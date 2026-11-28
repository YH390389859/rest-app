using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;

namespace Rest.App.Views;

/// <summary>
/// 一块屏幕上的遮罩窗口。
///
/// 和 macOS 版的差异：那边窗口必须能成为 key window 才能拿到键盘事件，所以用了
/// <c>canBecomeKey</c> + 全局 NSEvent 监听两个通道；Windows 这边窗口本身就是普通的
/// 顶层窗口，键盘事件天然能收到，只需要保证它盖在最上层、不进 Alt+Tab、不被当作普通窗口。
/// </summary>
public sealed class OverlayWindow : Window
{
    private const int GwlExStyle = -20;
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;

    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;

    private static readonly IntPtr HwndTopmost = new(-1);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int x, int y, int cx, int cy, uint flags);

    public BreakView View { get; }

    public OverlayWindow(BreakViewModel viewModel)
    {
        View = new BreakView { DataContext = viewModel };

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = false;      // 遮罩本来就是不透明的，走普通窗口性能好得多
        Background = System.Windows.Media.Brushes.Black;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Content = View;
        Cursor = Cursors.Arrow;
        Focusable = true;

        KeyDown += (_, e) =>
        {
            View.HandleKey(e.Key);
            e.Handled = true;
        };

        // 遮罩期间禁止最小化 / 关闭（不拦的话 Alt+F4 能把它干掉）
        Closing += (_, e) =>
        {
            if (!_allowClose) e.Cancel = true;
        };
        StateChanged += (_, _) =>
        {
            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        };
    }

    private bool _allowClose;

    /// <summary>按屏幕的物理像素铺满。用 SetWindowPos 而不是 Left/Top/Width/Height，
    /// 免去多屏不同缩放下的 DIP 换算。</summary>
    public void CoverScreen(System.Drawing.Rectangle bounds, bool activate)
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero)
        {
            // 还没建句柄，先显示再挪
            Show();
            handle = new WindowInteropHelper(this).Handle;
        }

        var exStyle = GetWindowLong(handle, GwlExStyle);
        exStyle |= WsExToolWindow;
        if (!activate) exStyle |= WsExNoActivate;
        SetWindowLong(handle, GwlExStyle, exStyle);

        SetWindowPos(handle, HwndTopmost, bounds.X, bounds.Y, bounds.Width, bounds.Height,
            SwpNoActivate | SwpShowWindow);
    }

    public void CloseForcibly()
    {
        _allowClose = true;
        try { Close(); } catch { /* 已经关了 */ }
    }
}
