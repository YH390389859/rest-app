namespace Rest.Platform.Windows.Media;

/// <summary>
/// 一个正在占用音频输出的应用 —— 对应 macOS 版的 <c>MediaSource</c>。
///
/// 和 macOS 最大的区别：Windows 的 SMTC 允许**按应用定向下发**暂停指令，
/// 所以这里不需要 macOS 那套「系统 Now Playing 槽位 / AppleScript / 辅助功能点按钮」
/// 的三级降级链路，只有「能控制」和「不能控制」两种。
/// </summary>
public sealed record MediaEntry
{
    /// <summary>SMTC 的 AppUserModelId；没有 SMTC 会话的应用退回 "pid:1234"。</summary>
    public required string AppKey { get; init; }

    /// <summary>展示名（Google Chrome / Spotify …）。</summary>
    public required string Name { get; init; }

    public int Pid { get; init; }

    /// <summary>可执行文件路径，用来抽应用图标。拿不到就为 null，界面退回首字母。</summary>
    public string? ExecutablePath { get; init; }

    public string? Title { get; init; }

    public string? Artist { get; init; }

    public string? Album { get; init; }

    public bool IsPlaying { get; init; }

    /// <summary>是否有 SMTC 会话可以下发暂停（false 时界面显示「无法自动暂停」）。</summary>
    public bool CanControl { get; init; }

    /// <summary>标题优先用媒体信息，拿不到就退回应用名（与 macOS 的 displayTitle 一致）。</summary>
    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? Name : Title!;

    /// <summary>副标题：音乐是「歌手 · 专辑」。</summary>
    public string? DisplayDetail
    {
        get
        {
            var parts = new List<string>();
            if (!string.IsNullOrWhiteSpace(Artist)) parts.Add(Artist!);
            if (!string.IsNullOrWhiteSpace(Album) && Album != Artist) parts.Add(Album!);
            return parts.Count == 0 ? null : string.Join(" · ", parts);
        }
    }
}
