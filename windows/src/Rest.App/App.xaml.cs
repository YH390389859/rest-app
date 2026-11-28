using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Rest.Core;
using Rest.Platform.Windows.Host;
using Rest.Platform.Windows.Media;
using Rest.Platform.Windows.Wallpaper;

namespace Rest.App;

/// <summary>
/// 应用入口。对应 <c>Sources/Rest/AppDelegate.swift</c>：建对象、连事件、起托盘、起计时。
///
/// 计时器只在外面驱动一次 <see cref="BreakPlanner.Tick"/>（250ms），
/// 调度器的所有时间判断都以注入的时钟为准，和界面线程解耦。
/// </summary>
public partial class App : Application
{
    private Mutex? _singleInstanceMutex;
    private DispatcherTimer? _tickTimer;

    private JsonSettingsStore _store = null!;
    private RestSettings _settings = null!;
    private MediaService _media = null!;
    private BingWallpaperService _wallpapers = null!;
    private BreakPlanner _planner = null!;
    private BreakCoordinator _coordinator = null!;
    private TrayIconHost _tray = null!;
    private Views.SettingsWindow _settingsWindow = null!;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var args = e.Args;
        var headless = args.Contains("--render") || args.Contains("--render-settings")
                       || args.Contains("--dump-media") || args.Contains("--test-pause")
                       || args.Contains("--self-test");

        if (headless) ConsoleBridge.Attach();

        // 多开会出现两个托盘图标、两套计时，体验灾难，所以只允许一个实例
        _singleInstanceMutex = new Mutex(true, @"Local\Rest-SingleInstance", out var isFirst);
        if (!isFirst)
        {
            ConsoleBridge.Log("Rest 已在运行，本次启动退出");
            Shutdown(0);
            return;
        }

        _store = new JsonSettingsStore(JsonSettingsStore.DefaultPath());
        _settings = new RestSettings(_store);
        _media = new MediaService();
        _wallpapers = new BingWallpaperService(_store);
        _planner = new BreakPlanner(_settings);
        _coordinator = new BreakCoordinator(_settings, _planner, _media, _wallpapers);

