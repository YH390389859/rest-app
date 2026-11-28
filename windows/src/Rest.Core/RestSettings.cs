using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Rest.Core;

/// <summary>
/// 设置模型。刻意和 macOS 版（<c>AppSettings</c>）保持同名同默认值：
/// 两边行为要一致，改这里就得同步改 <c>Sources/Rest/AppSettings.swift</c>。
///
/// 与 Swift 版的差异只有一处：读写落到 <see cref="ISettingsStore"/> 而不是 UserDefaults，
/// 这样核心库不依赖任何平台 API，单元测试里可以塞内存实现。
/// </summary>
public sealed class RestSettings : INotifyPropertyChanged
{
    /// <summary>键名沿用 macOS 的 UserDefaults key，方便以后写迁移工具。</summary>
    public static class Keys
    {
        public const string MicroEnabled = "microBreakEnabled";
        public const string Micro = "microBreakSeconds";
        public const string MicroEvery = "microBreakEveryMinutes";
        public const string MicroAllowPostpone = "microAllowPostpone";
        public const string MicroStrict = "microStrictMode";
        public const string LongEnabled = "longBreakEnabled";
        public const string Long = "longBreakMinutes";
        public const string LongSlots = "microsBeforeLong";
        public const string LongAllowPostpone = "longAllowPostpone";
        public const string LongStrict = "longStrictMode";
        public const string EndBehavior = "breakEndBehavior";
        public const string AutoPause = "autoPauseMedia";
        public const string Resume = "resumeMediaAfterBreak";
        public const string Bing = "useBingWallpaper";
        public const string Market = "wallpaperMarket";
        public const string AllDisplays = "allDisplays";
        public const string Sound = "playSound";
        public const string Idle = "skipWhenIdle";
        public const string Postpone = "postponeMinutes";
        public const string LaunchAtLogin = "launchAtLogin";
        public const string FirstLaunchDone = "didFirstLaunch";
    }

    private readonly ISettingsStore _store;
    private bool _loaded;

    public event PropertyChangedEventHandler? PropertyChanged;

    public RestSettings(ISettingsStore store)
    {
        _store = store;
        Load();
        _loaded = true;
    }

    // MARK: 小憩

    private bool _microEnabled = true;
    public bool MicroEnabled { get => _microEnabled; set => Set(ref _microEnabled, value, Keys.MicroEnabled); }

    private double _microBreakSeconds = 20;
    public double MicroBreakSeconds { get => _microBreakSeconds; set => Set(ref _microBreakSeconds, value, Keys.Micro); }

    private double _microBreakEveryMinutes = 10;
    public double MicroBreakEveryMinutes { get => _microBreakEveryMinutes; set => Set(ref _microBreakEveryMinutes, value, Keys.MicroEvery); }

    private bool _microAllowPostpone = true;
    public bool MicroAllowPostpone { get => _microAllowPostpone; set => Set(ref _microAllowPostpone, value, Keys.MicroAllowPostpone); }

    private bool _microStrictMode;
    public bool MicroStrictMode { get => _microStrictMode; set => Set(ref _microStrictMode, value, Keys.MicroStrict); }

    // MARK: 休息

    private bool _longEnabled = true;
    public bool LongEnabled { get => _longEnabled; set => Set(ref _longEnabled, value, Keys.LongEnabled); }

    private double _longBreakMinutes = 5;
    public double LongBreakMinutes { get => _longBreakMinutes; set => Set(ref _longBreakMinutes, value, Keys.Long); }

    /// <summary>
    /// 和 Stretchly 的 <c>longBreakInterval</c> 同义：这次休息之前要经过几次小憩。
    /// 休息的「每 N 分钟」= 小憩间隔 × (MicrosBeforeLong + 1)。
    /// </summary>
    private double _microsBeforeLong = 2;
    public double MicrosBeforeLong { get => _microsBeforeLong; set => Set(ref _microsBeforeLong, value, Keys.LongSlots); }

    private bool _longAllowPostpone = true;
    public bool LongAllowPostpone { get => _longAllowPostpone; set => Set(ref _longAllowPostpone, value, Keys.LongAllowPostpone); }

    private bool _longStrictMode;
    public bool LongStrictMode { get => _longStrictMode; set => Set(ref _longStrictMode, value, Keys.LongStrict); }

