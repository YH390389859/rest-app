using System.Diagnostics;
using System.Windows;
using Rest.App.Views;
using Rest.Core;
using Rest.Platform.Windows.Host;
using Rest.Platform.Windows.Media;
using Rest.Platform.Windows.Wallpaper;
using WinForms = System.Windows.Forms;

namespace Rest.App;

/// <summary>
/// 把「调度器 → 遮罩窗口 → 媒体暂停」串起来的地方，对应 <c>Sources/Rest/BreakCoordinator.swift</c>。
/// 业务顺序必须和 macOS 版一致，否则两边体验会不一样：
/// 休息开始 → 人不在就跳过 → 播提示音 → 铺遮罩 → 换壁纸 → 抓音频源并暂停。
/// </summary>
public sealed class BreakCoordinator : IDisposable
{
    private readonly RestSettings _settings;
    private readonly BreakPlanner _planner;
    private readonly BreakViewModel _vm;
    private readonly OverlayManager _overlays;
    private readonly MediaService _media;
    private readonly BingWallpaperService _wallpapers;
    private readonly bool _verbose = Environment.GetCommandLineArgs().Contains("--verbose");

    private bool _isPreview;
    private CancellationTokenSource? _audioCts;

    /// <summary>当前这轮休息看到的音频源（点击行按钮时按 AppKey 找回来）。</summary>
    private List<MediaEntry> _sources = new();

    /// <summary>已被我们暂停、但可能已经从音频列表里消失的应用（保留在界面上，方便手动恢复）。</summary>
    private readonly Dictionary<string, MediaEntry> _pausedExtras = new(StringComparer.Ordinal);
    private readonly HashSet<string> _busyAudio = new(StringComparer.Ordinal);

    public BreakCoordinator(RestSettings settings, BreakPlanner planner,
        MediaService media, BingWallpaperService wallpapers)
    {
        _settings = settings;
        _planner = planner;
        _media = media;
        _wallpapers = wallpapers;
        _vm = new BreakViewModel();
        _overlays = new OverlayManager(_vm);

        _overlays.UserReturned += ContinueToWork;

        Wire();
    }

    public BreakViewModel ViewModel => _vm;

    private void Wire()
    {
        _planner.BreakStarted += HandleBreakStart;
        _planner.BreakTick += (remaining, _) =>
        {
            _vm.Remaining = remaining;
            if (_verbose) Debug.WriteLine($"Rest: 倒计时 {remaining.TotalSeconds:0}");
        };
        _planner.BreakFinished += HandleBreakFinished;
        _planner.WorkStarted += HandleWorkStart;

        _vm.OnSkip = SkipCurrentBreak;
        _vm.OnPostpone = PostponeBreak;
        _vm.OnContinue = ContinueToWork;
        _vm.OnExtend = () =>
        {
            _planner.ExtendBreak(TimeSpan.FromMinutes(1));
            _vm.Mode = BreakViewMode.Running;
        };
        _vm.OnToggleAudio = key => _ = ToggleAudioAsync(key);
        _vm.OnPauseAllAudio = () => _ = PauseAllAudioAsync();
    }

    // MARK: 对外

    public void SkipCurrentBreak()
    {
        if (_planner.CurrentKind is not { } kind || !_settings.AllowsSkip(kind)) return;
        _overlays.Dismiss();
        _planner.SkipBreak();
    }

    public void PostponeBreak()
    {
        if (_planner.CurrentKind is not { } kind || !_settings.AllowsPostpone(kind)) return;
        _overlays.Dismiss();
        _planner.Postpone();
    }

    public void ContinueToWork()
    {
        _overlays.Dismiss();
        _planner.BeginNextWork();
    }

    /// <summary>从托盘 / 设置里手动触发一次预览（忽略「人不在电脑前就跳过」的判断）。</summary>
    public void PreviewBreak()
    {
        _isPreview = true;
        _planner.StartBreakNow();
    }

    // MARK: 休息开始

