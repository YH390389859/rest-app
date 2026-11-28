using System.Diagnostics;
using Windows.Media.Control;

namespace Rest.Platform.Windows.Media;

/// <summary>
/// 枚举「谁在出声」并按应用暂停 / 恢复。
///
/// 数据来源两条，合并成一个列表：
/// 1. **SMTC 会话**（<see cref="GlobalSystemMediaTransportControlsSessionManager"/>）——
///    公开 API，能拿到歌名/歌手，也能按应用下发暂停；
/// 2. **Core Audio 会话**（<see cref="AudioSessionInterop"/>）—— 补上那些没有 SMTC 的
///    老播放器，它们只能列出来，界面上显示「无法自动暂停」。
///
/// 对照 macOS 版：那边只有一个系统 Now Playing 槽位，多播放器同时出声时要靠
/// AppleScript / 辅助功能逐个点按钮；这边每条会话都是独立可控的，代码少了两个数量级。
/// </summary>
public sealed class MediaService
{
    /// <summary>被我们暂停过的应用，休息结束时用来恢复。</summary>
    private readonly HashSet<string> _paused = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string?> _exePathCache = new(StringComparer.Ordinal);
    private GlobalSystemMediaTransportControlsSessionManager? _manager;

    public bool IsPaused(string appKey) => _paused.Contains(appKey);

    public void DiscardPaused() => _paused.Clear();

    // MARK: 快照