    // MARK: 行为

    private BreakEndBehavior _breakEndBehavior = BreakEndBehavior.WaitForInput;
    public BreakEndBehavior BreakEndBehavior { get => _breakEndBehavior; set => Set(ref _breakEndBehavior, value, Keys.EndBehavior); }

    private bool _autoPauseMedia = true;
    public bool AutoPauseMedia { get => _autoPauseMedia; set => Set(ref _autoPauseMedia, value, Keys.AutoPause); }

    private bool _resumeMediaAfterBreak = true;
    public bool ResumeMediaAfterBreak { get => _resumeMediaAfterBreak; set => Set(ref _resumeMediaAfterBreak, value, Keys.Resume); }

    private bool _useBingWallpaper = true;
    public bool UseBingWallpaper { get => _useBingWallpaper; set => Set(ref _useBingWallpaper, value, Keys.Bing); }

    private string _wallpaperMarket = "zh-CN";
    public string WallpaperMarket { get => _wallpaperMarket; set => Set(ref _wallpaperMarket, value, Keys.Market); }

    private bool _allDisplays = true;
    public bool AllDisplays { get => _allDisplays; set => Set(ref _allDisplays, value, Keys.AllDisplays); }

    private bool _playSound = true;
    public bool PlaySound { get => _playSound; set => Set(ref _playSound, value, Keys.Sound); }

    private bool _skipWhenIdle = true;
    public bool SkipWhenIdle { get => _skipWhenIdle; set => Set(ref _skipWhenIdle, value, Keys.Idle); }

    private double _postponeMinutes = 5;
    public double PostponeMinutes { get => _postponeMinutes; set => Set(ref _postponeMinutes, value, Keys.Postpone); }

    /// <summary>
    /// 只负责持久化这个布尔值，真正写注册表由平台层做（Core 不碰 Windows API）。
    /// </summary>
    private bool _launchAtLogin;
    public bool LaunchAtLogin { get => _launchAtLogin; set => Set(ref _launchAtLogin, value, Keys.LaunchAtLogin); }

    // MARK: 计算属性（与 Swift 版逐条对应）

    public TimeSpan MicroBreakDuration => TimeSpan.FromSeconds(Math.Max(5, MicroBreakSeconds));

    /// <summary>小憩间隔，也就是每一段工作的长度（Stretchly 的 miniBreakInterval）。</summary>
    public TimeSpan MicroBreakInterval => TimeSpan.FromSeconds(Math.Max(60, MicroBreakEveryMinutes * 60));

    public TimeSpan LongBreakDuration => TimeSpan.FromSeconds(Math.Max(30, LongBreakMinutes * 60));

    public TimeSpan PostponeDuration => TimeSpan.FromSeconds(Math.Max(60, PostponeMinutes * 60));

    /// <summary>一个休息周期有几个「槽位」：MicrosBeforeLong 次小憩 + 1 次休息。</summary>
    public int SlotsPerLong => Math.Max(2, (int)Round(MicrosBeforeLong) + 1);

    /// <summary>休息周期总时长 = 小憩间隔 × 槽位数（默认 10 分 × 3 = 30 分）。</summary>
    public TimeSpan LongCycleSeconds => MicroBreakInterval * SlotsPerLong;

    public double LongCycleMinutes => Round(LongCycleSeconds.TotalSeconds / 60);

    /// <summary>只开休息、关掉小憩时，一段工作就直接排到一个完整周期。</summary>
    public TimeSpan WorkSpan => MicroEnabled ? MicroBreakInterval : LongCycleSeconds;

    public bool IsEnabled(BreakKind kind) => kind == BreakKind.Long ? LongEnabled : MicroEnabled;

    public bool IsStrict(BreakKind kind) => kind == BreakKind.Long ? LongStrictMode : MicroStrictMode;

    public bool AllowsPostpone(BreakKind kind)
    {
        if (!IsEnabled(kind) || IsStrict(kind)) return false;
        return kind == BreakKind.Long ? LongAllowPostpone : MicroAllowPostpone;
    }

    public bool AllowsSkip(BreakKind kind) => !IsStrict(kind);

