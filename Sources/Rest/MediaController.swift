import Foundation
import AppKit

/// 音频源枚举、按应用暂停 / 恢复。
///
/// 系统层面只有一个「Now Playing」槽位，多播放器同时出声时 MediaRemote 只认其中一个，
/// 所以这里以 CoreAudio 的输出进程列表为「有哪些应用在出声」的准绳，再逐个应用
/// 挑选可用的控制通道（见 `PerAppMediaControl`）。
@MainActor
final class MediaController {
    static let shared = MediaController()
    private init() {}

    /// 被我们暂停过的应用，休息结束时用来恢复
    private struct PausedRecord {
        let bundleID: String
        let pid: pid_t
        let channel: MediaChannel
        /// AppleScript 用的动词，恢复时取它的反义
        let verb: String
    }

    private var paused: [String: PausedRecord] = [:]
    private var scriptableCache: [String: Bool] = [:]

    func isPaused(_ bundleID: String) -> Bool { paused[bundleID] != nil }

    // MARK: - 快照

    func snapshot() async -> [MediaSource] {
        let apps = AudioActivityMonitor.outputApps()
        let nowPlaying = await MediaMetadata.systemNowPlaying()

        var nowBundle: String?
        var nowPID: pid_t = 0
        var nowName: String?
        if nowPlaying.pid > 0, let app = NSRunningApplication(processIdentifier: nowPlaying.pid) {
            nowBundle = Self.normalizedBundle(app.bundleIdentifier)
            nowPID = nowPlaying.pid
            nowName = app.localizedName
        }

        var sources: [MediaSource] = []
        var seen = Set<String>()
        // 系统里只有一个应用在出声时，Now Playing 槽位必然是它。即使我们读不到
        // Now Playing 的 PID（受限签名会被系统静默拒绝），也能安全地用系统命令控制。
        let soleOutput = apps.count == 1

        for app in apps {
            let bundle = Self.normalizedBundle(app.bundleID) ?? app.bundleID
            guard !seen.contains(bundle) else { continue }
            seen.insert(bundle)
            let isNow = (bundle == nowBundle)
            var source = MediaSource(bundleID: bundle,
                                     name: app.name,
                                     pid: app.pid,
                                     isNowPlaying: isNow,
                                     channel: channel(bundle, isNowPlaying: isNow, soleOutput: soleOutput))
            source.isBrowser = MediaMetadata.isBrowser(bundle)
            if isNow { apply(nowPlaying.meta, to: &source) }
            sources.append(source)
        }

        // Now Playing 在播放但没出现在输出列表里（AirPlay、或刚切歌的瞬间），补一条
        if nowPlaying.isPlaying, let bundle = nowBundle, !seen.contains(bundle) {
            seen.insert(bundle)
            var source = MediaSource(bundleID: bundle,
                                     name: nowName ?? bundle,
                                     pid: nowPID,
                                     isNowPlaying: true,
                                     channel: channel(bundle, isNowPlaying: true, soleOutput: soleOutput))
            source.isBrowser = MediaMetadata.isBrowser(bundle)
            apply(nowPlaying.meta, to: &source)
            sources.append(source)
        }

        // 系统槽位只放得下一个应用：其余正在出声的播放器用各自脚本字典补歌名
        for index in sources.indices where !sources[index].isNowPlaying {
            guard index < 4, sources[index].channel == .appleScript else { continue }
            if let meta = await MediaMetadata.scripted(bundleID: sources[index].bundleID) {
                apply(meta, to: &sources[index])
            }
        }

        // Now Playing 排最前，其余按名称
        return sources.sorted { lhs, rhs in
            if lhs.isNowPlaying != rhs.isNowPlaying { return lhs.isNowPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func apply(_ meta: TrackMetadata, to source: inout MediaSource) {
        if let title = meta.title { source.title = title }
        if let artist = meta.artist { source.artist = artist }
        if let album = meta.album { source.album = album }
        if meta.isMusic { source.isMusic = true }
    }

    /// Chromium / WebKit 的媒体会话挂在 helper 进程上，归并到主应用
    private static func normalizedBundle(_ bundle: String?) -> String? {
        guard let bundle, !bundle.isEmpty else { return nil }
        if bundle.contains(".helper") {
            let base = bundle.components(separatedBy: ".helper").first ?? bundle
            if NSRunningApplication.runningApplications(withBundleIdentifier: base).first != nil {
                return base
            }
        }
        return bundle
    }

    // MARK: - 通道判定

    private func channel(_ bundleID: String, isNowPlaying: Bool, soleOutput: Bool = false) -> MediaChannel {
        if isNowPlaying, MediaRemoteBridge.isAvailable { return .mediaRemote }
        // 没有 bundle id 的命令行进程（afplay 之类）既没有脚本字典也没有可点的按钮
        if bundleID.hasPrefix("pid:") { return .none }
        // 读不到 Now Playing 但系统里只有它在出声：槽位必然是它。有脚本字典的播放器
        // 优先走脚本（恢复更可靠），浏览器这类没脚本的用系统命令，绕开辅助功能。
        if soleOutput, MediaRemoteBridge.isAvailable, !isScriptable(bundleID) { return .mediaRemote }
        if isScriptable(bundleID) { return .appleScript }
        // 剩下的一律尝试辅助功能：没授权时点击会引导去授权，而不是直接判死
        return .accessibility
    }

    private func isScriptable(_ bundleID: String) -> Bool {
        if let cached = scriptableCache[bundleID] { return cached }
        let verbs = PerAppMediaControl.scriptingVerbs(forBundleID: bundleID)
        let result = verbs.contains { $0 != "play" }
        scriptableCache[bundleID] = result
        return result
    }

    // MARK: - 暂停

    @discardableResult
    func pause(_ source: MediaSource) async -> MediaChannel? {
        switch source.channel {
        case .mediaRemote:
            return await pauseNowPlaying(source) ? .mediaRemote : nil

        case .appleScript:
            let verbs = PerAppMediaControl.scriptingVerbs(forBundleID: source.bundleID)
            for verb in verbs where verb != "play" {
                let ok = await PerAppMediaControl.runScriptAsync(
                    "tell application id \"\(source.bundleID)\" to \(verb)")
                if ok {
                    remember(source, channel: .appleScript, verb: verb)
                    NSLog("Rest: 用 AppleScript(%@) 暂停了 %@", verb, source.name)
                    return .appleScript
                }
            }
            NSLog("Rest: %@ 的脚本通道没成功", source.name)
            return nil

        case .accessibility:
            guard PerAppMediaControl.accessibilityTrusted else {
                NSLog("Rest: 未获得辅助功能授权，无法控制 %@", source.name)
                return nil
            }
            let pid = source.pid
            if await PerAppMediaControl.pressPlayPauseAsync(pid: pid) {
                remember(source, channel: .accessibility, verb: "pause")
                NSLog("Rest: 用辅助功能暂停了 %@", source.name)
                return .accessibility
            }
            NSLog("Rest: 在 %@ 里没找到「暂停」按钮", source.name)
            return nil

        case .none:
            return nil
        }
    }

    private func pauseNowPlaying(_ source: MediaSource) async -> Bool {
        // 直接下发暂停，**不要**以「能否读到 Now Playing 数据」作为前提。
        // 查不到数据只说明我们没权限读，命令本身仍然会投递给当前 Now Playing 的应用
        // （Chrome / Safari 的网页 Media Session 就靠这条通道，辅助功能反而点不到它的自绘控件）。
        if MediaRemoteBridge.send(.pause) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            switch await MediaRemoteBridge.playingState() {
            case .some(false):
                remember(source, channel: .mediaRemote, verb: "pause")
                NSLog("Rest: 用系统媒体控制暂停了 %@", source.name)
                return true

            case .none:
                // 读不到状态：命令已投递，按成功处理。系统 Now Playing 通道对这类应用
                // 一直是有效的，判失败只会让界面误报「没响应」，也会丢掉恢复记录。
                remember(source, channel: .mediaRemote, verb: "pause")
                NSLog("Rest: 已向 %@ 下发暂停（读不到播放状态，按成功处理）", source.name)
                return true

            case .some(true):
                break   // 确实还在播，走兜底
            }
        }

        // 兜底：模拟媒体键（部分播放器不响应 MediaRemote 指令）
        PerAppMediaControl.postPlayPauseKey()
        try? await Task.sleep(nanoseconds: 350_000_000)
        if await MediaRemoteBridge.playingState() != .some(true) {
            remember(source, channel: .mediaRemote, verb: "pause")
            NSLog("Rest: 用媒体键暂停了 %@", source.name)
            return true
        }
        NSLog("Rest: 系统媒体控制没能暂停 %@", source.name)
        return false
    }

    private func remember(_ source: MediaSource, channel: MediaChannel, verb: String) {
        paused[source.bundleID] = PausedRecord(bundleID: source.bundleID,
                                               pid: source.pid,
                                               channel: channel,
                                               verb: verb)
    }

    // MARK: - 恢复

    func resume(bundleID: String) async {
        guard let record = paused.removeValue(forKey: bundleID) else { return }
        await resume(record)
    }

    func resumeAll() async {
        let records = Array(paused.values)
        paused.removeAll()
        for record in records {
            await resume(record)
        }
    }

    func discardPaused() { paused.removeAll() }

    private func resume(_ record: PausedRecord) async {
        switch record.channel {
        case .mediaRemote:
            // 用户自己播起来了，或者换了播放器，就别插手
            if await MediaRemoteBridge.playingState() == .some(true) { return }
            let pid = await MediaRemoteBridge.nowPlayingPID()
            if pid > 0, pid != record.pid { return }
            if pid == 0 {
                // 读不到槽位归属：确认原来的应用还活着再发命令，
                // 否则可能把「刚打开的其他播放器」当成目标播起来
                let alive = NSRunningApplication(processIdentifier: record.pid) != nil
                    || !NSRunningApplication.runningApplications(withBundleIdentifier: record.bundleID).isEmpty
                guard alive else { return }
            }
            if !MediaRemoteBridge.send(.play) {
                PerAppMediaControl.postPlayPauseKey()
            }

        case .appleScript:
            guard !isOutputting(record.bundleID) else { return }
            let verb = record.verb == "playpause" ? "playpause" : "play"
            _ = await PerAppMediaControl.runScriptAsync(
                "tell application id \"\(record.bundleID)\" to \(verb)")

        case .accessibility:
            guard !isOutputting(record.bundleID) else { return }
            _ = await PerAppMediaControl.pressPlayPauseAsync(pid: record.pid)

        case .none:
            break
        }
    }

    /// 这个应用现在是否又在输出音频（说明用户已经自己恢复了）
    private func isOutputting(_ bundleID: String) -> Bool {
        AudioActivityMonitor.outputApps().contains {
            $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID)
        }
    }
}
