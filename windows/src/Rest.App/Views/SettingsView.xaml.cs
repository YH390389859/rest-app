using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Rest.Core;

namespace Rest.App.Views;

public partial class SettingsView : UserControl
{
    private sealed record Market(string Code, string Name);

    private static readonly Market[] Markets =
    {
        new("zh-CN", "中国"),
        new("en-US", "美国"),
        new("ja-JP", "日本"),
        new("en-GB", "英国"),
        new("de-DE", "德国"),
        new("fr-FR", "法国"),
    };

    private RestSettings? _settings;

    /// <summary>点「预览休息界面」时由外部挂上（跳到遮罩试看，不写入设置）。</summary>
    public Action? PreviewRequested { get; set; }

    public SettingsView()
    {
        InitializeComponent();

        MarketBox.ItemsSource = Markets;

        DataContextChanged += (_, _) => Bind();
        Loaded += (_, _) => Bind();
    }

    private void Bind()
    {
        if (_settings is not null)
        {
            _settings.PropertyChanged -= OnSettingsChanged;
        }

        _settings = DataContext as RestSettings;
        if (_settings is null) return;

        _settings.PropertyChanged += OnSettingsChanged;
        UpdateEndBehaviorDetail();

        if (MarketBox.SelectedValue is null) MarketBox.SelectedValue = _settings.WallpaperMarket;
    }

    private void OnSettingsChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(RestSettings.BreakEndBehavior)) UpdateEndBehaviorDetail();
    }

    private void UpdateEndBehaviorDetail()
    {
        if (_settings is null) return;
        EndBehaviorDetail.Text = _settings.BreakEndBehavior.Detail();
    }

    private void OnPreviewClick(object sender, RoutedEventArgs e) => PreviewRequested?.Invoke();

    private void OnOpenDataFolderClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Rest");
            Directory.CreateDirectory(dir);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{dir}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Rest: 打开数据目录失败 {ex.Message}");
        }
    }
}
