using System.Windows;
using System.Windows.Media;
using Rest.Core;

namespace Rest.App.Views;

/// <summary>
/// 设置窗口。macOS 版是 <c>SettingsWindowController</c> + SwiftUI Form，
/// 这边用普通 Window 套 <see cref="SettingsView"/>，标题栏跟随系统。
/// </summary>
public sealed class SettingsWindow : Window
{
    private readonly SettingsView _view;
    private bool _allowClose;

    public SettingsWindow(RestSettings settings, Action onPreview)
    {
        Title = "Rest 设置";
        Width = 580;
        Height = 800;
        MinWidth = 540;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF7));
        ShowInTaskbar = true;

        _view = new SettingsView
        {
            DataContext = settings,
            PreviewRequested = onPreview,
        };
        Content = _view;

        // 关窗只是隐藏，托盘和计时继续跑（和 macOS 版一致）
        Closing += (_, e) =>
        {
            if (_allowClose) return;
            e.Cancel = true;
            Hide();
        };
    }

    public void ShowAndActivate()
    {
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;   // 只借一下前台权限，别一直压着别的窗口
        Focus();
    }

    public SettingsView View => _view;

    /// <summary>真正退出时调用（否则窗口关不掉，进程会留一个隐藏窗口）。</summary>
    public void CloseForShutdown()
    {
        _allowClose = true;
        Close();
    }
}
