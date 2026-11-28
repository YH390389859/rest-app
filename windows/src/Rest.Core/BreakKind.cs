namespace Rest.Core;

/// <summary>
/// 两种休息。macOS 版是 <c>enum BreakKind: String</c>，名字和文案在两边必须一致，
/// 否则托盘提示和遮罩界面会说两套话。
/// </summary>
public enum BreakKind
{
    /// <summary>小憩：频率高、时间短。</summary>
    Micro,

    /// <summary>休息：频率低、时间长。</summary>
    Long,
}

public static class BreakKindText
{
    public static string Title(this BreakKind kind) => kind == BreakKind.Long ? "休息" : "小憩";

    public static string Caption(this BreakKind kind) => kind == BreakKind.Long
        ? "起来走两步，活动肩颈，让眼睛看看远处"
        : "抬头看向远处 20 秒，眨眨眼睛，松开肩膀";

    /// <summary>写进设置文件 / 日志的稳定标识（对应 Swift 的 rawValue）。</summary>
    public static string RawValue(this BreakKind kind) => kind == BreakKind.Long ? "long" : "micro";
}
