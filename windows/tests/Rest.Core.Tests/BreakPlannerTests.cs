using Rest.Core;
using Xunit;

namespace Rest.Core.Tests;

/// <summary>可控时钟：把「30 分钟一轮」压缩成毫秒级。</summary>
public sealed class FakeClock : IClock
{
    public DateTimeOffset Now { get; set; } = new(2026, 1, 1, 9, 0, 0, TimeSpan.FromHours(8));

    public void Advance(TimeSpan delta) => Now += delta;

    public void AdvanceMinutes(double minutes) => Advance(TimeSpan.FromMinutes(minutes));

    public void AdvanceSeconds(double seconds) => Advance(TimeSpan.FromSeconds(seconds));
}

/// <summary>
/// 节奏模型的「契约测试」。
///
/// 这些用例是把 <c>Sources/Rest/Scheduler.swift</c> 的行为一条条翻译过来的，
/// 目的不是测 C# 写得好不好，而是**防止两个平台的行为慢慢跑偏**：
/// 谁改了任一边的语义，这里或那边的测试就该红。
/// </summary>
public sealed class BreakPlannerTests
{
    private static (BreakPlanner planner, RestSettings settings, FakeClock clock) Make(
        Action<RestSettings>? tweak = null)
    {
        var settings = new RestSettings(new MemorySettingsStore());
        tweak?.Invoke(settings);
        var clock = new FakeClock();
        return (new BreakPlanner(settings, clock), settings, clock);
    }

    /// <summary>把工作段走完，返回进入休息时的类型。</summary>
    private static BreakKind RunWorkToEnd(BreakPlanner planner, FakeClock clock, RestSettings settings)
    {
        clock.Advance(TimeSpan.FromSeconds(planner.Total.TotalSeconds + 0.5));
        planner.Tick();
        return planner.CurrentKind ?? throw new InvalidOperationException("应该已经进入休息");
    }

    [Fact]
    public void Start_进入工作计时_默认10分钟()
    {
        var (planner, _, _) = Make();
        planner.Start();

        Assert.Equal(SchedulerPhase.Working, planner.State.Phase);
        Assert.False(planner.State.Paused);
        Assert.Equal(TimeSpan.FromMinutes(10), planner.Total);
        Assert.Equal(TimeSpan.FromMinutes(10), planner.Remaining);
    }

    [Fact]
    public void 默认节奏_小憩小憩休息()
    {
        var (planner, settings, clock) = Make();
        planner.Start();

        Assert.Equal(BreakKind.Micro, RunWorkToEnd(planner, clock, settings));
        planner.BeginNextWork();
        Assert.Equal(BreakKind.Micro, RunWorkToEnd(planner, clock, settings));
        planner.BeginNextWork();
        Assert.Equal(BreakKind.Long, RunWorkToEnd(planner, clock, settings));
    }

    [Fact]
    public void 长休息结束后计数器归零_重新从小憩开始()
    {
        var (planner, settings, clock) = Make();
        planner.Start();
        RunWorkToEnd(planner, clock, settings);
        planner.BeginNextWork();
        RunWorkToEnd(planner, clock, settings);
        planner.BeginNextWork();
        Assert.Equal(BreakKind.Long, RunWorkToEnd(planner, clock, settings));

        planner.BeginNextWork();
        // 计数归零，所以下一轮又是两次小憩之后才长休息
        Assert.Equal(BreakKind.Micro, RunWorkToEnd(planner, clock, settings));
    }

    [Fact]
    public void 小憩20秒_休息5分钟()
    {
        var (planner, settings, clock) = Make();
        planner.Start();

        RunWorkToEnd(planner, clock, settings);
        Assert.Equal(TimeSpan.FromSeconds(20), planner.Total);

        planner.BeginNextWork();
        RunWorkToEnd(planner, clock, settings);
        planner.BeginNextWork();
        RunWorkToEnd(planner, clock, settings);
        Assert.Equal(TimeSpan.FromMinutes(5), planner.Total);
    }

    [Fact]
    public void 休息结束不自动进入下一轮_停在BreakFinished()
    {
        var (planner, settings, clock) = Make();
        planner.Start();
        RunWorkToEnd(planner, clock, settings);

        clock.AdvanceSeconds(25);
        planner.Tick();

        Assert.Equal(SchedulerPhase.BreakFinished, planner.State.Phase);
        Assert.Equal(BreakKind.Micro, planner.CurrentKind);
        Assert.Equal(1, planner.CompletedBreaks);

        // 关键：状态机自己不动，必须外部叫它
        clock.AdvanceMinutes(5);
        planner.Tick();
        Assert.Equal(SchedulerPhase.BreakFinished, planner.State.Phase);
    }

