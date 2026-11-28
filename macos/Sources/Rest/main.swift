import AppKit

let app = NSApplication.shared
let delegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 纯菜单栏应用，不占 Dock
app.run()
