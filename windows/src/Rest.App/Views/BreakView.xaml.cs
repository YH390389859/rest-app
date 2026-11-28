using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Rest.App.Views;

/// <summary>
/// 遮罩上的休息界面。布局照着 <c>Sources/Rest/BreakView.swift</c> 逐块搬过来，
/// 事件一律转给 <see cref="BreakViewModel"/> 的回调，界面自己不调度。
/// </summary>
public partial class BreakView : UserControl
{
    public BreakView()
    {
        InitializeComponent();
    }

    private BreakViewModel? ViewModel => DataContext as BreakViewModel;

    private void OnSkipClick(object sender, RoutedEventArgs e) => ViewModel?.OnSkip?.Invoke();

    private void OnPostponeClick(object sender, RoutedEventArgs e) => ViewModel?.OnPostpone?.Invoke();

    private void OnContinueClick(object sender, RoutedEventArgs e) => ViewModel?.OnContinue?.Invoke();

    private void OnExtendClick(object sender, RoutedEventArgs e) => ViewModel?.OnExtend?.Invoke();

    private void OnPauseAllClick(object sender, RoutedEventArgs e) => ViewModel?.OnPauseAllAudio?.Invoke();

    private void OnToggleAudioClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: BreakViewModel.AudioRow row })
        {
            ViewModel?.OnToggleAudio?.Invoke(row.Id);
        }
    }

    /// <summary>休息进行中按 Esc = 跳过（严格模式下 <c>OnSkip</c> 那边会被拦掉）。</summary>
    public void HandleEscape()
    {
        var vm = ViewModel;
        if (vm is null) return;
        if (vm.Mode != BreakViewMode.Running) return;
        vm.OnSkip?.Invoke();
    }

    public void HandleKey(Key key)
    {
        if (key == Key.Escape) HandleEscape();
    }
}
