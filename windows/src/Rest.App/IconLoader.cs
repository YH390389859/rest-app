using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Rest.App;

/// <summary>
/// 从可执行文件里抽应用图标。对应 macOS 的 <c>NSWorkspace.shared.icon(forFile:)</c>。
/// 结果按路径缓存 —— 每 5 秒刷新一次音频列表，重复抽图标没必要。
/// </summary>
public static class IconLoader
{
    private static readonly ConcurrentDictionary<string, ImageSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static ImageSource? FromExecutable(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        return Cache.GetOrAdd(path, static p =>
        {
            try
            {
                using var icon = System.Drawing.Icon.ExtractAssociatedIcon(p);
                if (icon is null) return null;

                var handle = icon.ToBitmap().GetHbitmap();
                try
                {
                    var source = Imaging.CreateBitmapSourceFromHBitmap(
                        handle, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    source.Freeze();   // 冻结后才能跨线程 / 给缓存复用
                    return source;
                }
                finally
                {
                    DeleteObject(handle);
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Rest: 读取图标失败 {ex.Message}");
                return null;
            }
        });
    }

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    /// <summary>从文件路径读壁纸，读进来就 Freeze，避免遮罩关掉后文件被占用。</summary>
    public static ImageSource? LoadImage(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        try
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.CreateOptions = BitmapCreateOptions.IgnoreImageCache;
            bitmap.UriSource = new Uri(path, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Rest: 加载壁纸失败 {ex.Message}");
            return null;
        }
    }
}
