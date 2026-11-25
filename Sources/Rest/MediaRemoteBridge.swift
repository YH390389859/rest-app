import Foundation

/// MediaRemote 是 macOS 上「系统级 Now Playing」的背后框架（私有 API）。
/// 用它可以在不获得任何权限、不依赖 AppleScript 的情况下：
///   1. 查出当前是哪个 App 在播放；
///   2. 向它下发 play / pause（和键盘上的媒体键效果一致，但不需要辅助功能授权）。
///
/// 它随系统发布、符号稳定，macOS 11 ~ 26 均可使用。若某天被移除，MediaController 会
/// 自动降级为模拟媒体键。
enum MediaRemoteBridge {

    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
    }

    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (pid_t) -> Void) -> Void
    private typealias GetBoolFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    }()

    static var isAvailable: Bool { handle != nil }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// 一次性触发盒，避免 continuation 被重复 resume（回调 + 超时竞争）
    private final class OnceBox: @unchecked Sendable {
        private var fired = false
        private let lock = NSLock()
        func fire(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !fired else { return }
            fired = true
            body()
        }
    }

    private static let callbackQueue = DispatchQueue(label: "rest.mediaremote.callback", qos: .userInitiated)

    // MARK: 查询

    /// 当前 Now Playing 的进程 PID，0 表示没有
    static func nowPlayingPID(timeout: TimeInterval = 1.2) async -> pid_t {
        guard let fn = symbol("MRMediaRemoteGetNowPlayingApplicationPID", as: GetPIDFn.self) else { return 0 }
        return await withCheckedContinuation { continuation in
            let box = OnceBox()
            fn(callbackQueue) { pid in
                box.fire { continuation.resume(returning: pid) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.fire { continuation.resume(returning: 0) }
            }
        }
    }

    /// 当前媒体是否真的在播放中（暂停时为 false）
    static func isPlaying(timeout: TimeInterval = 1.2) async -> Bool {
        guard let fn = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetBoolFn.self) else { return false }
        return await withCheckedContinuation { continuation in
            let box = OnceBox()
            fn(callbackQueue) { playing in
                box.fire { continuation.resume(returning: playing) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.fire { continuation.resume(returning: false) }
            }
        }
    }

    /// 当前媒体的标题 / 播放速率等信息
    static func nowPlayingInfo(timeout: TimeInterval = 1.2) async -> [String: Any] {
        guard let fn = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self) else { return [:] }
        return await withCheckedContinuation { continuation in
            let box = OnceBox()
            fn(callbackQueue) { dict in
                let info = (dict as? [String: Any]) ?? [:]
                box.fire { continuation.resume(returning: info) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.fire { continuation.resume(returning: [:]) }
            }
        }
    }

    // MARK: 控制

    @discardableResult
    static func send(_ command: Command) -> Bool {
        guard let fn = symbol("MRMediaRemoteSendCommand", as: SendCommandFn.self) else { return false }
        return fn(command.rawValue, nil)
    }
}
