import Foundation
import AppKit

/// 当前播放状态快照
struct PlaybackInfo {
    var isPlaying: Bool = false
    var pid: pid_t = 0
    var bundleID: String?
    var appName: String?
    /// 所有正在输出音频的应用（即使媒体处于暂停、流没关闭，也会出现在这里）
    var audioApps: [AudioApp] = []

    var hasAnything: Bool { isPlaying || !audioApps.isEmpty }
}

@MainActor
final class MediaController {
    static let shared = MediaController()

    struct PauseResult {
        let appName: String
        let bundleID: String?
        let pid: pid_t
        /// mediaremote / mediaKey
        let method: String
    }

    private init() {}

    // MARK: 查询

    func currentPlayback() async -> PlaybackInfo {
        var info = PlaybackInfo()
        info.audioApps = AudioActivityMonitor.outputApps()

        let pid = await MediaRemoteBridge.nowPlayingPID()
        let playing = await MediaRemoteBridge.isPlaying()

        if pid > 0 {
            info.pid = pid
            let app = NSRunningApplication(processIdentifier: pid)
            info.bundleID = app?.bundleIdentifier
            info.appName = app?.localizedName
        }
        if info.appName == nil, let first = info.audioApps.first {
            info.appName = first.name
            info.bundleID = first.bundleID
            info.pid = first.pid
        }
        info.isPlaying = playing || (pid == 0 && info.audioApps.count == 1 && MediaRemoteBridge.isAvailable == false)

        // 有 Now Playing 客户端且报告正在播放时，以它为准
        if pid > 0 { info.isPlaying = playing }
        return info
    }

    // MARK: 暂停 / 恢复

    /// 暂停当前播放中的媒体。
    /// - Parameter force: true 表示用户手动点击，即使系统说「没在播放」也尝试（有些播放器不注册 Now Playing）
    func pauseCurrentPlayback(force: Bool = false) async -> PauseResult? {
        let info = await currentPlayback()
        guard info.hasAnything else { return nil }

        let name = info.appName ?? "播放器"
        let bundle = info.bundleID
        let pid = info.pid

        if info.isPlaying || force {
            // 方案 A：MediaRemote 精确 pause（不动其它 App、不需要权限）
            if MediaRemoteBridge.send(.pause) {
                try? await Task.sleep(nanoseconds: 220_000_000)
                if !(await MediaRemoteBridge.isPlaying()) {
                    return PauseResult(appName: name, bundleID: bundle, pid: pid, method: "mediaremote")
                }
            }

            // 方案 B：模拟媒体键（部分 App 不响应 MediaRemote 指令）
            sendPlayPauseKey()
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !(await MediaRemoteBridge.isPlaying()) {
                return PauseResult(appName: name, bundleID: bundle, pid: pid, method: "mediaKey")
            }
        }

        return nil
    }

    /// 休息结束后恢复刚才被我们暂停的播放（只在仍是同一个 App、且用户没有自己开始播放时才恢复）
    func resume(_ result: PauseResult) async {
        // 用户已经自己播起来了，就别插手
        if await MediaRemoteBridge.isPlaying() { return }

        let currentPID = await MediaRemoteBridge.nowPlayingPID()
        if result.pid > 0, currentPID > 0, currentPID != result.pid { return }

        if !MediaRemoteBridge.send(.play) {
            sendPlayPauseKey()
        }
    }

    // MARK: 媒体键兜底

    /// 合成一次「播放/暂停」媒体键事件（NX_KEYTYPE_PLAY = 16）。
    /// 需要「辅助功能」授权，未授权时会被系统静默丢弃，因此只作为兜底。
    private func sendPlayPauseKey() {
        func post(isDown: Bool) {
            let flags: UInt = isDown ? 0xa00 : 0xb00
            guard let event = NSEvent.otherEvent(with: .systemDefined,
                                                 location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: 0,
                                                 context: nil,
                                                 subtype: 8,
                                                 data1: 16 << 16,
                                                 data2: -1) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        post(isDown: true)
        usleep(30_000)
        post(isDown: false)
    }
}
