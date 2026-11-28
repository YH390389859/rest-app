using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using Rest.Core;

namespace Rest.App;

public enum BreakViewMode
{
    Running,
    FinishedManual,
    Shield,
}

/// <summary>
/// 休息界面 / 设置界面共用的视图模型。对应 <c>Sources/Rest/BreakViewModel.swift</c>，
/// 属性名和文案保持一致，改文案时两边都要改。
/// </summary>
public sealed class BreakViewModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private BreakKind _kind = BreakKind.Micro;
    public BreakKind Kind
    {
        get => _kind;
        set { if (_kind == value) return; _kind = value; Raise(); Raise(nameof(KindTitle)); Raise(nameof(KindCaption)); }
    }

    public string KindTitle => Kind.Title();
    public string KindCaption => Kind.Caption();

    private TimeSpan _remaining = TimeSpan.FromSeconds(20);
    public TimeSpan Remaining
    {
        get => _remaining;
        set
        {
            if (_remaining == value) return;
            _remaining = value;
            Raise();
            Raise(nameof(RemainingText));
            Raise(nameof(Progress));
        }
    }

    public string RemainingText => ClockText.FormatClock(Remaining);

    private TimeSpan _total = TimeSpan.FromSeconds(20);
    public TimeSpan Total
    {
        get => _total;
        set { if (_total == value) return; _total = value; Raise(); Raise(nameof(Progress)); }
    }

    /// <summary>环形进度：已经走过的比例。</summary>
    public double Progress => Total.TotalSeconds <= 0
        ? 0
        : Math.Clamp(1 - Remaining.TotalSeconds / Total.TotalSeconds, 0, 1);

    private BreakViewMode _mode = BreakViewMode.Running;
    public BreakViewMode Mode
    {
        get => _mode;
        set
        {
            if (_mode == value) return;
            _mode = value;
            Raise();
            Raise(nameof(FooterHint));
            Raise(nameof(IsRunning));
            Raise(nameof(IsFinishedManual));
        }
    }

    /// <summary>倒计时区域显示与否（manual 模式换成「休息结束」块）。</summary>
    public bool IsRunning => Mode is BreakViewMode.Running or BreakViewMode.Shield;

    public bool IsFinishedManual => Mode == BreakViewMode.FinishedManual;

    public string ContinueButtonText => $"开始下一轮 · {WorkLabel}";

    /// <summary>「全部暂停」按钮的可用性。</summary>
    public bool CanPauseAll => !AudioBusyAll && PausableAudioCount > 0;

    public bool HasPausableAudio => PausableAudioCount > 0;

    // MARK: 壁纸

    private ImageSource? _wallpaper;
    public ImageSource? Wallpaper
    {
        get => _wallpaper;
        set { if (ReferenceEquals(_wallpaper, value)) return; _wallpaper = value; Raise(); Raise(nameof(HasWallpaper)); }
    }

    public bool HasWallpaper => Wallpaper is not null;

    private string _wallpaperCredit = string.Empty;
    public string WallpaperCredit
    {
        get => _wallpaperCredit;
        set { if (_wallpaperCredit == value) return; _wallpaperCredit = value; Raise(); Raise(nameof(HasCredit)); }
    }

    public bool HasCredit => !string.IsNullOrEmpty(WallpaperCredit);

    // MARK: 音频

    public sealed class AudioRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler? PropertyChanged;

        public required string Id { get; init; }
        public required string Title { get; init; }
        public string? Detail { get; init; }
        public ImageSource? Icon { get; init; }
        public bool IsNowPlaying { get; init; }
        public bool CanControl { get; init; }

        private bool _paused;
        public bool Paused
        {
            get => _paused;
            set
            {
                if (_paused == value) return;
                _paused = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Paused)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(RowOpacity)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IconOpacity)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ActionGlyph)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ActionTooltip)));
            }
        }

        private bool _busy;
        public bool Busy
        {
            get => _busy;
            set
            {
                if (_busy == value) return;
                _busy = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Busy)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ShowAction)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CannotControl)));
            }
        }

        public double RowOpacity => Paused ? 0.62 : 0.98;
        public double IconOpacity => Paused ? 0.6 : 1.0;

        /// <summary>暂停中显示「播放」，播放中显示「暂停」。</summary>
        public string ActionGlyph => Paused ? "\uE768" : "\uE769";

        public bool ShowAction => CanControl && !Busy;

        public bool CannotControl => !CanControl && !Busy;

        public bool HasIcon => Icon is not null;

        public bool HasDetail => !string.IsNullOrEmpty(Detail);

        public string FallbackLetter => string.IsNullOrEmpty(Title) ? "?" : Title[..1];

        public string ActionTooltip => Paused ? "恢复播放" : "暂停";
    }

    public ObservableCollection<AudioRow> AudioRows { get; } = new();

    private bool _audioBusyAll;
    public bool AudioBusyAll
    {
        get => _audioBusyAll;
        set
        {
            if (_audioBusyAll == value) return;
            _audioBusyAll = value;
            Raise();
            Raise(nameof(PauseAllLabel));
            Raise(nameof(CanPauseAll));
        }
    }

    public string PauseAllLabel => AudioBusyAll ? "正在暂停…" : "全部暂停";

    private string? _audioNotice;
    public string? AudioNotice
    {
        get => _audioNotice;
        set { if (_audioNotice == value) return; _audioNotice = value; Raise(); Raise(nameof(HasAudioNotice)); }
    }

    public bool HasAudioNotice => !string.IsNullOrEmpty(AudioNotice);

    public string AudioHeading
    {
        get
        {
            var paused = AudioRows.Count(r => r.Paused);
            if (AudioRows.Count > 0 && paused == AudioRows.Count) return "音频 · 已全部暂停";
            return $"音频 · {AudioRows.Count} 个应用";
        }
    }

    /// <summary>还能一键暂停的（已经暂停的、不支持控制的不算）。</summary>
    public int PausableAudioCount => AudioRows.Count(r => !r.Paused && r.CanControl);

    public bool HasAudio => AudioRows.Count > 0;

    /// <summary>超过 3 个时压缩行高；最多列 5 个。</summary>
    public bool IsCompactAudio => AudioRows.Count > 3;

    public double AudioRowHeight => IsCompactAudio ? 52 : 64;

    public double AudioIconSide => IsCompactAudio ? 34 : 46;

    // MARK: 按钮状态

    private string _workLabel = "约 10 分钟";
    public string WorkLabel
    {
        get => _workLabel;
        set { if (_workLabel == value) return; _workLabel = value; Raise(); Raise(nameof(ContinueButtonText)); }
    }

    private string _postponeLabel = "5 分钟";
    public string PostponeLabel { get => _postponeLabel; set { if (_postponeLabel == value) return; _postponeLabel = value; Raise(); Raise(nameof(PostponeButtonText)); } }

    public string PostponeButtonText => $"延后 {PostponeLabel}";

    private bool _canSkip = true;
    public bool CanSkip { get => _canSkip; set { if (_canSkip == value) return; _canSkip = value; Raise(); Raise(nameof(FooterHint)); } }

    private bool _canPostpone = true;
    public bool CanPostpone { get => _canPostpone; set { if (_canPostpone == value) return; _canPostpone = value; Raise(); } }

    public string FooterHint
    {
        get
        {
            if (Mode != BreakViewMode.Running) return "点击按钮或按任意键继续";
            if (!CanSkip) return "严格模式：这次休息不能跳过";
            return "按 Esc 跳过本次休息";
        }
    }

    // MARK: 回调（由 Coordinator 挂上）

    public Action? OnSkip { get; set; }
    public Action? OnPostpone { get; set; }
    public Action? OnContinue { get; set; }
    public Action? OnExtend { get; set; }
    public Action<string>? OnToggleAudio { get; set; }
    public Action? OnPauseAllAudio { get; set; }

    /// <summary>数量可能很多，界面最多列 5 行，其余的用一行说明带过。</summary>
    public IEnumerable<AudioRow> VisibleAudioRows => AudioRows.Take(5);

    public int HiddenAudioCount => Math.Max(0, AudioRows.Count - 5);

    public bool HasHiddenAudio => HiddenAudioCount > 0;

    public string HiddenAudioText => $"还有 {HiddenAudioCount} 个应用，可用「全部暂停」一起处理";

    /// <summary>音频行数变化后需要重算标题、紧凑样式。</summary>
    public void NotifyAudioCollectionChanged()
    {
        Raise(nameof(AudioHeading));
        Raise(nameof(PausableAudioCount));
        Raise(nameof(HasAudio));
        Raise(nameof(IsCompactAudio));
        Raise(nameof(AudioRowHeight));
        Raise(nameof(AudioIconSide));
        Raise(nameof(VisibleAudioRows));
        Raise(nameof(HiddenAudioCount));
        Raise(nameof(HasHiddenAudio));
        Raise(nameof(HiddenAudioText));
        Raise(nameof(CanPauseAll));
        Raise(nameof(HasPausableAudio));
    }
}
