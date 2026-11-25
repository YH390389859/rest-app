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
        WallpaperService.prefetch(market: settings.wallpaperMarket)

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

        // 调试用：--render <输出路径> 把休息界面离屏渲染成 PNG
        if let index = CommandLine.arguments.firstIndex(of: "--render"),
           CommandLine.arguments.count > index + 1 {
            DebugRender.run(path: CommandLine.arguments[index + 1])
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return true
    }
}