        try
        {
            await RunStartupModesAsync(args, headless);
        }
        catch (Exception ex)
        {
            ConsoleBridge.Log($"Rest: 启动失败 {ex}");
            if (!headless) MessageBox.Show(ex.ToString(), "Rest 启动失败");
            Shutdown(1);
        }
    }

    private async Task RunStartupModesAsync(string[] args, bool headless)
    {
        // 离屏渲染 / 自检：跑完直接退出，不建托盘
        if (TryGetArgValue(args, "--render") is { } renderPath)
        {
            DebugRender.RenderBreak(renderPath, _settings);
            Shutdown(0);
            return;
        }

        if (TryGetArgValue(args, "--render-settings") is { } settingsPath)
        {
            DebugRender.RenderSettings(settingsPath, _settings);
            Shutdown(0);
            return;
        }

        if (args.Contains("--dump-media"))
        {
            await DebugRender.DumpMediaAsync(_media);
            Shutdown(0);
            return;
        }

        if (TryGetArgValue(args, "--test-pause") is { } keyword)
        {
            await DebugRender.TestPauseAsync(_media, keyword);
            Shutdown(0);
            return;
        }

        if (args.Contains("--self-test"))
        {
            var code = await RunSelfTestAsync();
            Shutdown(code);
            return;
        }

        // 正常模式：托盘 + 设置窗口 + 计时
        _settingsWindow = new Views.SettingsWindow(_settings, _coordinator.PreviewBreak);

        _tray = new TrayIconHost(_planner, _settings, new TrayIconHost.Actions(
            Toggle: () => _planner.TogglePause(),
            BreakNow: () => _planner.StartBreakNow(),
            SkipBreak: _coordinator.SkipCurrentBreak,
            Preview: _coordinator.PreviewBreak,
            Settings: () => _settingsWindow.ShowAndActivate(),
            Quit: Quit));

        _planner.StateChanged += () => _tray.Refresh();

        // 开机自启勾选状态以注册表为准（重装 / 手动删除注册表项后要能反映真实情况）
        if (_settings.LaunchAtLogin != AutostartService.IsEnabled())
        {
            _settings.LaunchAtLogin = AutostartService.IsEnabled();
        }
        _settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(RestSettings.LaunchAtLogin)) return;
            if (!AutostartService.SetEnabled(_settings.LaunchAtLogin))
            {
                ConsoleBridge.Log("Rest: 写注册表失败，开机自启没生效");
            }
        };

        _tickTimer = new DispatcherTimer(DispatcherPriority.Normal)
        {
            Interval = TimeSpan.FromMilliseconds(250),
        };
        _tickTimer.Tick += (_, _) => _planner.Tick();
        _tickTimer.Start();

        _planner.Start();
        _wallpapers.PrepareNext(_settings.WallpaperMarket);

        if (!_store.TryGet(RestSettings.Keys.FirstLaunchDone, out var done) || done != "true")
        {
            _store.Set(RestSettings.Keys.FirstLaunchDone, "true");
            _settingsWindow.ShowAndActivate();
        }

        if (args.Contains("--preview"))
        {
            // 等托盘和窗口都就绪再弹，避免首个遮罩抢在 DPI 初始化之前
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                _coordinator.PreviewBreak();
            };
            timer.Start();
        }

        ConsoleBridge.Log("Rest 已启动（Windows 版）");
    }

    /// <summary>
    /// 无界面自检：给远程/CI 用来确认「装得上、跑得起来、能枚举音频」。
    /// 任何一项失败都返回非 0，方便脚本判断。
    /// </summary>
    private async Task<int> RunSelfTestAsync()
    {
        var failures = 0;

        ConsoleBridge.Log("== 1. 设置读写 ==");
        try
        {
            var probe = new RestSettings(new MemorySettingsStore());
            var span = probe.WorkSpan;
            ConsoleBridge.Log($"默认工作段 {span.TotalMinutes:0} 分钟，槽位 {probe.SlotsPerLong} 个");
            if (Math.Abs(span.TotalMinutes - 10) > 0.01) failures++;
        }
        catch (Exception ex)
        {
            ConsoleBridge.Log($"失败：{ex.Message}");
            failures++;
        }

        ConsoleBridge.Log("== 2. 调度器节奏 ==");
        try
        {
            var clock = new ManualClock();
            var planner = new BreakPlanner(new RestSettings(new MemorySettingsStore()), clock);
            planner.Start();
            clock.Advance(TimeSpan.FromMinutes(10.5));
            planner.Tick();
            ConsoleBridge.Log($"10 分钟后状态={planner.State.Phase} 类型={planner.CurrentKind}");
            if (planner.State.Phase != SchedulerPhase.Breaking) failures++;
        }
        catch (Exception ex)
        {
            ConsoleBridge.Log($"失败：{ex.Message}");
            failures++;
        }

        ConsoleBridge.Log("== 3. 音频源枚举（SMTC）==");
        try
        {
            var entries = await _media.SnapshotAsync();
            ConsoleBridge.Log($"拿到 {entries.Count} 个音频源");
            foreach (var entry in entries.Take(10))
            {
                ConsoleBridge.Log($"  {entry.Name} | 可控={entry.CanControl} | 在播={entry.IsPlaying}");
            }
            // 枚举不到不算失败（可能确实没在放东西），能跑通就算过
        }
        catch (Exception ex)
        {
            ConsoleBridge.Log($"失败：{ex.Message}");
            failures++;
        }

        ConsoleBridge.Log("== 4. 必应壁纸 ==");
        try
        {
            var item = await _wallpapers.NextAsync(_settings.WallpaperMarket);
            ConsoleBridge.Log(item is null ? "没取到（网络可能不通）" : $"取到 {item.Id}");
        }
        catch (Exception ex)
        {
            ConsoleBridge.Log($"失败：{ex.Message}");
            failures++;
        }

        ConsoleBridge.Log("== 5. 显示器 ==");
        foreach (var screen in System.Windows.Forms.Screen.AllScreens)
        {
            ConsoleBridge.Log($"  {screen.DeviceName} {screen.Bounds.Width}x{screen.Bounds.Height} " +
                              $"primary={screen.Primary} workingArea={screen.WorkingArea}");
        }

        ConsoleBridge.Log(failures == 0 ? "自检全部通过" : $"自检有 {failures} 项失败");
        return failures == 0 ? 0 : 1;
    }

    private static string? TryGetArgValue(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        // 允许 `--test-pause` 不带值（表示“随便挑一个可控的”）
        if (index < 0) return null;
        if (index + 1 >= args.Length) return string.Empty;
        var next = args[index + 1];
        return next.StartsWith("--", StringComparison.Ordinal) ? string.Empty : next;
    }

    private void Quit()
    {
        _tickTimer?.Stop();
        _settingsWindow?.CloseForShutdown();
        _tray?.Dispose();
        _coordinator?.Dispose();
        Shutdown(0);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tickTimer?.Stop();
        _tray?.Dispose();
        _coordinator?.Dispose();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        ConsoleBridge.Detach();
        base.OnExit(e);
    }

    /// <summary>自检用的可控时钟。</summary>
    private sealed class ManualClock : IClock
    {
        public DateTimeOffset Now { get; set; } = DateTimeOffset.Now;
        public void Advance(TimeSpan delta) => Now += delta;
    }
}