    private void HandleBreakStart(BreakKind kind, TimeSpan duration)
    {
        Debug.WriteLine($"Rest: 休息开始 {kind.RawValue()} {duration.TotalSeconds:0}s");

        _vm.Kind = kind;
        _vm.Total = duration;
        _vm.Remaining = duration;
        _vm.Mode = BreakViewMode.Running;
        ClearAudioState();

        _vm.WorkLabel = _settings.NextWorkLabel;
        _vm.PostponeLabel = $"{(int)_settings.PostponeMinutes} 分钟";
        _vm.CanSkip = _settings.AllowsSkip(kind);
        _vm.CanPostpone = _settings.AllowsPostpone(kind);

        // 人不在电脑前就没必要弹遮罩
        var preview = _isPreview;
        _isPreview = false;

        if (!preview && _settings.SkipWhenIdle &&
            IdleMonitor.SinceLastInput() > _settings.IdleThreshold)
        {
            Debug.WriteLine("Rest: 检测到用户离开，跳过本次休息");
            Application.Current.Dispatcher.BeginInvoke(new Action(() => _planner.BeginNextWork()));
            return;
        }

        if (_settings.PlaySound) SoundFx.PlayBreakStart();

        _overlays.ScreenProvider = CurrentScreens;
        _overlays.Show();

        LoadWallpaper();
        StartAudioTracking();
    }

    private IReadOnlyList<WinForms.Screen> CurrentScreens()
    {
        var all = WinForms.Screen.AllScreens;
        if (_settings.AllDisplays) return all;

        var primary = WinForms.Screen.PrimaryScreen;
        return primary is null ? all : new[] { primary };
    }

    private void LoadWallpaper()
    {
        if (!_settings.UseBingWallpaper)
        {
            _vm.Wallpaper = null;
            _vm.WallpaperCredit = string.Empty;
            return;
        }

        var market = _settings.WallpaperMarket;

        // 有预取好的就立刻换上，同时后台准备再下一张
        var ready = _wallpapers.TakePreloaded(market);
        if (ready is not null)
        {
            Apply(ready);
            _wallpapers.PrepareNext(market);
            return;
        }

        _ = Task.Run(async () =>
        {
            var item = await _wallpapers.NextAsync(market);
            await Application.Current.Dispatcher.InvokeAsync(() => Apply(item));
            _wallpapers.PrepareNext(market);
        });
    }

    private void Apply(WallpaperItem? item)
    {
        _vm.Wallpaper = IconLoader.LoadImage(item?.FilePath);
        _vm.WallpaperCredit = item?.Credit ?? string.Empty;
    }

    // MARK: 音频

