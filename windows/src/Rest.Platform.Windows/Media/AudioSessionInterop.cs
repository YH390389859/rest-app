using System.Runtime.InteropServices;

namespace Rest.Platform.Windows.Media;

/// <summary>
/// Windows Core Audio 的「音频会话」枚举：找出**当前真的有输出流**的进程。
///
/// 为什么需要它：SMTC（系统媒体传输控件）的会话列表里既有正在播的，也有暂停的、
/// 甚至只是打开过的播放器。macOS 版靠 CoreAudio 的 `IsRunningOutput` 做「谁在出声」的准绳，
/// 这边对应的就是 IAudioSessionManager2 → State == Active。
///
/// 全部是公开 API，不需要任何权限、不需要驱动、不需要注入。
/// </summary>
internal static class AudioSessionInterop
{
    private const int DeviceStateActive = 0x1;
    private const int DataFlowRender = 0;         // eRender：输出设备
    private const int RoleMultimedia = 1;         // eMultimedia

    internal enum AudioSessionState
    {
        Inactive = 0,
        Active = 1,
        Expired = 2,
    }

    public sealed record OutputSession(int Pid, AudioSessionState State);

    /// <summary>列出所有在输出设备上注册了音频会话的进程。失败时返回空表，调用方退回 SMTC。</summary>
    public static IReadOnlyList<OutputSession> EnumerateOutputSessions()
    {
        var result = new List<OutputSession>();
        IMMDeviceEnumerator? enumerator = null;
        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();

            if (enumerator.GetDefaultAudioEndpoint(DataFlowRender, RoleMultimedia, out var device) != 0 || device is null)
            {
                return result;
            }

            var iid = typeof(IAudioSessionManager2).GUID;
            if (device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out var managerObj) != 0
                || managerObj is not IAudioSessionManager2 manager)
            {
                return result;
            }

            if (manager.GetSessionEnumerator(out var sessions) != 0 || sessions is null) return result;
            if (sessions.GetCount(out var count) != 0) return result;

            for (var i = 0; i < count; i++)
            {
                if (sessions.GetSession(i, out var control) != 0 || control is null) continue;
                if (control is not IAudioSessionControl2 control2) continue;

                // 系统提示音（Windows 自己的叮咚）不算「用户在播放东西」
                if (control2.IsSystemSoundsSession() == 0) continue;
                if (control2.GetProcessId(out var pid) != 0 || pid <= 0) continue;
                if (control.GetState(out var state) != 0) continue;

                result.Add(new OutputSession(pid, (AudioSessionState)state));
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Rest: 枚举音频会话失败 {ex.Message}");
        }
        finally
        {
            if (enumerator is not null) Marshal.ReleaseComObject(enumerator);
        }

        return result;
    }

    /// <summary>这个进程当前是否有 Active 的输出会话（等价于 macOS 的 IsRunningOutput）。</summary>
    public static bool IsOutputting(int pid)
        => EnumerateOutputSessions().Any(s => s.Pid == pid && s.State == AudioSessionState.Active);

    // MARK: COM 声明（顺序不能动，vtable 必须严格对齐）

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject
    {
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
        int OpenPropertyStore(int access, out IntPtr properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2
    {
        int GetAudioSessionControl(IntPtr audioSessionGuid, int flags, out IAudioSessionControl sessionControl);
        int GetSimpleAudioVolume(IntPtr audioSessionGuid, int flags, out IntPtr audioVolume);
        int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnumerator);
        int RegisterSessionNotification(IntPtr sessionNotification);
        int UnregisterSessionNotification(IntPtr sessionNotification);
        int RegisterDuckNotification([MarshalAs(UnmanagedType.LPWStr)] string sessionId, IntPtr duckNotification);
        int UnregisterDuckNotification(IntPtr duckNotification);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator
    {
        int GetCount(out int count);
        int GetSession(int index, out IAudioSessionControl session);
    }

    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl
    {
        int GetState(out int state);
        int GetDisplayName(out IntPtr name);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid eventContext);
        int GetIconPath(out IntPtr path);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid eventContext);
        int GetGroupingParam(out Guid groupingParam);
        int SetGroupingParam(ref Guid groupingParam, ref Guid eventContext);
        int RegisterAudioSessionNotification(IntPtr clientNotification);
        int UnregisterAudioSessionNotification(IntPtr clientNotification);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2
    {
        // IAudioSessionControl 的方法必须原样排在前九个
        int GetState(out int state);
        int GetDisplayName(out IntPtr name);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid eventContext);
        int GetIconPath(out IntPtr path);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string value, ref Guid eventContext);
        int GetGroupingParam(out Guid groupingParam);
        int SetGroupingParam(ref Guid groupingParam, ref Guid eventContext);
        int RegisterAudioSessionNotification(IntPtr clientNotification);
        int UnregisterAudioSessionNotification(IntPtr clientNotification);

        int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string sessionIdentifier);
        int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string instanceIdentifier);
        int GetProcessId(out int pid);
        int IsSystemSoundsSession();
        int SetDuckingPreference(bool optOut);
    }
}
