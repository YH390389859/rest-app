import AppKit
import SwiftUI

/// 调试用：把休息界面离屏渲染成 PNG，方便在没有录屏权限的环境里检查排版。
@MainActor
enum DebugRender {
    static func run(path: String) {
        let vm = BreakViewModel()
        vm.kind = .micro
        vm.total = 20
        vm.remaining = 12
        vm.mode = .running
        vm.workLabel = "20 分钟"
        vm.postponeLabel = "5 分钟"
        vm.mediaAppName = "Google Chrome"

        Task {
            if let wallpaper = await WallpaperService.nextWallpaper(market: "zh-CN") {
                vm.wallpaper = wallpaper.image
                vm.wallpaperCredit = wallpaper.credit
            }
            render(vm: vm, size: CGSize(width: 1440, height: 900), to: path)

            // 第二张：休息结束（等按钮）
            let finished = BreakViewModel()
            finished.kind = .long
            finished.total = 300
            finished.remaining = 0
            finished.mode = .finishedManual
            finished.workLabel = "20 分钟"
            finished.wallpaper = vm.wallpaper
            finished.wallpaperCredit = vm.wallpaperCredit
            render(vm: finished, size: CGSize(width: 1440, height: 900),
                   to: path.replacingOccurrences(of: ".png", with: "-finished.png"))

            // 第三张：已暂停媒体
            let paused = BreakViewModel()
            paused.kind = .micro
            paused.total = 20
            paused.remaining = 8
            paused.mode = .running
            paused.workLabel = "20 分钟"
            paused.postponeLabel = "5 分钟"
            paused.mediaAppName = "Google Chrome"
            paused.mediaPaused = true
            paused.wallpaper = vm.wallpaper
            paused.wallpaperCredit = vm.wallpaperCredit
            render(vm: paused, size: CGSize(width: 1440, height: 900),
                   to: path.replacingOccurrences(of: ".png", with: "-paused.png"))

            NSApp.terminate(nil)
        }
    }

    private static func render(vm: BreakViewModel, size: CGSize, to path: String) {
        let view = BreakView(vm: vm).frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0
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
