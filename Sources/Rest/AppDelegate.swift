import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var scheduler: Scheduler!
    private var coordinator: BreakCoordinator!
    private var statusBar: StatusBarController!
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduler = Scheduler(settings: settings)
        coordinator = BreakCoordinator(settings: settings, scheduler: scheduler)

        settingsWindow = SettingsWindowController(settings: settings, onPreview: { [weak self] in
            self?.coordinator.previewBreak()
        })

        statusBar = StatusBarController(
            scheduler: scheduler,
            settings: settings,
            actions: .init(
                toggle: { [weak self] in self?.scheduler.togglePause() },
                breakNow: { [weak self] in self?.scheduler.startBreakNow() },
                skipBreak: { [weak self] in self?.coordinator.skipCurrentBreak() },
                previewBreak: { [weak self] in self?.coordinator.previewBreak() },
                settings: { [weak self] in self?.settingsWindow?.show() },
                quit: { NSApp.terminate(nil) }
            )
        )

        scheduler.onStateChange = { [weak self] in
            self?.statusBar.refresh()
        }

        scheduler.start()
        WallpaperService.prepareNext(market: settings.wallpaperMarket)

        if !UserDefaults.standard.bool(forKey: "didFirstLaunch") {
            UserDefaults.standard.set(true, forKey: "didFirstLaunch")
            settingsWindow?.show()
        }

        // 调试用：启动即预览休息界面
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.coordinator.previewBreak()
            }
        }

        // 调试用：--test-rescreen 复现「分辨率变了但窗口还是旧尺寸」，验证遮罩会重铺
        if CommandLine.arguments.contains("--test-rescreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.coordinator.previewBreak()
            }
            // 把窗口改成过期的 1280x720，模拟显示器换分辨率后窗口没跟着走
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                for window in NSApp.windows where window is OverlayWindow {
                    window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 720), display: true)
                }
                NSLog("Rest: [测试] 已把遮罩窗口改成过期尺寸 1280x720")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                NSLog("Rest: [测试] 模拟显示器参数变化")
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification, object: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                let overlays = NSApp.windows.filter { $0 is OverlayWindow }
                let screens = NSScreen.screens
                let matched = overlays.allSatisfy { window in
                    screens.contains { $0.frame == window.frame }
                }
                NSLog("Rest: [测试] 复查 %d 个遮罩窗口，与屏幕对齐: %@",
                      overlays.count, matched ? "是" : "否")
                NSApp.terminate(nil)
            }
        }

        // 调试用：--render <输出路径> 把休息界面离屏渲染成 PNG
        if let index = CommandLine.arguments.firstIndex(of: "--render"),
           CommandLine.arguments.count > index + 1 {
            DebugRender.run(path: CommandLine.arguments[index + 1])
        }

        // 调试用：--dump-media 打印当前音频源与元数据（歌名 / 歌手 / 封面）
        if CommandLine.arguments.contains("--dump-media") {
            DebugRender.dumpMedia()
        }

        // 调试用：--test-pause [bundle 关键字] 对当前音频源执行一次暂停，验证通道是否真的可用
        if CommandLine.arguments.contains("--test-pause") {
            let index = CommandLine.arguments.firstIndex(of: "--test-pause") ?? 0
            let keyword = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : ""
            DebugRender.testPause(keyword: keyword)
        }

        // 调试用：--render-settings <输出路径> [高度] 渲染设置界面
        if let index = CommandLine.arguments.firstIndex(of: "--render-settings"),
           CommandLine.arguments.count > index + 1 {
            let height = CommandLine.arguments.count > index + 2
                ? CGFloat(Double(CommandLine.arguments[index + 2]) ?? 780)
                : 780
            DebugRender.renderSettings(path: CommandLine.arguments[index + 1], height: height)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return true
    }
}
