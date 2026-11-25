import Foundation
import AppKit
import ApplicationServices

/// 按应用单独暂停 / 恢复播放。
///
/// 三条通道，按可靠性排序：
///  1. 系统媒体控制（MediaRemote）—— 只对 Now Playing 那个应用有效，不需要任何授权
///  2. AppleScript —— 只在目标应用的脚本字典（sdef）真的声明了 pause / playpause 时使用，
///     先读 sdef 判断能力，不会凭猜测乱发事件；首次执行需要「自动化」授权
///  3. 辅助功能（AX）—— 在这应用的界面里找「暂停」按钮按下去，需要「辅助功能」授权
enum PerAppMediaControl {

    // MARK: - AppleScript

    /// 是否已经拿到「自动化」授权。
    ///
    /// 用 `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` 静默查询：
    /// 没授权就返回 false，**不会**弹系统弹窗。读元数据是锦上添花，不值得为了它
    /// 在休息遮罩弹出来的时候打断用户；真正需要授权的是「暂停」，那条路会主动引导。
    static func canAutomate(bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target) == noErr else {
            return false
        }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) == noErr
    }

    /// 目标应用脚本字典里与暂停相关的动词（读 sdef 文件，不会触发授权弹窗）
    static func scriptingVerbs(forBundleID bundleID: String) -> [String] {
        guard let text = sdefText(forBundleID: bundleID) else { return [] }

        // <command name="pause" ...> —— 属性顺序不固定，用正则兜住
        guard let re = try? NSRegularExpression(pattern: "<command[^>]*name=\"(pause|playpause|play)\"") else {
            return []
        }
        let ns = text as NSString
        var verbs: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 1 else { continue }
            let verb = ns.substring(with: m.range(at: 1))
            if !verbs.contains(verb) { verbs.append(verb) }
        }
        return verbs
    }

    /// 脚本字典里是否声明了「下一首」（Music / Spotify 都是 `next track`）
    static func hasNextTrackCommand(forBundleID bundleID: String) -> Bool {
        guard let text = sdefText(forBundleID: bundleID) else { return false }
        return text.contains("name=\"next track\"") || text.contains("name=\"nextTrack\"")
    }

    /// 把应用 Resources 目录下所有 .sdef 拼成一段文本（纯文件读取，无副作用）
    private static func sdefText(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let resources = url.appendingPathComponent("Contents/Resources")
        guard let files = try? FileManager.default.contentsOfDirectory(at: resources,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: .skipsHiddenFiles) else {
            return nil
        }
        var text = ""
        for file in files where file.pathExtension.lowercased() == "sdef" {
            if let chunk = try? String(contentsOf: file, encoding: .utf8) { text += chunk }
        }
        return text.isEmpty ? nil : text
    }

    /// 执行一段 AppleScript。阻塞式，调用方必须放到后台线程。
    /// 超时直接 terminate，避免某个应用把 osascript 卡死。
    static func runScript(_ source: String, timeout: TimeInterval = 2.0) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(30_000)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// 后台执行，不阻塞主线程（休息遮罩上的动画和倒计时都在主线程）
    static func runScriptAsync(_ source: String, timeout: TimeInterval = 2.0) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            runScript(source, timeout: timeout)
        }.value
    }

    /// 执行脚本并取回 stdout（读元数据用）。
    /// 元数据只是锦上添花，所以失败、超时、输出为空一律返回 nil，调用方静默降级。
    static func runScriptOutput(_ source: String, timeout: TimeInterval = 2.0) async -> String? {
        await Task.detached(priority: .utility) {
            runScriptCapturing(source, timeout: timeout)
        }.value
    }

    private static func runScriptCapturing(_ source: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(30_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("Rest: 元数据脚本失败(%d): %@", process.terminationStatus, message)
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - 辅助功能

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 请求辅助功能授权（只在用户主动点击需要它的按钮时调用）。
    ///
    /// 系统那个「是否允许控制这台电脑」的弹窗对同一个应用只会弹一次：用户以前点过
    /// 拒绝、或者从别的副本点过，再调 `AXIsProcessTrustedWithOptions` 就完全没反应。
    /// 所以这里除了尝试弹窗，还一定把「系统设置 → 隐私与安全性 → 辅助功能」打开，
    /// 保证点击后有任何可见反馈。
    static func requestAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("Rest: 请求辅助功能授权，当前 trusted=%d", trusted ? 1 : 0)
        openAccessibilitySettings()
    }

    /// 打开系统设置里的辅助功能授权页。
    /// 新版 macOS 把隐私面板做成了 ExtensionKit 扩展，旧锚点仍会重定向，
    /// 但先试新标识、失败再退回旧的更稳。
    static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
        NSLog("Rest: 打开辅助功能设置页失败")
    }

    /// 在目标应用里找「暂停」按钮并按下去。阻塞式，调用方放到后台线程。
    static func pressPlayPause(pid: pid_t) -> Bool {
        guard pid > 0, AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)

        var queue: [(element: AXUIElement, depth: Int)] = [(app, 0)]
        var visited = 0
        // 广度优先 + 节点/深度上限：Chrome 这类应用的树很大，不设限会卡住
        while !queue.isEmpty, visited < 2200 {
            let (element, depth) = queue.removeFirst()
            visited += 1

            if isPauseControl(element),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }

            if depth < 7 {
                for child in children(element) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return false
    }

    static func pressPlayPauseAsync(pid: pid_t) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            pressPlayPause(pid: pid)
        }.value
    }

    /// 按钮上只认这些文案，避免误按「暂停下载」「暂停同步」之类的无关按钮
    private static let pauseLabels: Set<String> = [
        "暂停", "pause", "播放/暂停", "暂停/播放", "play/pause", "pause/play", "暂停播放"
    ]

    private static func isPauseControl(_ element: AXUIElement) -> Bool {
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              role == "AXButton" || role == "AXMenuItem" || role == "AXCheckBox" else {
            return false
        }
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let raw = attribute(element, key) as? String else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pauseLabels.contains(text) { return true }
        }
        return false
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    // MARK: - 媒体键（最终兜底）

    /// 合成一次「播放/暂停」媒体键事件（NX_KEYTYPE_PLAY = 16）。
    /// 它和真实媒体键一样只作用于系统 Now Playing 应用，且需要「辅助功能」授权。
    static func postPlayPauseKey() {
        func post(isDown: Bool) {
            let flags: UInt = isDown ? 0xa00 : 0xb00
            guard let event = NSEvent.otherEvent(with: .systemDefined,
                                                 location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: 0,
                                                 context: nil,
                                                 subtype: 8,
                                                 data1: 16 << 16,
                                                 data2: -1) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        post(isDown: true)
        usleep(30_000)
        post(isDown: false)
    }
}