    /// <summary>休息开始时抓一次音频源，之后每 5 秒刷新（用户中途开新视频也能列出来）。</summary>
    private void StartAudioTracking()
    {
        _audioCts?.Cancel();
        _audioCts = new CancellationTokenSource();
        var token = _audioCts.Token;
        var autoPause = _settings.AutoPauseMedia;

        _ = Task.Run(async () =>
        {
            await RefreshAudioAsync(pausePlaying: autoPause, token);

            while (!token.IsCancellationRequested)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(5), token); }
                catch (TaskCanceledException) { return; }

                if (token.IsCancellationRequested || _planner.CurrentKind is null) return;
                await RefreshAudioAsync(pausePlaying: false, token);
            }
        }, token);
    }

    private async Task RefreshAudioAsync(bool pausePlaying, CancellationToken token)
    {
        var list = (await _media.SnapshotAsync()).ToList();
        if (token.IsCancellationRequested) return;
        _sources = list;
        ApplyAudioRows(list);

        if (!pausePlaying) return;

        var targets = list.Where(e => !_media.IsPaused(e.AppKey) && e.CanControl).ToList();
        if (targets.Count == 0) return;

        await Application.Current.Dispatcher.InvokeAsync(() => _vm.AudioBusyAll = true);
        var failed = new List<string>();
        foreach (var source in targets)
        {
            if (await _media.PauseAsync(source)) _pausedExtras[source.AppKey] = source;
            else failed.Add(source.Name);
        }
        await Application.Current.Dispatcher.InvokeAsync(() => _vm.AudioBusyAll = false);

        ApplyAudioRows(_sources);
        if (failed.Count > 0) SetNotice($"「{string.Join("、", failed)}」没响应暂停指令，可以手动暂停");
    }

    private void ApplyAudioRows(IReadOnlyList<MediaEntry> list)
    {
        var merged = list.ToList();
        foreach (var (key, source) in _pausedExtras)
        {
            if (_media.IsPaused(key) && !merged.Any(e => e.AppKey == key)) merged.Add(source);
        }

        var rows = merged.Select(source => new BreakViewModel.AudioRow
        {
            Id = source.AppKey,
            Title = source.DisplayTitle,
            Detail = DetailFor(source),
            Icon = IconLoader.FromExecutable(source.ExecutablePath),
            IsNowPlaying = source.IsPlaying,
            CanControl = source.CanControl,
            Paused = _media.IsPaused(source.AppKey),
            Busy = _busyAudio.Contains(source.AppKey),
        }).ToList();

        _ = Application.Current.Dispatcher.InvokeAsync(() =>
        {
            _vm.AudioRows.Clear();
            foreach (var row in rows) _vm.AudioRows.Add(row);
            _vm.NotifyAudioCollectionChanged();
        });
    }

    private string? DetailFor(MediaEntry source)
    {
        if (source.DisplayDetail is { } detail) return detail;
        if (_media.IsPaused(source.AppKey)) return null;
        if (!source.CanControl) return "系统未提供控制接口";
        return "正在播放";
    }

    private async Task ToggleAudioAsync(string appKey)
    {
        var source = _sources.FirstOrDefault(e => e.AppKey == appKey)
                     ?? (_pausedExtras.TryGetValue(appKey, out var extra) ? extra : null);
        if (source is null) return;

        if (_media.IsPaused(appKey))
        {
            _pausedExtras.Remove(appKey);
            await _media.ResumeAsync(appKey);
            ApplyAudioRows(_sources);
            return;
        }

        _busyAudio.Add(appKey);
        ApplyAudioRows(_sources);

        var ok = await _media.PauseAsync(source);
        _busyAudio.Remove(appKey);

        if (ok)
        {
            _pausedExtras[appKey] = source;
            SetNotice(null);
        }
        else
        {
            SetNotice($"「{source.Name}」没响应暂停指令，可以手动暂停");
        }
        ApplyAudioRows(_sources);
    }

    private async Task PauseAllAudioAsync()
    {
        if (_vm.AudioBusyAll) return;
        await Application.Current.Dispatcher.InvokeAsync(() => _vm.AudioBusyAll = true);

        var failed = new List<string>();
        foreach (var source in _sources.Where(e => !_media.IsPaused(e.AppKey) && e.CanControl))
        {
            if (await _media.PauseAsync(source)) _pausedExtras[source.AppKey] = source;
            else failed.Add(source.Name);
        }

        await Application.Current.Dispatcher.InvokeAsync(() => _vm.AudioBusyAll = false);
        ApplyAudioRows(_sources);
        SetNotice(failed.Count == 0 ? null : $"「{string.Join("、", failed)}」没响应暂停指令，可以手动暂停");
    }

    private void SetNotice(string? notice)
        => _ = Application.Current.Dispatcher.InvokeAsync(() => _vm.AudioNotice = notice);

    private void ClearAudioState()
    {
        _sources = new List<MediaEntry>();
        _pausedExtras.Clear();
        _busyAudio.Clear();
        _vm.AudioRows.Clear();
        _vm.AudioNotice = null;
        _vm.AudioBusyAll = false;
        _vm.NotifyAudioCollectionChanged();
    }

    // MARK: 休息结束

    private void HandleBreakFinished()
    {
        if (_settings.PlaySound) SoundFx.PlayBreakEnd();

        switch (_settings.BreakEndBehavior)
        {
            case BreakEndBehavior.Auto:
                Debug.WriteLine("Rest: 休息结束 → 直接进入下一轮");
                ContinueToWork();
                break;

            case BreakEndBehavior.Manual:
                Debug.WriteLine("Rest: 休息结束 → 等待点击按钮");
                _vm.Mode = BreakViewMode.FinishedManual;
                break;

            default:
                Debug.WriteLine("Rest: 休息结束 → 进入透明遮罩，等待键鼠动作");
                _overlays.BeginShield();
                break;
        }
    }

    private void HandleWorkStart()
    {
        Debug.WriteLine($"Rest: 进入工作计时 {_planner.Total.TotalSeconds:0}s");
        _overlays.Dismiss();
        _vm.Mode = BreakViewMode.Running;

        _audioCts?.Cancel();
        _audioCts = null;
        ClearAudioState();

        if (_settings.ResumeMediaAfterBreak) _ = _media.ResumeAllAsync();
        else _media.DiscardPaused();
    }

    public void Dispose()
    {
        _audioCts?.Cancel();
        _overlays.Dispose();
    }
}
