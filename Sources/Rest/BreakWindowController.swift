import AppKit
import SwiftUI

/// 覆盖层窗口：无边框、透明底、可成为 key window（这样才能拿到键盘事件）
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 管理休息遮罩窗口（每个屏幕一个），以及「透明遮罩」状态下的输入捕获
@MainActor
final class BreakWindowController {
    private let vm: BreakViewModel
    private var windows: [OverlayWindow] = []
    private var monitors: [Any] = []
    private var shieldArmedAt: Date?

    /// 透明遮罩期间捕获到第一次输入
    var onUserReturn: (() -> Void)?

    // 透明遮罩刚出现时系统可能补发一次 mouseMoved，留一点宽限期避免误触发
    private let shieldGrace: TimeInterval = 0.8

    init(viewModel: BreakViewModel) {
        self.vm = viewModel
    }

    var isVisible: Bool { !windows.isEmpty }

    // MARK: 显示 / 隐藏

    func show(on screens: [NSScreen]) {
        dismissWindows()

        let targets = screens.isEmpty ? [NSScreen.main].compactMap { $0 } : screens
        for screen in targets {
            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: .borderless,
                                       backing: .buffered,
                                       defer: false)
            window.setFrame(screen.frame, display: true)
            window.level = .screenSaver                       // 高于全屏应用
            window.collectionBehavior = [.canJoinAllSpaces,    // 在任意 Space 都出现
                                         .fullScreenAuxiliary, // 能盖住全屏应用
                                         .stationary,
                                         .ignoresCycle]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none

            let hosting = NSHostingView(rootView: BreakView(vm: vm))
            hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = .clear

            window.contentView = hosting
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    /// 进入全透明遮罩状态（窗口仍在，内容变全透明，继续吃掉输入）
    func beginShield() {
        guard !windows.isEmpty else { return }
        shieldArmedAt = Date()
        withAnimation(.easeInOut(duration: 0.3)) {
            vm.mode = .shield
        }
        for window in windows {
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
        }
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        shieldArmedAt = nil
        removeMonitors()
        dismissWindows()
    }

    private func dismissWindows() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
    }

    // MARK: 输入捕获

    private func installMonitors() {
        removeMonitors()

        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseDragged, .rightMouseDragged,
                                           .scrollWheel, .mouseMoved,
                                           .swipe, .rotate, .magnify, .beginGesture, .tabletPoint]

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event) ? nil : event
        }) {
            monitors.append(local)
        }

        // 兜底：万一窗口没能成为 key window（例如被其它全屏应用抢了焦点），
        // 鼠标层面的全局事件不需要任何授权，也能唤醒。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShieldActive, self.shieldArmedSinceLongEnough else { return }
                self.fireUserReturn()
            }
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    private var isShieldActive: Bool { vm.mode == .shield }

    private var shieldArmedSinceLongEnough: Bool {
        guard let armed = shieldArmedAt else { return false }
        return Date().timeIntervalSince(armed) > shieldGrace
    }

    /// 返回 true 表示吞掉这个事件
    private func handleLocal(_ event: NSEvent) -> Bool {
        guard isShieldActive else {
            // 休息进行中：Esc 快捷跳过
            if event.type == .keyDown, event.keyCode == 53, vm.mode == .running {
                vm.onSkip?()
                return true
            }
            return false
        }

        guard shieldArmedSinceLongEnough else { return false }
        fireUserReturn()
        return true
    }

    private func fireUserReturn() {
        guard isShieldActive else { return }
        shieldArmedAt = nil
        vm.mode = .running
        onUserReturn?()
    }
}