    public async Task<IReadOnlyList<MediaEntry>> SnapshotAsync()
    {
        var manager = await GetManagerAsync();
        var entries = new List<MediaEntry>();
        var claimedPids = new HashSet<int>();

        if (manager is not null)
        {
            foreach (var session in manager.GetSessions())
            {
                var appKey = session.SourceAppUserModelId ?? string.Empty;
                if (string.IsNullOrEmpty(appKey)) continue;

                string? title = null, artist = null, album = null;
                try
                {
                    var props = await session.TryGetMediaPropertiesAsync();
                    if (props is not null)
                    {
                        title = NullIfEmpty(props.Title);
                        artist = NullIfEmpty(props.Artist);
                        album = NullIfEmpty(props.AlbumTitle);
                    }
                }
                catch
                {
                    // 某些应用会在查询属性时拒绝/超时，歌名拿不到不影响控制
                }

                var info = session.GetPlaybackInfo();
                var status = info?.PlaybackStatus ?? GlobalSystemMediaTransportControlsSessionPlaybackStatus.Closed;
                if (status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Closed) continue;

                var proc = ResolveProcess(appKey);
                if (proc is not null) claimedPids.Add(proc.Id);

                entries.Add(new MediaEntry
                {
                    AppKey = appKey,
                    Name = FriendlyName(appKey, proc),
                    Pid = proc?.Id ?? 0,
                    ExecutablePath = SafeMainModule(proc),
                    Title = title,
                    Artist = artist,
                    Album = album,
                    IsPlaying = status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing,
                    CanControl = true,
                });
            }
        }

        // SMTC 没覆盖到的、但确实在出声的应用（老播放器、某些游戏、命令行播放器）
        foreach (var output in AudioSessionInterop.EnumerateOutputSessions())
        {
            if (output.State != AudioSessionInterop.AudioSessionState.Active) continue;
            if (claimedPids.Contains(output.Pid)) continue;
            if (output.Pid == Environment.ProcessId) continue;

            Process? proc = null;
            try { proc = Process.GetProcessById(output.Pid); }
            catch { continue; }
            if (proc is null) continue;
            if (IsSystemProcess(proc.ProcessName)) continue;

            claimedPids.Add(output.Pid);
            entries.Add(new MediaEntry
            {
                AppKey = $"pid:{output.Pid}",
                Name = proc.ProcessName,
                Pid = output.Pid,
                ExecutablePath = SafeMainModule(proc),
                IsPlaying = true,
                CanControl = false,
            });
        }

        // 正在播放的排前面，其余按名称
        return entries
            .OrderByDescending(e => e.IsPlaying)
            .ThenBy(e => e.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    // MARK: 暂停 / 恢复

    /// <summary>暂停指定应用。返回 false 表示这个应用没有被暂停（不能控制或没响应）。</summary>
    public async Task<bool> PauseAsync(MediaEntry entry)
    {
        if (!entry.CanControl) return false;

        var session = await FindSessionAsync(entry.AppKey);
        if (session is null) return false;

        bool ok;
        try { ok = await session.TryPauseAsync(); }
        catch { ok = false; }

        if (!ok)
        {
            // 有些应用只实现了「切换」，退一步用 toggle
            try { ok = await session.TryTogglePlayPauseAsync(); }
            catch { ok = false; }
        }

        if (!ok) return false;

        _paused.Add(entry.AppKey);
        return true;
    }

    public async Task ResumeAsync(string appKey)
    {
        if (!_paused.Remove(appKey)) return;

        var session = await FindSessionAsync(appKey);
        if (session is null) return;

        // 用户自己又播起来了：别插手
        var status = session.GetPlaybackInfo()?.PlaybackStatus;
        if (status == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing) return;

        try { await session.TryPlayAsync(); }
        catch { /* 应用已经退出 */ }
    }

    public async Task ResumeAllAsync()
    {
        var keys = _paused.ToList();
        foreach (var key in keys) await ResumeAsync(key);
    }

    // MARK: 内部

    private async Task<GlobalSystemMediaTransportControlsSessionManager?> GetManagerAsync()
    {
        if (_manager is not null) return _manager;
        try
        {
            _manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
        }
        catch (Exception ex)
        {
            // 极少数精简版系统没有 Media Control 服务，此时界面仍能显示音频应用，
            // 只是不能自动暂停
            Debug.WriteLine($"Rest: SMTC 不可用 {ex.Message}");
        }
        return _manager;
    }

    private async Task<GlobalSystemMediaTransportControlsSession?> FindSessionAsync(string appKey)
    {
        var manager = await GetManagerAsync();
        return manager?.GetSessions()
            .FirstOrDefault(s => string.Equals(s.SourceAppUserModelId, appKey, StringComparison.Ordinal));
    }

    /// <summary>AUMID 里通常带得出进程名（chrome.exe / Spotify.exe），据此找到进程拿图标。</summary>
    private Process? ResolveProcess(string appUserModelId)
    {
        var token = TokenFromAumid(appUserModelId);
        if (string.IsNullOrEmpty(token)) return null;

        try
        {
            var candidates = Process.GetProcessesByName(token);
            if (candidates.Length > 0) return candidates.OrderBy(p => p.Id).First();

            // AUMID 里的 token 大小写和进程名不一定一致
            return Process.GetProcesses()
                .FirstOrDefault(p =>
                {
                    try { return string.Equals(p.ProcessName, token, StringComparison.OrdinalIgnoreCase); }
                    catch { return false; }
                });
        }
        catch
        {
            return null;
        }
    }

    private string FriendlyName(string appUserModelId, Process? process)
    {
        var token = TokenFromAumid(appUserModelId) ?? string.Empty;
        var known = token.ToLowerInvariant() switch
        {
            "chrome" => "Google Chrome",
            "msedge" => "Microsoft Edge",
            "firefox" => "Firefox",
            "spotify" => "Spotify",
            "zunemusic" => "媒体播放器",
            "wmplayer" => "Windows Media Player",
            "vlc" => "VLC",
            "foobar2000" => "foobar2000",
            "qqmusic" => "QQ 音乐",
            "cloudmusic" => "网易云音乐",
            "potplayermini64" or "potplayermini" => "PotPlayer",
            _ => null,
        };
        if (known is not null) return known;

        if (!string.IsNullOrEmpty(token)) return token;
        return TryProcessName(process) ?? appUserModelId;
    }

    /// <summary>
    /// 从 AUMID 里取「应用名」这一节：
    /// <c>Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic</c> → <c>ZuneMusic</c>；
    /// <c>Spotify.exe</c> → <c>Spotify</c>。
    /// </summary>
    private static string? TokenFromAumid(string aumid)
    {
        if (string.IsNullOrWhiteSpace(aumid)) return null;

        var packagePart = aumid.Split('!')[0];
        var underscore = packagePart.IndexOf('_');
        if (underscore > 0 && packagePart.Contains('.')) packagePart = packagePart[..underscore];

        var segments = packagePart.Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length == 0) return null;

        var last = segments[^1];
        if (last.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) last = last[..^4];
        return last.Length == 0 ? null : last;
    }

    private static string? TryProcessName(Process? process)
    {
        try { return process?.ProcessName; }
        catch { return null; }
    }

    private static string? SafeMainModule(Process? process)
    {
        if (process is null) return null;
        try { return process.MainModule?.FileName; }
        catch { return null; }   // 权限不够的进程会抛，图标就算了
    }

    private static string? NullIfEmpty(string? value)
        => string.IsNullOrWhiteSpace(value) ? null : value;

    private static bool IsSystemProcess(string name) => name.ToLowerInvariant() is
        "audiodg" or "svchost" or "system" or "idle" or "dwm" or "explorer" or "runtimebroker" or "searchhost";
}
