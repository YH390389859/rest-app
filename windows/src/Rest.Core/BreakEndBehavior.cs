namespace Rest.Core;

/// <summary>休息倒计时结束后的行为，和 Swift 版 <c>BreakEndBehavior</c> 一一对应。</summary>
public enum BreakEndBehavior
{
    /// <summary>倒计时结束立刻进入下一轮工作（Stretchly 默认行为）。</summary>
    Auto,

    /// <summary>停在结束界面，必须点按钮才继续。</summary>
    Manual,

    /// <summary>倒计时结束后变成全透明遮罩，捕获到第一次键鼠动作才继续。</summary>
    WaitForInput,
}

public static class BreakEndBehaviorText
{
    public static string Title(this BreakEndBehavior behavior) => behavior switch
    {
        BreakEndBehavior.Auto => "直接进入下一轮",
        BreakEndBehavior.Manual => "停留，等按钮",
        _ => "透明遮罩 + 任意操作",
    };

    public static string Detail(this BreakEndBehavior behavior) => behavior switch
    {
        BreakEndBehavior.Auto => "倒计时归零后立刻开始下一轮工作，遮罩自动消失。",
        BreakEndBehavior.Manual => "倒计时归零后停留在结束界面，显示「开始下一轮」按钮。",
        _ => "倒计时归零后遮罩变为全透明（看起来已经可以操作），捕获到第一次键鼠动作后关闭遮罩并开始下一轮。",
    };
}
