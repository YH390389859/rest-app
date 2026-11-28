using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Rest.Core;
using Rest.Platform.Windows.Media;

namespace Rest.App;

/// <summary>
/// 离屏渲染休息界面 / 设置界面到 PNG。
/// 对应 macOS 版的 <c>DebugRender.swift</c>（那边的 <c>--render</c>）。
///
/// 这个功能在 Windows 上比在 macOS 上更重要：远程（SSH）连到一台机器时看不到桌面，
/// 但可以把界面渲染成图片再传出来看，不用靠人肉截图。
/// </summary>
public static class DebugRender
{
    public static void RenderBreak(string path, RestSettings settings, int width = 2560, int height = 1440)
    {
        var vm = new BreakViewModel
        {
            Kind = BreakKind.Long,
            Total = TimeSpan.FromMinutes(5),
            Remaining = TimeSpan.FromMinutes(3.28),
            Mode = BreakViewMode.Running,
            WorkLabel = settings.NextWorkLabel,
            PostponeLabel = $"{(int)settings.PostponeMinutes} 分钟",
            CanSkip = true,
            CanPostpone = true,
            Wallpaper = TryPickWallpaper(),
            WallpaperCredit = "必应每日壁纸（示例）",
        };

        // 造两行音频示例，验证卡片布局（真运行时来自 SMTC）
        vm.AudioRows.Add(new BreakViewModel.AudioRow
        {
            Id = "demo-chrome",
            Title = "Somewhere Over the Rainbow",
            Detail = "Israel Kamakawiwoʻole · Facing Future",
            CanControl = true,
        });
        vm.AudioRows.Add(new BreakViewModel.AudioRow
        {
            Id = "demo-spotify",
            Title = "Spotify",
            Detail = "正在播放",
            CanControl = false,
        });
        vm.NotifyAudioCollectionChanged();

        var view = new Views.BreakView { DataContext = vm };
        Render(view, path, width, height);
    }

    public static void RenderSettings(string path, RestSettings settings, int width = 580, int height = 800)
    {
        var view = new Views.SettingsView { DataContext = settings };
        Render(view, path, width, height);
    }

    private static ImageSource? TryPickWallpaper()
    {
        try
        {
            var dir = Rest.Platform.Windows.Wallpaper.BingWallpaperService.CacheDirectory;
            var file = Directory.GetFiles(dir, "*.jpg")
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
            return IconLoader.LoadImage(file);
        }
        catch
        {
            return null;
        }
    }

    private static void Render(FrameworkElement element, string path, int width, int height)
    {
        element.Width = width;
        element.Height = height;
        element.Measure(new Size(width, height));
        element.Arrange(new Rect(0, 0, width, height));
        element.UpdateLayout();

        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(element);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));

        var dir = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        using var stream = File.Create(path);
        encoder.Save(stream);

        ConsoleBridge.Log($"已渲染 {path} ({width}x{height})");
    }

    /// <summary>打印当前「谁在出声」，排查媒体控制问题用。</summary>
    public static async Task DumpMediaAsync(MediaService media)
    {
        var entries = await media.SnapshotAsync();
        ConsoleBridge.Log($"音频源 {entries.Count} 个：");
        foreach (var entry in entries)
        {
            ConsoleBridge.Log($"  [{entry.AppKey}] {entry.Name} pid={entry.Pid} " +
                              $"playing={entry.IsPlaying} controllable={entry.CanControl} " +
                              $"title={entry.Title ?? "-"} artist={entry.Artist ?? "-"}");
        }
    }

    /// <summary>对当前音频源执行一次暂停 / 恢复，验证通道是否真的可用。</summary>
    public static async Task TestPauseAsync(MediaService media, string keyword)
    {
        var entries = (await media.SnapshotAsync()).ToList();
        var target = entries.FirstOrDefault(e =>
            keyword.Length == 0
                ? e.CanControl
                : e.Name.Contains(keyword, StringComparison.OrdinalIgnoreCase)
                  || e.AppKey.Contains(keyword, StringComparison.OrdinalIgnoreCase));

        if (target is null)
        {
            ConsoleBridge.Log($"没找到匹配「{keyword}」的音频源");
            return;
        }

        ConsoleBridge.Log($"尝试暂停 {target.Name} ({target.AppKey})");
        var ok = await media.PauseAsync(target);
        ConsoleBridge.Log(ok ? "暂停成功，2 秒后恢复" : "暂停失败");

        if (ok)
        {
            await Task.Delay(2000);
            await media.ResumeAsync(target.AppKey);
            ConsoleBridge.Log("已恢复");
        }
    }
}
