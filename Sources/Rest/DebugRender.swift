import AppKit
import SwiftUI

/// 调试用：把休息界面离屏渲染成 PNG，方便在没有录屏权限的环境里检查排版。
@MainActor
enum DebugRender {
    static func run(path: String) {
        let chromeIcon = NSWorkspace.shared.icon(forFile: "/Applications/Google Chrome.app")
        let musicIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")

        func row(_ id: String,
                 _ title: String,
                 detail: String?,
                 icon: NSImage?,
                 nowPlaying: Bool = false,
                 channel: MediaChannel = .accessibility,
                 paused: Bool = false) -> BreakViewModel.AudioRow {
            BreakViewModel.AudioRow(id: id, title: title, detail: detail,
                                    icon: icon, isNowPlaying: nowPlaying, channel: channel,
                                    paused: paused, busy: false)
        }

        Task {
            var wallpaper: NSImage?
            var credit = ""
            if let w = await WallpaperService.nextWallpaper(market: "zh-CN") {
                wallpaper = w.image
                credit = w.credit
            }

            @MainActor func makeVM(remaining: Double, mode: BreakViewModel.Mode) -> BreakViewModel {
                let vm = BreakViewModel()
                vm.kind = .micro
                vm.total = 20
                vm.remaining = remaining
                vm.mode = mode
                vm.workLabel = "10 分钟"
                vm.postponeLabel = "5 分钟"
                vm.wallpaper = wallpaper
                vm.wallpaperCredit = credit
                return vm
            }

            // 1. 多音频源：音乐 + 浏览器页签 + 已暂停的第三方播放器
            let multi = makeVM(remaining: 12, mode: .running)
            multi.audioRows = [
                row("com.apple.Music", "Where You Taking My Baby?", detail: "BC Camplight · A Sober Conversation",
                    icon: musicIcon, nowPlaying: true,
                    channel: .mediaRemote),
                row("com.google.Chrome", "Harvard CS50's Introduction to Computer Science", detail: "freeCodeCamp.org",
                    icon: chromeIcon, channel: .mediaRemote),
                row("com.netease.163music", "晴天", detail: "周杰伦 · 叶惠美",
                    icon: nil, channel: .appleScript, paused: true)
            ]
            render(vm: multi, size: CGSize(width: 1440, height: 900), to: path)

            // 2. 全部暂停
            let paused = makeVM(remaining: 8, mode: .running)
            paused.audioRows = [
                row("com.apple.Music", "Where You Taking My Baby?", detail: "BC Camplight · A Sober Conversation",
                    icon: musicIcon, nowPlaying: true,
                    channel: .mediaRemote, paused: true),
                row("com.google.Chrome", "Harvard CS50's Introduction to Computer Science", detail: "freeCodeCamp.org",
                    icon: chromeIcon, channel: .mediaRemote, paused: true)
            ]
            render(vm: paused, size: CGSize(width: 1440, height: 900),
                   to: path.replacingOccurrences(of: ".png", with: "-paused.png"))

            // 3. 五个音频源（超过 3 行要压缩）
            let many = makeVM(remaining: 15, mode: .running)
            many.audioRows = [
                row("a", "Where You Taking My Baby?", detail: "BC Camplight · A Sober Conversation",
                    icon: musicIcon, nowPlaying: true, channel: .mediaRemote),
                row("b", "Harvard CS50's Introduction", detail: "freeCodeCamp.org",
                    icon: chromeIcon, channel: .mediaRemote),
                row("c", "晴天", detail: "周杰伦 · 叶惠美", icon: nil, channel: .appleScript),
                row("d", "Lofi Beats to Relax", detail: "Spotify", icon: nil, channel: .appleScript),
                row("e", "腾讯会议", detail: "需「辅助功能」授权", icon: nil, channel: .accessibility)
            ]
            render(vm: many, size: CGSize(width: 1440, height: 900),
                   to: path.replacingOccurrences(of: ".png", with: "-many.png"))

            // 4. 没有音频源（卡片整块不出现）
            let silent = makeVM(remaining: 6, mode: .running)
            render(vm: silent, size: CGSize(width: 1440, height: 900),
                   to: path.replacingOccurrences(of: ".png", with: "-silent.png"))

            // 5. 休息结束（等按钮）
            let finished = BreakViewModel()
            finished.kind = .long
            finished.total = 300
            finished.remaining = 0
            finished.mode = .finishedManual
            finished.workLabel = "10 分钟"
            finished.wallpaper = wallpaper
            finished.wallpaperCredit = credit
            render(vm: finished, size: CGSize(width: 1440, height: 900),
                   to: path.replacingOccurrences(of: ".png", with: "-finished.png"))

            NSApp.terminate(nil)
        }
    }