    /// <summary>下一轮工作大概多长（用于「开始下一轮」按钮文案）。</summary>
    public string NextWorkLabel
    {
        get
        {
            var minutes = (int)Round(WorkSpan.TotalSeconds / 60);
            return $"约 {Math.Max(1, minutes)} 分钟";
        }
    }

    /// <summary>空闲超过这个时长，认为人不在电脑前，休息没意义。</summary>
    public TimeSpan IdleThreshold => TimeSpan.FromSeconds(120);

    /// <summary>
    /// Swift 的 <c>rounded()</c> 是「四舍五入、.5 向远离零」，而 C# <c>Math.Round</c> 默认银行家舍入
    /// （2.5 → 2）。不显式指定就会在 2.5 → 3 这种边界上跟 macOS 版算出不同的槽位数。
    /// </summary>
    public static double Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero);

    // MARK: 持久化

    private static readonly string[] DerivedNames =
    {
        nameof(SlotsPerLong), nameof(LongCycleSeconds), nameof(LongCycleMinutes),
        nameof(WorkSpan), nameof(NextWorkLabel), nameof(MicroBreakInterval),
        nameof(MicroBreakDuration), nameof(LongBreakDuration), nameof(PostponeDuration),
    };

    private void Load()
    {
        if (_store.TryGet(Keys.MicroEnabled, out var v) && bool.TryParse(v, out var b)) _microEnabled = b;
        if (_store.TryGet(Keys.Micro, out v) && double.TryParse(v, out var d)) _microBreakSeconds = d;
        if (_store.TryGet(Keys.MicroEvery, out v) && double.TryParse(v, out d)) _microBreakEveryMinutes = d;
        if (_store.TryGet(Keys.MicroAllowPostpone, out v) && bool.TryParse(v, out b)) _microAllowPostpone = b;
        if (_store.TryGet(Keys.MicroStrict, out v) && bool.TryParse(v, out b)) _microStrictMode = b;
        if (_store.TryGet(Keys.LongEnabled, out v) && bool.TryParse(v, out b)) _longEnabled = b;
        if (_store.TryGet(Keys.Long, out v) && double.TryParse(v, out d)) _longBreakMinutes = d;
        if (_store.TryGet(Keys.LongSlots, out v) && double.TryParse(v, out d)) _microsBeforeLong = d;
        if (_store.TryGet(Keys.LongAllowPostpone, out v) && bool.TryParse(v, out b)) _longAllowPostpone = b;
        if (_store.TryGet(Keys.LongStrict, out v) && bool.TryParse(v, out b)) _longStrictMode = b;
        if (_store.TryGet(Keys.EndBehavior, out v) && Enum.TryParse<BreakEndBehavior>(v, out var e)) _breakEndBehavior = e;
        if (_store.TryGet(Keys.AutoPause, out v) && bool.TryParse(v, out b)) _autoPauseMedia = b;
        if (_store.TryGet(Keys.Resume, out v) && bool.TryParse(v, out b)) _resumeMediaAfterBreak = b;
        if (_store.TryGet(Keys.Bing, out v) && bool.TryParse(v, out b)) _useBingWallpaper = b;
        if (_store.TryGet(Keys.Market, out v) && !string.IsNullOrEmpty(v)) _wallpaperMarket = v;
        if (_store.TryGet(Keys.AllDisplays, out v) && bool.TryParse(v, out b)) _allDisplays = b;
        if (_store.TryGet(Keys.Sound, out v) && bool.TryParse(v, out b)) _playSound = b;
        if (_store.TryGet(Keys.Idle, out v) && bool.TryParse(v, out b)) _skipWhenIdle = b;
        if (_store.TryGet(Keys.Postpone, out v) && double.TryParse(v, out d)) _postponeMinutes = d;
        if (_store.TryGet(Keys.LaunchAtLogin, out v) && bool.TryParse(v, out b)) _launchAtLogin = b;
    }

    private void Set<T>(ref T field, T value, string key, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        if (_loaded) _store.Set(key, value switch
        {
            bool b => b ? "true" : "false",
            double d => d.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
            Enum en => en.ToString(),
            _ => value?.ToString() ?? string.Empty,
        });
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

        // 派生值跟着变（设置界面里「约每 N 分钟」「下一轮约 N 分钟」要实时更新）
        foreach (var derived in DerivedNames)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(derived));
        }
    }
}
