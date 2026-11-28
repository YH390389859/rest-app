using System.Globalization;

namespace Rest.Core;

/// <summary>设置的后端存储。macOS 版直接用 UserDefaults，Windows 版用 JSON 文件。</summary>
public interface ISettingsStore
{
    bool TryGet(string key, out string? value);
    void Set(string key, string value);
}

/// <summary>单元测试用：内存字典。</summary>
public sealed class MemorySettingsStore : ISettingsStore
{
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);

    public bool TryGet(string key, out string? value) => _values.TryGetValue(key, out value);

    public void Set(string key, string value) => _values[key] = value;
}

/// <summary>
/// 落到 <c>%APPDATA%\Rest\settings.json</c> 的键值存储。
///
/// 用 JSON 键值而不是注册表：一是好备份、好排错（用户发个文件过来就能复现），
/// 二是和 macOS 的 UserDefaults plist 结构接近，将来要写迁移工具只差一层键名映射。
/// </summary>
public sealed class JsonSettingsStore : ISettingsStore
{
    private readonly string _path;
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    public JsonSettingsStore(string path)
    {
        _path = path;
        Load();
    }

    public static string DefaultPath()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Rest");
        return Path.Combine(dir, "settings.json");
    }

    public bool TryGet(string key, out string? value)
    {
        lock (_gate) return _values.TryGetValue(key, out value);
    }

    public void Set(string key, string value)
    {
        lock (_gate)
        {
            _values[key] = value;
            Save();
        }
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            var json = File.ReadAllText(_path);
            var parsed = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, string>>(json);
            if (parsed is null) return;
            foreach (var (k, v) in parsed) _values[k] = v;
        }
        catch (Exception ex)
        {
            // 设置文件坏了不该让 App 起不来，退回默认值继续跑
            System.Diagnostics.Debug.WriteLine($"Rest: 读取设置失败 {ex.Message}");
        }
    }

    private void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            var json = System.Text.Json.JsonSerializer.Serialize(
                _values, new System.Text.Json.JsonSerializerOptions { WriteIndented = true });

            // 先写临时文件再替换：避免写到一半断电留下半个 JSON
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, _path, overwrite: true);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Rest: 保存设置失败 {ex.Message}");
        }
    }
}

/// <summary>
/// 时钟抽象。计时全靠它，测试里换成可控时钟就能把「30 分钟一轮」压缩到毫秒级跑完。
/// </summary>
public interface IClock
{
    DateTimeOffset Now { get; }
}

public sealed class SystemClock : IClock
{
    public static readonly SystemClock Instance = new();
    public DateTimeOffset Now => DateTimeOffset.Now;
}

/// <summary>时间格式化。和 Swift 版 <c>formatClock</c> 同一套规则（四舍五入、至少两位补零）。</summary>
public static class ClockText
{
    public static string FormatClock(TimeSpan span)
    {
        var total = Math.Max(0, (int)RestSettings.Round(span.TotalSeconds));
        return string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}", total / 60, total % 60);
    }
}
