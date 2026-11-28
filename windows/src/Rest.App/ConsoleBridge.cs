using System.Runtime.InteropServices;

namespace Rest.App;

/// <summary>
/// 让 WinExe 也能在命令行里输出。WPF 应用默认没有控制台，SSH / CI 里跑
/// 自检和截图时必须有一个能回看得见的地方 —— 这条路径决定了「远程调试是否可行」。
/// </summary>
public static class ConsoleBridge
{
    private const int AttachParentProcess = -1;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    private static TextWriter? _fileWriter;

    /// <summary>接管父进程的控制台；失败时退回写日志文件，绝不抛异常。</summary>
    public static void Attach(string? logPath = null)
    {
        try
        {
            var attached = AttachParentProcess < 0 && AttachConsole(AttachParentProcess);
            if (!attached) attached = AllocConsole();
            if (attached)
            {
                var stdout = Console.OpenStandardOutput();
                var writer = new StreamWriter(stdout) { AutoFlush = true };
                Console.SetOut(writer);
                Console.SetError(writer);
            }
        }
        catch
        {
            // 没有控制台就算了，下面还有文件兜底
        }

        if (string.IsNullOrEmpty(logPath)) logPath = DefaultLogPath();
        try
        {
            var dir = Path.GetDirectoryName(logPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var stream = new FileStream(logPath, FileMode.Create, FileAccess.Write, FileShare.Read);
            _fileWriter = new StreamWriter(stream) { AutoFlush = true };
        }
        catch
        {
            // 日志文件也写不了就只能在调试器里看了
        }
    }

    public static string DefaultLogPath()
        => Path.Combine(Path.GetTempPath(), "rest-debug.log");

    public static void Log(string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss.fff}] {message}";
        try { Console.WriteLine(line); } catch { }
        try { _fileWriter?.WriteLine(line); } catch { }
    }

    public static void Detach()
    {
        try { _fileWriter?.Flush(); } catch { }
        try { FreeConsole(); } catch { }
    }
}
