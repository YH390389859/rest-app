using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Rest.Core;

namespace Rest.Platform.Windows.Wallpaper;

public sealed record WallpaperItem(string FilePath, string Credit, string Id);

/// <summary>
/// 必应每日壁纸。移植自 <c>Sources/Rest/WallpaperService.swift</c>，逻辑保持一致：
///
/// 需求是「每次进入休息都换一张」，而 <c>idx=0&amp;n=1</c> 一天只有一张图，所以取 <c>n=8</c>
/// （必应保留的最近 8 天），用持久化游标在它们之间轮换，并按图片 id 缓存文件 ——
/// 同一张图第二次用到就不再下载。
///
/// 另外提供 <see cref="PrepareNextAsync"/>：显示当前这张的同时后台把下一张拉好，
/// 这样下一次休息是「立刻」出现新壁纸，不用等网络。
/// </summary>
public sealed class BingWallpaperService
{
    private static readonly HttpClient Http = CreateClient();

    private readonly ISettingsStore _store;
    private readonly Dictionary<string, WallpaperItem> _preloaded = new(StringComparer.Ordinal);
    private readonly HashSet<string> _preparing = new(StringComparer.Ordinal);

    public BingWallpaperService(ISettingsStore store) => _store = store;

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Rest/1.0 (Windows)");
        return client;
    }

    public static string CacheDirectory
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Rest", "wallpapers");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    // MARK: 对外

    /// <summary>取一张新的壁纸（游标轮换，并跳过与上一张重复的）。</summary>
    public async Task<WallpaperItem?> NextAsync(string market)
    {
        var items = await FetchArchiveAsync(market);
        if (items is null || items.Count == 0) return LatestCached();

        var cursorKey = $"wallpaperCursor-{market}";
        var lastKey = $"wallpaperLast-{market}";

        var cursor = ReadInt(cursorKey);
        var picked = items[cursor % items.Count];
        if (items.Count > 1 && ReadString(lastKey) == picked.Id)
        {
            cursor++;
            picked = items[cursor % items.Count];
        }
        cursor++;
        _store.Set(cursorKey, cursor.ToString(CultureInfo.InvariantCulture));
        _store.Set(lastKey, picked.Id);

        Debug.WriteLine($"Rest: 本次壁纸 {picked.Id}");
        return await DownloadAsync(picked) ?? LatestCached();
    }

    /// <summary>取走已预取好的那一张（有则立刻可用）。</summary>
    public WallpaperItem? TakePreloaded(string market)
    {
        if (!_preloaded.TryGetValue(market, out var item)) return null;
        _preloaded.Remove(market);
        return item;
    }

    /// <summary>后台准备下一张。</summary>
    public void PrepareNext(string market)
    {
        if (_preloaded.ContainsKey(market) || !_preparing.Add(market)) return;

        _ = Task.Run(async () =>
        {
            try
            {
                var item = await NextAsync(market);
                if (item is not null) _preloaded[market] = item;
            }
            finally
            {
                _preparing.Remove(market);
            }
        });
    }

    // MARK: 内部

    private sealed record Item(string Id, Uri Url, string Credit);

    private async Task<List<Item>?> FetchArchiveAsync(string market)
    {
        try
        {
            var url = $"https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt={Uri.EscapeDataString(market)}";
            using var response = await Http.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;

            using var stream = await response.Content.ReadAsStreamAsync();
            using var doc = await JsonDocument.ParseAsync(stream);
            if (!doc.RootElement.TryGetProperty("images", out var images)) return null;

            var items = new List<Item>();
            foreach (var image in images.EnumerateArray())
            {
                if (!image.TryGetProperty("url", out var urlProp)) continue;
                var path = urlProp.GetString();
                if (string.IsNullOrEmpty(path)) continue;

                if (path.StartsWith('/')) path = "https://www.bing.com" + path;
                path += (path.Contains('?') ? "&" : "?") + "uhd=1&uhdwidth=3840&uhdheight=2160";
                if (!Uri.TryCreate(path, UriKind.Absolute, out var uri)) continue;

                var credit = image.TryGetProperty("copyright", out var c) ? c.GetString() ?? "" : "";
                items.Add(new Item(SafeId(path), uri, credit));
            }
            return items;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Rest: 拉取必应壁纸列表失败 {ex.Message}");
            return null;
        }
    }

    /// <summary>从 <c>...&amp;id=OHR.Xxx_ZH-CN12345_1920x1080.jpg&amp;...</c> 取出稳定的图片 id。</summary>
    private static string SafeId(string path)
    {
        string raw;
        var idIndex = path.IndexOf("id=", StringComparison.Ordinal);
        if (idIndex >= 0)
        {
            raw = path[(idIndex + 3)..];
            var amp = raw.IndexOf('&');
            if (amp >= 0) raw = raw[..amp];
        }
        else
        {
            // FNV-1a：Swift 版同款，保证同一 URL 得到同一个缓存文件名
            ulong hash = 14695981039346656037;
            foreach (var b in System.Text.Encoding.UTF8.GetBytes(path)) hash = (hash ^ b) * 1099511628211;
            raw = hash.ToString("x", CultureInfo.InvariantCulture);
        }

        var cleaned = new string(raw.Where(c => char.IsLetterOrDigit(c) || c is '.' or '_' or '-').ToArray());
        return cleaned.Length == 0 ? "bing" : cleaned[..Math.Min(80, cleaned.Length)];
    }

    private async Task<WallpaperItem?> DownloadAsync(Item item)
    {
        var file = Path.Combine(CacheDirectory, item.Id + ".jpg");
        var creditFile = Path.Combine(CacheDirectory, item.Id + ".txt");

        if (File.Exists(file))
        {
            var credit = string.IsNullOrEmpty(item.Credit)
                ? (File.Exists(creditFile) ? await File.ReadAllTextAsync(creditFile) : "")
                : item.Credit;
            return new WallpaperItem(file, credit, item.Id);
        }

        try
        {
            var bytes = await Http.GetByteArrayAsync(item.Url);
            // 原图已经是必应的 UHD jpg，不再重新编码，直接落盘
            await File.WriteAllBytesAsync(file, bytes);
            await File.WriteAllTextAsync(creditFile, item.Credit);
            TrimCache();
            return new WallpaperItem(file, item.Credit, item.Id);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Rest: 下载壁纸失败 {ex.Message}");
            return null;
        }
    }

    private WallpaperItem? LatestCached()
    {
        try
        {
            var files = Directory.GetFiles(CacheDirectory, "*.jpg");
            if (files.Length == 0) return null;

            var newest = files.OrderByDescending(File.GetLastWriteTimeUtc).First();
            var creditFile = Path.ChangeExtension(newest, ".txt");
            var credit = File.Exists(creditFile) ? File.ReadAllText(creditFile) : "";
            return new WallpaperItem(newest, credit, Path.GetFileNameWithoutExtension(newest));
        }
        catch
        {
            return null;
        }
    }

    /// <summary>只保留最近 24 张，避免缓存无限增长。</summary>
    private static void TrimCache()
    {
        try
        {
            var files = Directory.GetFiles(CacheDirectory, "*.jpg");
            if (files.Length <= 24) return;

            foreach (var old in files.OrderByDescending(File.GetLastWriteTimeUtc).Skip(24))
            {
                File.Delete(old);
                var credit = Path.ChangeExtension(old, ".txt");
                if (File.Exists(credit)) File.Delete(credit);
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Rest: 清理壁纸缓存失败 {ex.Message}");
        }
    }

    private int ReadInt(string key)
        => _store.TryGet(key, out var v) && int.TryParse(v, out var value) ? value : 0;

    private string? ReadString(string key)
        => _store.TryGet(key, out var v) ? v : null;
}
