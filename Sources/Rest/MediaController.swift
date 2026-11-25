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

        for app in apps {
            let bundle = Self.normalizedBundle(app.bundleID) ?? app.bundleID
            guard !seen.contains(bundle) else { continue }
            seen.insert(bundle)
            let isNow = (bundle == nowBundle)
            var source = MediaSource(bundleID: bundle,
                                     name: app.name,
                                     pid: app.pid,
                                     isNowPlaying: isNow,
                                     channel: channel(bundle, isNowPlaying: isNow))
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
                                     channel: channel(bundle, isNowPlaying: true))
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

        for index in sources.indices {
            sources[index].canNext = canNext(sources[index])
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

    /// 「下一首」只给确认是音乐内容、且确实有这条指令的应用，避免给网页视频配一个点了没反应的按钮
    private func canNext(_ source: MediaSource) -> Bool {
        if source.channel == .mediaRemote, source.isMusic, MediaRemoteBridge.isAvailable { return true }
        return PerAppMediaControl.hasNextTrackCommand(forBundleID: source.bundleID)
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

    private func channel(_ bundleID: String, isNowPlaying: Bool) -> MediaChannel {
        if isNowPlaying, MediaRemoteBridge.isAvailable { return .mediaRemote }
        // 没有 bundle id 的命令行进程（afplay 之类）既没有脚本字典也没有可点的按钮
        if bundleID.hasPrefix("pid:") { return .none }
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
        // 先确认自己真的读得到系统状态。ad-hoc 签名的构建在部分系统上会被静默拒绝
        // （查询立即返回空字典），这种情况下「暂停后 isPlaying == false」是假阳性，
        // 会被误当成暂停成功，所以宁可放弃这条通道交给脚本 / 辅助功能。
        let probe = await MediaRemoteBridge.nowPlayingInfo()
        guard !probe.isEmpty else {
            NSLog("Rest: 读不到系统 Now Playing 状态，跳过系统媒体控制")
            return false
        }
        if MediaRemoteBridge.send(.pause) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if await MediaRemoteBridge.isPlaying() == false {
                remember(source, channel: .mediaRemote, verb: "pause")
                NSLog("Rest: 用系统媒体控制暂停了 %@", source.name)
                return true
            }
        }
        // 兜底：模拟媒体键（部分播放器不响应 MediaRemote 指令）
        PerAppMediaControl.postPlayPauseKey()
        try? await Task.sleep(nanoseconds: 350_000_000)
        if await MediaRemoteBridge.isPlaying() == false {
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

    // MARK: - 下一首

    /// 只在界面确认 `canNext` 后调用：Now Playing 走系统指令，其余走脚本字典
    func next(_ source: MediaSource) async {
        if source.channel == .mediaRemote, MediaRemoteBridge.isAvailable,
           MediaRemoteBridge.send(.nextTrack) {
            NSLog("Rest: 用系统媒体控制让 %@ 切到下一首", source.name)
            return
        }
        guard PerAppMediaControl.hasNextTrackCommand(forBundleID: source.bundleID) else { return }
        _ = await PerAppMediaControl.runScriptAsync(
            "tell application id \"\(source.bundleID)\" to next track")
        NSLog("Rest: 用 AppleScript 让 %@ 切到下一首", source.name)
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
            if await MediaRemoteBridge.isPlaying() { return }
            let pid = await MediaRemoteBridge.nowPlayingPID()
            if pid > 0, pid != record.pid { return }
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
