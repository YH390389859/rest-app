using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Rest.Platform.Windows.Host;

/// <summary>
/// 距离最后一次键盘 / 鼠标输入的时长。
/// 对应 macOS 的 <c>CGEventSource.secondsSinceLastEventType</c>，同样是公开 API、不需要权限。
/// </summary>
public static class IdleMonitor
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static TimeSpan SinceLastInput()
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref info)) return TimeSpan.Zero;

        // dwTime 是系统启动以来的毫秒数（32 位，约 49 天回绕），
        // 用 Environment.TickCount 的差值才不会被回绕坑到
        var elapsed = Environment.TickCount - (int)info.dwTime;
        if (elapsed < 0) elapsed = 0;
        return TimeSpan.FromMilliseconds(elapsed);
    }
}

/// <summary>
/// 开机自启。macOS 用 <c>SMAppService</c>，Windows 就是当前用户的 Run 键 ——
/// 不需要管理员权限，也不需要往启动文件夹丢快捷方式。
/// </summary>
public static class AutostartService
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Rest";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            return key?.GetValue(ValueName) is string value && value.Length > 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>返回值表示最终是否生效（写注册表可能被组策略拦掉）。</summary>
    public static bool SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (key is null) return false;

            if (enabled)
            {
                var exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe)) return false;
                key.SetValue(ValueName, $"\"{exe}\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Rest: 设置开机自启失败 {ex.Message}");
            return false;
        }
    }
}

/// <summary>提示音。macOS 用 NSSound 的系统音，这边直接播 Windows 自带的 wav。</summary>
public static class SoundFx
{
    private const uint SndAsync = 0x0001;
    private const uint SndFilename = 0x00020000;
    private const uint SndNoDefault = 0x0002;

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern bool PlaySound(string? sound, IntPtr module, uint flags);

    private static string MediaPath(string file)
        => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", file);

    public static void PlayBreakStart() => Play("Windows Notify Calendar.wav", "Windows Ding.wav");

    public static void PlayBreakEnd() => Play("Windows Notify Messaging.wav", "Windows Ding.wav");

    private static void Play(string preferred, string fallback)
    {
        var path = MediaPath(preferred);
        if (!File.Exists(path)) path = MediaPath(fallback);
        if (!File.Exists(path)) return;

        // 异步播放，避免卡住 UI 线程
        PlaySound(path, IntPtr.Zero, SndAsync | SndFilename | SndNoDefault);
    }
}
