import Foundation
import AppKit

/// 暂停某个应用时实际动用的通道。
///
/// MediaRemote 的定向指令（`MRMediaRemoteSendCommandToApp`）只对持有
/// `com.apple.mediaremote.send-commands` 私有 entitlement 的进程生效，
/// 第三方签名的 App 调用时所有指令都会被重定向到「当前 Now Playing 播放器」。
/// 所以除 Now Playing 之外的应用，只能走它们自己的通道。
enum MediaChannel: String {
    /// 系统级媒体控制，只作用于系统当前认定的 Now Playing 应用
    case mediaRemote
    /// 目标应用脚本字典里声明了 pause / playpause
    case appleScript
    /// 通过辅助功能找到它的「暂停」按钮按下去
    case accessibility
    case none

    var isControllable: Bool { self != .none }
}

/// 一个正在占用音频输出的应用
struct MediaSource: Identifiable {
    let bundleID: String
    var name: String
    var pid: pid_t
    var isNowPlaying: Bool
    var channel: MediaChannel

    // MARK: 元数据

    /// 歌名 / 视频标题 / 浏览器页签标题
    var title: String?
    var artist: String?
    var album: String?
    var isBrowser = false
    var isMusic = false

    var id: String { bundleID }

    /// 标题优先用媒体信息，拿不到就退回应用名
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return name
    }

    /// 副标题：音乐是「歌手 · 专辑」，浏览器是站点名
    var displayDetail: String? {
        var parts: [String] = []
        if let artist, !artist.isEmpty { parts.append(artist) }
        if let album, !album.isEmpty, album != artist { parts.append(album) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func icon() -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSRunningApplication(processIdentifier: pid)?.icon
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
