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

    /// 目标应用脚本字典里与暂停相关的动词（读 sdef 文件，不会触发授权弹窗）
    static func scriptingVerbs(forBundleID bundleID: String) -> [String] {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return [] }
        let resources = url.appendingPathComponent("Contents/Resources")
        guard let files = try? FileManager.default.contentsOfDirectory(at: resources,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: .skipsHiddenFiles) else {
            return []
        }
        var text = ""
        for file in files where file.pathExtension.lowercased() == "sdef" {
            if let chunk = try? String(contentsOf: file, encoding: .utf8) { text += chunk }
        }
        guard !text.isEmpty else { return [] }

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

    // MARK: - 辅助功能

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 请求辅助功能授权（只在用户主动点击需要它的按钮时调用，会弹系统引导）
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
