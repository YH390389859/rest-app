import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    struct Actions {
        var toggle: () -> Void
        var breakNow: () -> Void
        var skipBreak: () -> Void
        var previewBreak: () -> Void
        var settings: () -> Void
        var quit: () -> Void
    }

    private let item: NSStatusItem
    private let scheduler: Scheduler
    private let settings: AppSettings
    private let actions: Actions

    init(scheduler: Scheduler, settings: AppSettings, actions: Actions) {
        self.scheduler = scheduler
        self.settings = settings
        self.actions = actions
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Rest")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        item.button?.title = " " + scheduler.statusText
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        switch scheduler.state {
        case .stopped:
            menu.addItem(makeItem("开始计时", #selector(toggleTimer)))
        case .working(let paused):
            menu.addItem(makeItem(paused ? "继续计时" : "暂停计时", #selector(toggleTimer)))
        case .breaking, .breakFinished:
            menu.addItem(makeItem("跳过当前休息", #selector(skipBreakKey)))
        }

        menu.addItem(makeItem("立即休息", #selector(breakNow)))
        menu.addItem(makeItem("预览休息界面", #selector(previewBreak)))
        menu.addItem(.separator())
        menu.addItem(makeItem("设置…", #selector(openSettings), ","))
        menu.addItem(makeItem("退出 Rest", #selector(quit), "q"))
    }

    private func makeItem(_ title: String, _ selector: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func headerText() -> String {
        switch scheduler.state {
        case .stopped:
            return "未开始"
        case .working(let paused):
            if paused { return "已暂停 · 剩余 \(formatClock(scheduler.remaining))" }
            return "工作中 · 剩余 \(formatClock(scheduler.remaining))"
        case .breaking(let kind):
            return "\(kind.title)中 · 剩余 \(formatClock(scheduler.remaining))"
        case .breakFinished:
            return "休息已结束，等待继续"
        }
    }

    @objc private func toggleTimer() { actions.toggle() }
    @objc private func breakNow() { actions.breakNow() }
    @objc private func skipBreakKey() { actions.skipBreak() }
    @objc private func previewBreak() { actions.previewBreak() }
    @objc private func openSettings() { actions.settings() }
    @objc private func quit() { actions.quit() }
}
