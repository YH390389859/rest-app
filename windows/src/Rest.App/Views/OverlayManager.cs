using System.Diagnostics;
using System.Windows.Threading;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;

namespace Rest.App.Views;

/// <summary>
/// 管理「每块屏一个遮罩窗口」以及透明遮罩状态下的输入捕获。
/// 对应 <c>Sources/Rest/BreakWindowController.swift</c>。
///
/// 需要处理的三个现实问题，跟 macOS 那边一一对应：
/// 1. 多屏 / 只遮主屏 —— 由 <c>AllDisplays</c> 设置决定；
/// 2. 休息途中改分辨率、插拔外接屏 —— 监听 DisplaySettingsChanged 并整块重铺；
/// 3. 一次切换会连发好几条通知 —— 合并成一次重建（防抖 200ms）。
/// </summary>
public sealed class OverlayManager : IDisposable
{
    private readonly BreakViewModel _vm;
    private readonly List<OverlayWindow> _windows = new();
    private readonly InputHook _hook = new();
    private DispatcherTimer? _reflowTimer;
    private DispatcherTimer? _shieldTimer;
    private bool _observing;

    /// <summary>
    /// 透明遮罩刚出现时系统可能补发一次鼠标事件，留 800ms 宽限期避免「点跳过的那一下」
    /// 反过来把新遮罩关掉（和 macOS 版 shieldGrace 同一个道理）。
    /// </summary>
    private static readonly TimeSpan ShieldGrace = TimeSpan.FromMilliseconds(800);

    /// <summary>透明遮罩期间捕获到第一次输入。</summary>
    public event Action? UserReturned;

    /// <summary>该铺哪几块屏（由 Coordinator 按设置决定），分辨率变化时会再问一次。</summary>
    public Func<IReadOnlyList<WinForms.Screen>>? ScreenProvider { get; set; }

    public OverlayManager(BreakViewModel viewModel)
    {
        _vm = viewModel;
        _hook.FirstInput += () =>
        {
            if (!IsShieldActive) return;
            _vm.Mode = BreakViewMode.Running;
            UserReturned?.Invoke();
        };
    }

    public bool IsVisible => _windows.Count > 0;

    public bool IsShieldActive => _vm.Mode == BreakViewMode.Shield;

    // MARK: 显示 / 隐藏

    public void Show()
    {
        var screens = ScreenProvider?.Invoke() ?? DefaultScreens();
        BuildWindows(screens);
        ObserveDisplayChanges();

        // 只有第一块屏抢焦点（其余屏不激活，避免任务栏闪烁）
        if (_windows.Count > 0)
        {
            _windows[0].Activate();
            _windows[0].Focus();
        }
    }

    public void Dismiss()
    {
        StopShield();
        UnobserveDisplayChanges();
        CloseWindows();
        ScreenProvider = null;
    }

    /// <summary>进入全透明遮罩状态：窗口让开，改用低层钩子吃掉第一次输入。</summary>
    public void BeginShield()
    {
        if (!IsVisible) return;

        _vm.Mode = BreakViewMode.Shield;

        // 全透明的 WPF 窗口点不中，所以直接藏起来，由钩子接管
        foreach (var window in _windows)
        {
            window.Hide();
        }
        _shieldTimer ??= new DispatcherTimer();
        _shieldTimer.Interval = ShieldGrace;
        _shieldTimer.Stop();
        _shieldTimer.Tick -= OnShieldTick;
        _shieldTimer.Tick += OnShieldTick;
        _shieldTimer.Start();

        Debug.WriteLine("Rest: 进入透明遮罩，等待第一次输入");
    }

    private void OnShieldTick(object? sender, EventArgs e)
    {
        _shieldTimer?.Stop();
        if (!IsShieldActive) return;
        _hook.Start();
    }

    private void StopShield()
    {
        _shieldTimer?.Stop();
        _hook.Stop();
        if (_vm.Mode == BreakViewMode.Shield) _vm.Mode = BreakViewMode.Running;
    }

    // MARK: 窗口铺设

    private static IReadOnlyList<WinForms.Screen> DefaultScreens() => WinForms.Screen.AllScreens;

    private void BuildWindows(IReadOnlyList<WinForms.Screen> screens)
    {
        CloseWindows();

        if (screens.Count == 0) screens = DefaultScreens();

        foreach (var screen in screens)
        {
            var window = new OverlayWindow(_vm);
            // 先给个占位尺寸再按物理像素摆位，避免在副屏上先闪一下错误大小
            window.Width = 100;
            window.Height = 100;
            window.WindowStartupLocation = System.Windows.WindowStartupLocation.Manual;
            window.Left = 0;
            window.Top = 0;
            window.Show();
            window.CoverScreen(screen.Bounds, activate: _windows.Count == 0);
            _windows.Add(window);
        }
    }

    private void CloseWindows()
    {
        foreach (var window in _windows)
        {
            window.CloseForcibly();
        }
        _windows.Clear();
    }

    // MARK: 显示器变化

    private void ObserveDisplayChanges()
    {
        if (_observing) return;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        _observing = true;
    }

    private void UnobserveDisplayChanges()
    {
        if (!_observing) return;
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        _observing = false;
        _reflowTimer?.Stop();
        _reflowTimer = null;
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => ScheduleReflow();

    /// <summary>一次切换会连发好几条通知（每块屏一条），合并成一次重建。</summary>
    private void ScheduleReflow()
    {
        if (!IsVisible) return;

        _reflowTimer ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _reflowTimer.Tick -= OnReflowTick;
        _reflowTimer.Tick += OnReflowTick;
        _reflowTimer.Stop();
        _reflowTimer.Start();
    }

    private void OnReflowTick(object? sender, EventArgs e)
    {
        _reflowTimer?.Stop();
        if (!IsVisible) return;

        var screens = ScreenProvider?.Invoke() ?? DefaultScreens();
        Debug.WriteLine($"Rest: 显示器参数变化，重铺 {screens.Count} 个遮罩窗口");

        var wasShield = IsShieldActive;
        BuildWindows(screens);

        // 重铺时正在透明遮罩：窗口是新藏的，钩子还在，保持形态即可
        if (wasShield)
        {
            _vm.Mode = BreakViewMode.Shield;
            foreach (var window in _windows) window.Hide();
        }
        else if (_windows.Count > 0)
        {
            _windows[0].Activate();
        }
    }

    public void Dispose()
    {
        Dismiss();
        _hook.Dispose();
    }
}
