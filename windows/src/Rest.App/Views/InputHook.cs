using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace Rest.App.Views;

/// <summary>
/// 低层键盘 / 鼠标钩子，用于「透明遮罩 + 任意操作才继续」这个模式。
///
/// 为什么不用窗口收事件：全透明的 WPF 窗口在 alpha=0 的区域会被系统判定为「点透」，
/// 鼠标根本落不到窗口上。macOS 那边靠 NSEvent 全局监听解决，Windows 这边对应的就是
/// WH_KEYBOARD_LL / WH_MOUSE_LL —— 不需要管理员权限，也不需要驱动。
///
/// 第一次输入会被吞掉（返回 1），和 macOS 版「捕获到第一次动作才关闭遮罩」一致。
/// </summary>
public sealed class InputHook : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WhMouseLl = 14;

    private const int WmKeyDown = 0x0100;
    private const int WmSysKeyDown = 0x0104;
    private const int WmLButtonDown = 0x0201;
    private const int WmRButtonDown = 0x0204;
    private const int WmMButtonDown = 0x0207;
    private const int WmMouseWheel = 0x020A;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    // 委托必须用字段持有，否则被 GC 回收后回调会直接崩掉（这是 LL 钩子的经典坑）
    private readonly HookProc _keyboardProc;
    private readonly HookProc _mouseProc;
    private IntPtr _keyboardHook;
    private IntPtr _mouseHook;
    private bool _fired;

    /// <summary>捕获到第一次输入。会在钩子的消息线程上触发，注意切回 UI 线程。</summary>
    public event Action? FirstInput;

    public InputHook()
    {
        _keyboardProc = KeyboardCallback;
        _mouseProc = MouseCallback;
    }

    public void Start()
    {
        if (_keyboardHook != IntPtr.Zero) return;
        _fired = false;
        var module = GetModuleHandle(null);
        _keyboardHook = SetWindowsHookEx(WhKeyboardLl, _keyboardProc, module, 0);
        _mouseHook = SetWindowsHookEx(WhMouseLl, _mouseProc, module, 0);
        Debug.WriteLine($"Rest: 输入钩子 keyboard={_keyboardHook} mouse={_mouseHook}");
    }

    public void Stop()
    {
        if (_keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_keyboardHook);
            _keyboardHook = IntPtr.Zero;
        }
        if (_mouseHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_mouseHook);
            _mouseHook = IntPtr.Zero;
        }
    }

    private IntPtr KeyboardCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var message = wParam.ToInt32();
            if (message is WmKeyDown or WmSysKeyDown)
            {
                return Swallow();
            }
        }
        return CallNextHookEx(_keyboardHook, nCode, wParam, lParam);
    }

    private IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var message = wParam.ToInt32();
            if (message is WmLButtonDown or WmRButtonDown or WmMButtonDown or WmMouseWheel)
            {
                return Swallow();
            }
        }
        return CallNextHookEx(_mouseHook, nCode, wParam, lParam);
    }

    /// <summary>只吞第一次；之后立刻卸钩子，避免用户正常操作一直被打断。</summary>
    private IntPtr Swallow()
    {
        if (_fired) return CallNextHookEx(IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero);

        _fired = true;
        Stop();
        // 钩子回调是同步的，必须用 BeginInvoke 回到 UI 线程再关遮罩，
        // 直接在回调里关窗口会卡住输入队列
        Dispatcher.CurrentDispatcher.BeginInvoke(new Action(() => FirstInput?.Invoke()));
        return new IntPtr(1);
    }

    public void Dispose() => Stop();
}
