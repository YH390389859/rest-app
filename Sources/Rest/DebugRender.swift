import AppKit
import SwiftUI

/// 调试用：把休息界面离屏渲染成 PNG，方便在没有录屏权限的环境里检查排版。
@MainActor
enum DebugRender {
    static func run(path: String) {
        let chromeIcon = NSWorkspace.shared.icon(forFile: "/Applications/Google Chrome.app")
        let musicIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Music.app")

        func row(_ id: String,
                 _ name: String,
                 icon: NSImage?,
                 subtitle: String?,
                 nowPlaying: Bool = false,
                 channel: MediaChannel = .accessibility,
                 paused: Bool = false) -> BreakViewModel.AudioRow {
            BreakViewModel.AudioRow(id: id, name: name, icon: icon, subtitle: subtitle,
                                    isNowPlaying: nowPlaying, channel: channel,
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

            // 1. 多音频源：系统正在播放 + 已暂停 + 需授权
            let multi = makeVM(remaining: 12, mode: .running)
            multi.audioRows = [
                row("com.google.Chrome", "Google Chrome", icon: chromeIcon,
                    subtitle: "【4K】雪山日出延时 · Nature Relax", nowPlaying: true, channel: .mediaRemote),
                row("com.netease.163music", "网易云音乐", icon: nil,
                    subtitle: "晴天 · 周杰伦", channel: .appleScript, paused: true),
                row("com.apple.Music", "音乐", icon: musicIcon,
                    subtitle: "需「辅助功能」授权", channel: .accessibility)
            ]
            render(vm: multi, size: CGSize(width: 1440, height: 900), to: path)

            // 2. 全部暂停
            let paused = makeVM(remaining: 8, mode: .running)
            paused.audioRows = [
                row("com.google.Chrome", "Google Chrome", icon: chromeIcon,
                    subtitle: "【4K】雪山日出延时 · Nature Relax", nowPlaying: true,
                    channel: .mediaRemote, paused: true),
                row("com.netease.163music", "网易云音乐", icon: nil,
                    subtitle: "晴天 · 周杰伦", channel: .appleScript, paused: true)
            ]
            render(vm: paused, size: CGSize(width: 1440, height: 900),
                   to: path.replacingOccurrences(of: ".png", with: "-paused.png"))

            // 3. 五个音频源（超过 3 行要能滚动）
            let many = makeVM(remaining: 15, mode: .running)
            many.audioRows = [
                row("a", "Google Chrome", icon: chromeIcon, subtitle: "【4K】雪山日出延时", nowPlaying: true, channel: .mediaRemote),
                row("b", "网易云音乐", icon: nil, subtitle: "晴天 · 周杰伦", channel: .appleScript),
                row("c", "音乐", icon: musicIcon, subtitle: nil, channel: .appleScript),
                row("d", "Spotify", icon: nil, subtitle: "Lofi Beats", channel: .appleScript),
                row("e", "腾讯会议", icon: nil, subtitle: "需「辅助功能」授权", channel: .accessibility)
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

    private static func render(vm: BreakViewModel, size: CGSize, to path: String) {
        let view = BreakView(vm: vm).frame(width: size.width, height: size.height)
        write(view, scale: 1.0, to: path)
    }

    /// 把设置界面渲染成 PNG（检查排版用）。
    /// Form 是 AppKit 支撑的视图，ImageRenderer 渲不出内容，所以走窗口的 cacheDisplay——
    /// 这是画自己窗口的内容，不需要录屏权限。
    static func renderSettings(path: String) {
        let hosting = NSHostingView(rootView: SettingsView(settings: AppSettings.shared))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 780),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.contentView = hosting
        win.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
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
