namespace Rest.Core;

public enum SchedulerPhase
{
    Stopped,
    Working,
    Breaking,
    BreakFinished,
}

/// <summary>调度器状态的不可变快照（对应 Swift 的 <c>enum SchedulerState</c> 带关联值）。</summary>
public readonly record struct PlannerState(SchedulerPhase Phase, bool Paused, BreakKind Kind)
{
    public static readonly PlannerState Stopped = new(SchedulerPhase.Stopped, false, BreakKind.Micro);
    public static PlannerState Working(bool paused = false) => new(SchedulerPhase.Working, paused, BreakKind.Micro);
    public static PlannerState Breaking(BreakKind kind) => new(SchedulerPhase.Breaking, false, kind);
    public static PlannerState BreakFinished(BreakKind kind) => new(SchedulerPhase.BreakFinished, false, kind);

    public bool IsWorking => Phase == SchedulerPhase.Working;
    public bool IsBreaking => Phase is SchedulerPhase.Breaking or SchedulerPhase.BreakFinished;
}

/// <summary>
/// 工作时间 / 休息时间状态机。**这是整个项目里唯一需要两个平台逐字对齐的类**，
/// 移植自 <c>Sources/Rest/Scheduler.swift</c>，语义改动必须两边同时改。
///
/// 节奏模型照抄 Stretchly：每一段工作长度都等于小憩间隔，休息第几次到来由计数器决定 ——
/// <c>breakNumber % (microsBeforeLong + 1) == 0</c> 时来一次长休息。所以「休息 每 30 分」
/// 在 10 分钟小憩间隔下 = 每 3 个槽位一次，也就是「2 次小憩后」。
///
/// 和 Swift 版的两处实现差异（不影响行为）：
/// 1. 计时器不在类内部：外部每 250ms 调一次 <see cref="Tick"/>，好处是测试可以精确推进时间；
/// 2. 时间来源是 <see cref="IClock"/>，测试用可控时钟，不依赖真实 sleep。
///
/// 它只负责计时与状态流转，不碰任何 UI；休息结束后不会自行进入下一轮，
/// 必须由外部调用 <see cref="BeginNextWork"/>，这样才能实现「等用户点了才继续」。
/// </summary>
public sealed class BreakPlanner
{
    private readonly RestSettings _settings;
    private readonly IClock _clock;

    /// <summary>本次工作/休息阶段的结束时刻。</summary>
    private DateTimeOffset? _deadline;

    /// <summary>已经过了几个槽位（Stretchly 的 breakNumber）。</summary>
    private int _breakNumber;

    /// <summary>暂停的开始时刻，恢复时据此平移 deadline。</summary>
    private DateTimeOffset? _pausedAt;

    public BreakPlanner(RestSettings settings, IClock? clock = null)
    {
        _settings = settings;
        _clock = clock ?? SystemClock.Instance;
    }

    public PlannerState State { get; private set; } = PlannerState.Stopped;

    public TimeSpan Remaining { get; private set; }

    public TimeSpan Total { get; private set; }

    public int CompletedBreaks { get; private set; }

    /// <summary>任何状态变化（界面、托盘都要跟着刷）。</summary>
    public event Action? StateChanged;

    public event Action<BreakKind, TimeSpan>? BreakStarted;

    /// <summary>休息期间每 250ms 触发一次，参数为（剩余, 总时长）。</summary>
    public event Action<TimeSpan, TimeSpan>? BreakTick;

    public event Action? BreakFinished;

    public event Action? WorkStarted;

    // MARK: 对外操作

    public void Start()
    {
        _breakNumber = 0;
        EnterWork(_settings.WorkSpan);
    }

    public void TogglePause()
    {
        switch (State.Phase)
        {
            case SchedulerPhase.Working:
                if (State.Paused)
                {
                    if (_pausedAt is { } since && _deadline is { } deadline)
                    {
                        _deadline = deadline + (_clock.Now - since);
                    }
                    _pausedAt = null;
                    State = PlannerState.Working(paused: false);
                }
                else
                {
                    _pausedAt = _clock.Now;
                    State = PlannerState.Working(paused: true);
                }
                StateChanged?.Invoke();
                break;

            case SchedulerPhase.Stopped:
                Start();
                break;
        }
    }

    /// <summary>手动立刻进入休息（按当前计数器判断该来哪一种）。</summary>
    public void StartBreakNow() => StartBreak();

    /// <summary>跳过当前休息，直接开始下一轮工作。</summary>
    public void SkipBreak()
    {
        if (CurrentKind is not { } kind || !_settings.AllowsSkip(kind)) return;
        // 跳过的那一次不再占用周期里的位置
        if (kind == BreakKind.Long) _breakNumber = 0;
        EnterWork(_settings.WorkSpan);
    }

    /// <summary>推迟当前休息：回到工作状态，N 分钟后再来同一种休息。</summary>
    public void Postpone()
    {
        if (CurrentKind is not { } kind || !_settings.AllowsPostpone(kind)) return;
        // 这一种休息还没真正发生，把计数退回去
        _breakNumber = Math.Max(0, _breakNumber - 1);
        EnterWork(_settings.PostponeDuration);
    }