    [Fact]
    public void 跳过小憩_不占槽位_下一次还是小憩()
    {
        var (planner, settings, clock) = Make();
        planner.Start();

        RunWorkToEnd(planner, clock, settings);   // 第 1 次
        planner.SkipBreak();

        Assert.Equal(SchedulerPhase.Working, planner.State.Phase);
        Assert.Equal(BreakKind.Micro, RunWorkToEnd(planner, clock, settings)); // 第 1 次重来
    }

    [Fact]
    public void 跳过休息_计数器归零()
    {
        var (planner, settings, clock) = Make();
        planner.Start();
        RunWorkToEnd(planner, clock, settings);
        planner.BeginNextWork();
        RunWorkToEnd(planner, clock, settings);
        planner.BeginNextWork();
        Assert.Equal(BreakKind.Long, RunWorkToEnd(planner, clock, settings));

        planner.SkipBreak();
        // 归零后再数一次：又是「2 次小憩后」才有长休息
        Assert.Equal(2, planner.MicrosBeforeNextLong);

        // 归零后应该还能连续来两次小憩
        Assert.Equal(BreakKind.Micro, RunWorkToEnd(planner, clock, settings));
    }

    [Fact]
    public void 推迟休息_工作段变成推迟时长_之后还是同一种()
    {
        var (planner, settings, clock) = Make();
        planner.Start();

        RunWorkToEnd(planner, clock, settings);   // 第 1 次小憩
        planner.Postpone();

        Assert.Equal(SchedulerPhase.Working, planner.State.Phase);
        Assert.Equal(TimeSpan.FromMinutes(5), planner.Total);
        Assert.Equal(BreakKind.Micro, RunWorkToEnd(planner, clock, settings));
    }

    [Fact]
    public void 严格模式下不能跳过也不能推迟()
    {
        var (planner, settings, clock) = Make(s => s.MicroStrictMode = true);
        planner.Start();
        RunWorkToEnd(planner, clock, settings);

        Assert.False(settings.AllowsSkip(BreakKind.Micro));
        Assert.False(settings.AllowsPostpone(BreakKind.Micro));

        planner.SkipBreak();
        Assert.Equal(SchedulerPhase.Breaking, planner.State.Phase);

        planner.Postpone();
        Assert.Equal(SchedulerPhase.Breaking, planner.State.Phase);
    }

    [Fact]
    public void 关掉小憩允许跳过_严格模式不影响休息()
    {
        var (planner, settings, clock) = Make(s =>
        {
            s.MicroStrictMode = true;
            s.LongAllowPostpone = true;
        });
        planner.Start();
        Assert.True(settings.AllowsPostpone(BreakKind.Long));
        Assert.True(settings.AllowsSkip(BreakKind.Long));
    }

    [Fact]
    public void 暂停期间倒计时不动_恢复后平移deadline()
    {
        var (planner, _, clock) = Make();
        planner.Start();

        clock.AdvanceMinutes(3);
        planner.Tick();
        Assert.Equal(TimeSpan.FromMinutes(7), planner.Remaining);

        planner.TogglePause();
        Assert.True(planner.State.Paused);

        clock.AdvanceMinutes(4);
        planner.Tick();
        Assert.Equal(TimeSpan.FromMinutes(7), planner.Remaining);

        planner.TogglePause();
        Assert.False(planner.State.Paused);

        clock.AdvanceMinutes(6.9);
        planner.Tick();
        Assert.Equal(SchedulerPhase.Working, planner.State.Phase);
        Assert.Equal(TimeSpan.FromSeconds(6), planner.Remaining);

        clock.AdvanceSeconds(7);
        planner.Tick();
        Assert.Equal(SchedulerPhase.Breaking, planner.State.Phase);
    }

    [Fact]
    public void 未开始时暂停等于开始()
    {
        var (planner, _, _) = Make();
        planner.TogglePause();
        Assert.Equal(SchedulerPhase.Working, planner.State.Phase);
    }

    [Fact]
    public void 休息中延长1分钟_总时长和剩余都增加()
    {
        var (planner, settings, clock) = Make();
        planner.Start();
        RunWorkToEnd(planner, clock, settings);

        planner.ExtendBreak(TimeSpan.FromMinutes(1));
        Assert.Equal(TimeSpan.FromSeconds(80), planner.Total);
        Assert.Equal(TimeSpan.FromSeconds(80), planner.Remaining);
    }

