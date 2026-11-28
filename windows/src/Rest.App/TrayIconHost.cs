using System.Diagnostics;
using Rest.Core;
using WinForms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace Rest.App;

/// <summary>
/// 托盘图标 + 右键菜单。对应 <c>Sources/Rest/StatusBarController.swift</c>。
///
/// 菜单是每次打开时重建的（对应 NSMenuDelegate 的 menuNeedsUpdate），
/// 这样「暂停计时 / 继续计时」「严格模式不能跳过」这些状态相关的文案永远是最新的。
/// </summary>
public sealed class TrayIconHost : IDisposable
{
    public sealed record Actions(
        Action Toggle,
        Action BreakNow,
        Action SkipBreak,
        Action Preview,
        Action Settings,
        Action Quit);

    private readonly BreakPlanner _planner;
    private readonly RestSettings _settings;
    private readonly Actions _actions;
    private readonly WinForms.NotifyIcon _icon;
    private readonly WinForms.ContextMenuStrip _menu;

    public TrayIconHost(BreakPlanner planner, RestSettings settings, Actions actions)
    {
        _planner = planner;
        _settings = settings;
        _actions = actions;

        _icon = new WinForms.NotifyIcon
        {
            Icon = LoadIcon(),
            Visible = true,
            ContextMenuStrip = new WinForms.ContextMenuStrip(),
        };
        _menu = _icon.ContextMenuStrip!;
        _menu.Opening += (_, _) => BuildMenu();

        // 左键单击：直接打开设置，等价于 macOS 点状态栏图标弹出菜单里的第一项
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == WinForms.MouseButtons.Left) _actions.Settings();
        };

        Refresh();
    }

    private static Drawing.Icon LoadIcon()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exe))
            {
                var icon = Drawing.Icon.ExtractAssociatedIcon(exe);
                if (icon is not null) return icon;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Rest: 读取托盘图标失败 {ex.Message}");
        }
        return Drawing.SystemIcons.Application;
    }

    /// <summary>托盘提示文字跟着倒计时走（对应 macOS 的 statusItem.button.title）。</summary>
    public void Refresh()
    {
        var text = "Rest · " + _planner.StatusText;
        // NotifyIcon.Text 上限 63 个字符，超了会直接抛异常
        _icon.Text = text.Length <= 63 ? text : text[..63];
    }

    // MARK: 菜单

    private void BuildMenu()
    {
        _menu.Items.Clear();

        _menu.Items.Add(InfoItem(HeaderText()));

        if (_planner.State.Phase == SchedulerPhase.Working)
        {
            _menu.Items.Add(InfoItem($"下次{_planner.UpcomingKind.Title()} 大约 {EtaText} 后"));
            if (_planner.UpcomingKind == BreakKind.Micro && _planner.MicrosBeforeNextLong is { } n && n > 0)
            {
                _menu.Items.Add(InfoItem($"下次休息 {n} 次小憩后"));
            }
        }

        _menu.Items.Add(new WinForms.ToolStripSeparator());

        switch (_planner.State.Phase)
        {
            case SchedulerPhase.Stopped:
                _menu.Items.Add(Item("开始计时", _actions.Toggle));
                break;

            case SchedulerPhase.Working:
                _menu.Items.Add(Item(_planner.State.Paused ? "继续计时" : "暂停计时", _actions.Toggle));
                break;

            default:
                var kind = _planner.CurrentKind ?? BreakKind.Micro;
                var allowed = _settings.AllowsSkip(kind);
                var skip = Item(allowed ? "跳过当前休息" : "严格模式：不能跳过", _actions.SkipBreak);
                skip.Enabled = allowed;
                _menu.Items.Add(skip);
                break;
        }

        _menu.Items.Add(Item("立即休息", _actions.BreakNow));
        _menu.Items.Add(Item("预览休息界面", _actions.Preview));
        _menu.Items.Add(new WinForms.ToolStripSeparator());
        _menu.Items.Add(Item("设置…", _actions.Settings));
        _menu.Items.Add(Item("退出 Rest", _actions.Quit));
    }

    private static WinForms.ToolStripMenuItem Item(string text, Action action)
    {
        var item = new WinForms.ToolStripMenuItem(text);
        item.Click += (_, _) => action();
        return item;
    }

    private static WinForms.ToolStripMenuItem InfoItem(string text)
        => new(text) { Enabled = false };

    private string EtaText
    {
        get
        {
            var seconds = _planner.Remaining.TotalSeconds;
            if (seconds < 60) return $"{Math.Round(seconds)} 秒";
            return $"{Math.Round(seconds / 60)} 分钟";
        }
    }

    private string HeaderText() => _planner.State.Phase switch
    {
        SchedulerPhase.Stopped => "未开始",
        SchedulerPhase.Working => _planner.State.Paused
            ? $"已暂停 · 剩余 {ClockText.FormatClock(_planner.Remaining)}"
            : $"工作中 · 剩余 {ClockText.FormatClock(_planner.Remaining)}",
        SchedulerPhase.Breaking => $"{_planner.State.Kind.Title()}中 · 剩余 {ClockText.FormatClock(_planner.Remaining)}",
        _ => "休息已结束，等待继续",
    };

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }
}