    /// <summary>休息结束，进入下一轮工作。</summary>
    public void BeginNextWork()
    {
        if (CurrentKind == BreakKind.Long) _breakNumber = 0;
        EnterWork(_settings.WorkSpan);
    }

    /// <summary>休息结束界面点「再休息一会儿」。</summary>
    public void ExtendBreak(TimeSpan extra)
    {
        switch (State.Phase)
        {
            case SchedulerPhase.Breaking:
                if (_deadline is not { } d) return;
                _deadline = d + extra;
                Total += extra;
                Remaining = Max0(_deadline.Value - _clock.Now);
                break;

            case SchedulerPhase.BreakFinished:
                Total += extra;
                Remaining = extra;
                State = PlannerState.Breaking(State.Kind);
                _deadline = _clock.Now + extra;
                break;

            default:
                return;
        }
        StateChanged?.Invoke();
    }

    // MARK: 状态查询

    public bool IsBreaking => State.IsBreaking;

    /// <summary>当前正在休息（或刚结束）的类型。</summary>
    public BreakKind? CurrentKind => State.Phase switch
    {
        SchedulerPhase.Breaking or SchedulerPhase.BreakFinished => State.Kind,
        _ => null,
    };

    /// <summary>即将到来的那次休息是什么类型。</summary>
    public BreakKind UpcomingKind
    {
        get
        {
            if (!_settings.MicroEnabled) return BreakKind.Long;
            if (!_settings.LongEnabled) return BreakKind.Micro;
            return (_breakNumber + 1) % _settings.SlotsPerLong == 0 ? BreakKind.Long : BreakKind.Micro;
        }
    }

    /// <summary>
    /// 距离下一次长休息还要经过几次小憩（Stretchly 的「N 次小憩后」）。0 表示下一次就是长休息，
    /// null 表示只开了一种休息、这个概念不适用。
    /// </summary>
    public int? MicrosBeforeNextLong
    {
        get
        {
            if (!_settings.MicroEnabled || !_settings.LongEnabled) return null;
            var slots = _settings.SlotsPerLong;
            return Math.Max(0, slots - 1 - (_breakNumber % slots));
        }
    }

    public string StatusText => State.Phase switch
    {
        SchedulerPhase.Stopped => "开始",
        SchedulerPhase.Working => State.Paused ? "暂停" : ClockText.FormatClock(Remaining),
        SchedulerPhase.Breaking => (State.Kind == BreakKind.Long ? "休息 " : "小憩 ") + ClockText.FormatClock(Remaining),
        _ => "休息结束",
    };

    // MARK: 计时（由外部 250ms 定时器驱动）

    public void Tick()
    {
        switch (State.Phase)
        {
            case SchedulerPhase.Working when !State.Paused && _deadline is { } d:
                Remaining = Max0(d - _clock.Now);
                if (Remaining <= TimeSpan.Zero)
                {
                    // 推迟过的工作段走完，下一次就轮到本该来的那种休息
                    StartBreak();
                    return;
                }
                StateChanged?.Invoke();
                break;

            case SchedulerPhase.Breaking when _deadline is { } d:
                Remaining = Max0(d - _clock.Now);
                if (Remaining <= TimeSpan.Zero)
                {
                    _deadline = null;
                    CompletedBreaks++;
                    State = PlannerState.BreakFinished(State.Kind);
                    BreakFinished?.Invoke();
                    StateChanged?.Invoke();
                }
                else
                {
                    BreakTick?.Invoke(Remaining, Total);
                    StateChanged?.Invoke();
                }
                break;
        }
    }

    // MARK: 内部

    private void EnterWork(TimeSpan span)
    {
        if (!_settings.MicroEnabled && !_settings.LongEnabled)
        {
            // 两类休息都关掉了，就没有可计时的东西
            State = PlannerState.Stopped;
            _deadline = null;
            Remaining = TimeSpan.Zero;
            Total = TimeSpan.Zero;
            WorkStarted?.Invoke();
            StateChanged?.Invoke();
            return;
        }

        Total = span < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : span;
        State = PlannerState.Working(paused: false);
        _deadline = _clock.Now + Total;
        Remaining = Total;
        WorkStarted?.Invoke();
        StateChanged?.Invoke();
    }

    private void StartBreak()
    {
        if (!_settings.MicroEnabled && !_settings.LongEnabled) return;

        _breakNumber++;
        var kind = !_settings.MicroEnabled
            ? BreakKind.Long
            : !_settings.LongEnabled
                ? BreakKind.Micro
                : _breakNumber % _settings.SlotsPerLong == 0 ? BreakKind.Long : BreakKind.Micro;

        var duration = kind == BreakKind.Long ? _settings.LongBreakDuration : _settings.MicroBreakDuration;

        State = PlannerState.Breaking(kind);
        _deadline = _clock.Now + duration;
        Total = duration;
        Remaining = duration;
        BreakStarted?.Invoke(kind, duration);
        StateChanged?.Invoke();
    }

    private static TimeSpan Max0(TimeSpan span) => span < TimeSpan.Zero ? TimeSpan.Zero : span;
}