    [Fact]
    public void 结束界面再休息1分钟_回到breaking()
    {
        var (planner, settings, clock) = Make();
        planner.Start();
        RunWorkToEnd(planner, clock, settings);
        clock.AdvanceSeconds(25);
        planner.Tick();
        Assert.Equal(SchedulerPhase.BreakFinished, planner.State.Phase);

        planner.ExtendBreak(TimeSpan.FromMinutes(1));
        Assert.Equal(SchedulerPhase.Breaking, planner.State.Phase);
        Assert.Equal(TimeSpan.FromMinutes(1), planner.Remaining);
    }

    [Fact]
    public void 两类休息都关掉_启动后是stopped()
    {
        var (planner, _, _) = Make(s =>
        {
            s.MicroEnabled = false;
            s.LongEnabled = false;
        });
        planner.Start();
        Assert.Equal(SchedulerPhase.Stopped, planner.State.Phase);
        Assert.Equal(0, planner.Total.TotalSeconds);
    }

    [Fact]
    public void 只开休息_一段工作等于一个完整周期()
    {
        var (planner, settings, clock) = Make(s => s.MicroEnabled = false);
        planner.Start();

        Assert.Equal(TimeSpan.FromMinutes(30), planner.Total);
        Assert.Equal(BreakKind.Long, RunWorkToEnd(planner, clock, settings));
        Assert.Null(planner.MicrosBeforeNextLong);
    }

    [Fact]
    public void 只开小憩_永远不安排长休息()
    {
        var (planner, settings, clock) = Make(s => s.LongEnabled = false);
        planner.Start();

        for (var i = 0; i < 5; i++)
        {
            Assert.Equal(BreakKind.Micro, RunWorkToEnd(planner, clock, settings));
            planner.BeginNextWork();
        }
    }

    [Fact]
    public void 托盘提示_2次1次0次小憩()
    {
        var (planner, settings, clock) = Make();
        planner.Start();

        Assert.Equal(2, planner.MicrosBeforeNextLong);
        Assert.Equal(BreakKind.Micro, planner.UpcomingKind);

        RunWorkToEnd(planner, clock, settings);
        planner.BeginNextWork();
        Assert.Equal(1, planner.MicrosBeforeNextLong);

        RunWorkToEnd(planner, clock, settings);
        planner.BeginNextWork();
        Assert.Equal(0, planner.MicrosBeforeNextLong);
        Assert.Equal(BreakKind.Long, planner.UpcomingKind);
    }

    [Fact]
    public void 槽位数按四舍五入远离零_和Swift一致()
    {
        // Swift 的 rounded() 对 2.5 给 3；C# 默认 Math.Round 会给 2。这里必须和 Swift 一致。
        var settings = new RestSettings(new MemorySettingsStore()) { MicrosBeforeLong = 2.5 };
        Assert.Equal(4, settings.SlotsPerLong);

        // 休息周期 = 10 分 × 4 = 40 分
        Assert.Equal(TimeSpan.FromMinutes(40), settings.LongCycleSeconds);
    }

    [Fact]
    public void 改小憩间隔会连带改变长休息的实际时间()
    {
        var settings = new RestSettings(new MemorySettingsStore()) { MicroBreakEveryMinutes = 20 };
        Assert.Equal(TimeSpan.FromMinutes(60), settings.LongCycleSeconds);
        Assert.Equal(60, settings.LongCycleMinutes);
    }

    [Fact]
    public void 时钟格式化()
    {
        Assert.Equal("00:20", ClockText.FormatClock(TimeSpan.FromSeconds(20)));
        Assert.Equal("10:00", ClockText.FormatClock(TimeSpan.FromMinutes(10)));
        Assert.Equal("00:00", ClockText.FormatClock(TimeSpan.FromSeconds(-5)));
        Assert.Equal("01:05", ClockText.FormatClock(TimeSpan.FromSeconds(64.6)));
    }

    [Fact]
    public void 设置能存能读()
    {
        var dir = Path.Combine(Path.GetTempPath(), "rest-settings-test-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(dir, "settings.json");
        try
        {
            var store = new JsonSettingsStore(path);
            var settings = new RestSettings(store) { MicroBreakEveryMinutes = 15, MicroEnabled = false };

            var reloaded = new RestSettings(new JsonSettingsStore(path));
            Assert.Equal(15, reloaded.MicroBreakEveryMinutes);
            Assert.False(reloaded.MicroEnabled);
            // 没改过的值应该是默认值，而不是 0
            Assert.Equal(5, reloaded.LongBreakMinutes);
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }
}
