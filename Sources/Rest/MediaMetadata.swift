import AppKit

/// 一条媒体内容的元数据（歌名 / 歌手 / 专辑）
///
/// 封面一律用应用自己的图标，不再从系统抓专辑图：图标拿得到、稳定、不用额外订阅，
/// 在休息界面里辨识度也够（能一眼看出是哪个应用在响）。
struct TrackMetadata {
    var title: String?
    var artist: String?
    var album: String?
    /// 是否音乐类内容（决定要不要给「下一首」按钮）
    var isMusic = false

    var isEmpty: Bool { title == nil && artist == nil }
}

/// 媒体元数据的两级来源：
///
///  1. **系统 Now Playing 槽位**（MediaRemote，无需授权）——歌名、歌手、专辑都有。
///     浏览器把网页里的 Media Session 元数据发布到同一个槽位，所以 Chrome / Safari 的
///     `title` 就是页签标题、`artist` 通常是站点名，正好是「哪个页签在出声」。
///  2. **AppleScript**（需要「自动化」授权）——只在 Music / Spotify / VLC / IINA 这类
///     有脚本字典的播放器上取值。用于「它没抢到 Now Playing 槽位，但确实在出声」的场景。
///  3. 都没有就只显示应用名与状态，界面会自动退回简单样式。
enum MediaMetadata {

    // MARK: - 浏览器

    private static let browserBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "org.mozilla.firefox", "company.thebrowser.Browser", "com.pushplaylabs.sidekick",
        "com.kagi.kagimacOS",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        if browserBundles.contains(bundleID) { return true }
        // 少数发行版用带后缀的 bundle id（Chrome Dev、Edge Beta 之类）
        let lower = bundleID.lowercased()
        return browserBundles.contains { base in
            lower.hasPrefix(base.lowercased() + ".") || lower == base.lowercased()
        }
    }

    // MARK: - 系统 Now Playing

    struct NowPlayingSnapshot {
        var pid: pid_t = 0
        var isPlaying = false
        var meta = TrackMetadata()
    }

    static func systemNowPlaying() async -> NowPlayingSnapshot {
        guard MediaRemoteBridge.isAvailable else { return NowPlayingSnapshot() }

        async let pidTask = MediaRemoteBridge.nowPlayingPID()
        async let playingTask = MediaRemoteBridge.isPlaying()
        async let infoTask = MediaRemoteBridge.nowPlayingInfo()
        let (processID, playing, info) = await (pidTask, playingTask, infoTask)

        var snapshot = NowPlayingSnapshot()
        snapshot.pid = processID
        snapshot.isPlaying = playing
        snapshot.meta = parse(info)
        return snapshot
    }

    private static func parse(_ info: [String: Any]) -> TrackMetadata {
        var meta = TrackMetadata()
        meta.title = text(info["kMRMediaRemoteNowPlayingInfoTitle"])
        meta.artist = text(info["kMRMediaRemoteNowPlayingInfoArtist"])
        meta.album = text(info["kMRMediaRemoteNowPlayingInfoAlbum"])

        let isMusicApp = (info["kMRMediaRemoteNowPlayingInfoIsMusicApp"] as? NSNumber)?.intValue == 1
        let mediaType = text(info["kMRMediaRemoteNowPlayingInfoMediaType"]) ?? ""
        meta.isMusic = isMusicApp || mediaType == "MRMediaRemoteMediaTypeMusic"
        return meta
    }

    private static func text(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - AppleScript 元数据

    /// 只对确认有脚本字典的播放器取值，其它应用一律不发指令
    private static func scriptSource(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Music":
            return """
            tell application id "com.apple.Music"
                try
                    set t to current track
                    return (name of t) & "␟" & (artist of t) & "␟" & (album of t)
                on error
                    return ""
                end try
            end tell
            """
        case "com.spotify.client":
            return """
            tell application id "com.spotify.client"
                try
                    set t to current track
                    return (name of t) & "␟" & (artist of t) & "␟" & (album of t)
                on error
                    return ""
                end try
            end tell
            """
        case "com.colliderli.iina":
            return """
            tell application id "com.colliderli.iina"
                try
                    set t to current track
                    return (title of t) & "␟" & (artist of t) & "␟" & (album of t)
                on error
                    return ""
                end try
            end tell
            """
        case "org.videolan.vlc":
            return """
            tell application id "org.videolan.vlc"
                try
                    return (name of current item) & "␟"
                on error
                    return ""
                end try
            end tell
            """
        default:
            return nil
        }
    }

    private static let separator = "␟"
    private static var scriptCache: [String: (meta: TrackMetadata?, at: Date)] = [:]
    private static let scriptCacheTTL: TimeInterval = 5

    static func scripted(bundleID: String) async -> TrackMetadata? {
        if let cached = scriptCache[bundleID], Date().timeIntervalSince(cached.at) < scriptCacheTTL {
            return cached.meta
        }
        guard scriptSource(for: bundleID) != nil else { return nil }
        // 没拿到「自动化」授权就别发脚本：静默返回，等用户真正授权后再显示歌名
        guard PerAppMediaControl.canAutomate(bundleID: bundleID) else {
            scriptCache[bundleID] = (nil, Date())
            return nil
        }

        let source = scriptSource(for: bundleID)!
        let output = await PerAppMediaControl.runScriptOutput(source, timeout: 2.5)

        var meta: TrackMetadata?
        if let output, !output.isEmpty {
            let fields = output.components(separatedBy: separator)
            var candidate = TrackMetadata()
            candidate.title = clean(fields, 0)
            candidate.artist = clean(fields, 1)
            candidate.album = clean(fields, 2)
            candidate.isMusic = true
            meta = candidate.isEmpty ? nil : candidate
        }

        scriptCache[bundleID] = (meta, Date())
        return meta
    }

    private static func clean(_ fields: [String], _ index: Int) -> String? {
        guard index < fields.count else { return nil }
        let value = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
