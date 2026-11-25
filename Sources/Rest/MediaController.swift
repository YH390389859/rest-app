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
        let playingPID = await MediaRemoteBridge.nowPlayingPID()
        let isPlaying = await MediaRemoteBridge.isPlaying()

        var nowBundle: String?
        var nowPID: pid_t = 0
        var nowName: String?
        if playingPID > 0, let app = NSRunningApplication(processIdentifier: playingPID) {
            nowBundle = Self.normalizedBundle(app.bundleIdentifier)
            nowPID = playingPID
            nowName = app.localizedName
        }

        var sources: [MediaSource] = []
        var seen = Set<String>()

        for app in apps {
            let bundle = Self.normalizedBundle(app.bundleID) ?? app.bundleID
            guard !seen.contains(bundle) else { continue }
            seen.insert(bundle)
            let isNow = (bundle == nowBundle)
            sources.append(MediaSource(bundleID: bundle,
                                       name: app.name,
                                       pid: app.pid,
                                       title: nil,
                                       isNowPlaying: isNow,
                                       channel: channel(bundle, isNowPlaying: isNow)))
        }

        // Now Playing 在播放但没出现在输出列表里（AirPlay、或刚切歌的瞬间），补一条
        if isPlaying, let bundle = nowBundle, !seen.contains(bundle) {
            seen.insert(bundle)
            sources.append(MediaSource(bundleID: bundle,
                                       name: nowName ?? bundle,
                                       pid: nowPID,
                                       title: nil,
                                       isNowPlaying: true,
                                       channel: channel(bundle, isNowPlaying: true)))
        }

        // 标题只有 Now Playing 那个能拿到
        if let index = sources.firstIndex(where: { $0.isNowPlaying }),
           let title = await nowPlayingTitle() {
            sources[index].title = title
        }

        // Now Playing 排最前，其余按名称
        return sources.sorted { lhs, rhs in
            if lhs.isNowPlaying != rhs.isNowPlaying { return lhs.isNowPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func nowPlayingTitle() async -> String? {
        let info = await MediaRemoteBridge.nowPlayingInfo()
        func str(_ key: String) -> String? {
            guard let raw = info[key] as? String else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let title = str("kMRMediaRemoteNowPlayingInfoTitle")
        let artist = str("kMRMediaRemoteNowPlayingInfoArtist")
        if let title, let artist { return "\(title) · \(artist)" }
        return title
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