    /// 调试用：打印当前识别到的音频源与元数据。
    /// 不弹遮罩、不需要播放器配合，适合验证「歌名 / 歌手 / 页签署名」这条链路。
    static func dumpMedia() {
        var lines: [String] = []
        func log(_ text: String) {
            NSLog("Rest: [dump] %@", text)
            lines.append(text)
        }
        Task {
            // 启动瞬间 MediaRemote 可能还没连上 XPC，等一会儿再查（可用 REST_DUMP_DELAY 调整）
            let delay = Double(ProcessInfo.processInfo.environment["REST_DUMP_DELAY"] ?? "1.5") ?? 1.5
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            log("MediaRemote available=\(MediaRemoteBridge.isAvailable ? 1 : 0)")
            let nowPlaying = await MediaMetadata.systemNowPlaying()
            let nowApp = NSRunningApplication(processIdentifier: nowPlaying.pid)
            log("NowPlaying pid=\(nowPlaying.pid) bundle=\(nowApp?.bundleIdentifier ?? "-") "
                + "playing=\(nowPlaying.isPlaying ? 1 : 0) title=\(nowPlaying.meta.title ?? "-") "
                + "artist=\(nowPlaying.meta.artist ?? "-") album=\(nowPlaying.meta.album ?? "-")")

            let sources = await MediaController.shared.snapshot()
            log("共 \(sources.count) 个音频源")
            for source in sources {
                log("\(source.bundleID) | \(source.displayTitle) | \(source.displayDetail ?? "-") "
                    + "| 渠道:\(source.channel.rawValue) "
                    + "| 浏览器:\(source.isBrowser ? 1 : 0) | 音乐:\(source.isMusic ? 1 : 0)")
            }
            try? lines.joined(separator: "\n").write(toFile: "/tmp/rest-dump.txt",
                                                     atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func render(vm: BreakViewModel, size: CGSize, to path: String) {
        let view = BreakView(vm: vm).frame(width: size.width, height: size.height)
        write(view, scale: 1.0, to: path)
    }


    /// 把设置界面渲染成 PNG（检查排版用）。
    /// Form 是 AppKit 支撑的视图，ImageRenderer 渲不出内容，所以走窗口的 cacheDisplay——
    /// 这是画自己窗口的内容，不需要录屏权限。
    static func renderSettings(path: String, height: CGFloat = 780) {
        let hosting = NSHostingView(rootView: SettingsView(settings: AppSettings.shared))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.contentView = hosting
        win.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if ProcessInfo.processInfo.environment["REST_SCROLL_BOTTOM"] != nil,
               let scroll = Self.firstScrollView(in: hosting) {
                let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
                scroll.reflectScrolledClipView(scroll.contentView)
                hosting.layoutSubtreeIfNeeded()
            }
            if let view = win.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    NSLog("Rest: 已渲染 \(path)")
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    private static func write<V: View>(_ view: V, scale: CGFloat, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("Rest: 渲染失败 \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        NSLog("Rest: 已渲染 \(path)")
    }
}
