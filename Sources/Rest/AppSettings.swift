import Foundation
import AppKit
import CoreGraphics
import Combine
import ServiceManagement

// MARK: - 休息结束后的行为

enum BreakEndBehavior: String, CaseIterable, Identifiable {
    /// 倒计时结束立刻进入下一轮工作（Stretchly 默认行为）
    case auto
    /// 停在结束界面，必须点按钮才继续
    case manual
    /// 倒计时结束后变成全透明遮罩，捕获到第一次键鼠/触控板动作才继续
    case waitForInput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "直接进入下一轮"
        case .manual: return "停留，等按钮"
        case .waitForInput: return "透明遮罩 + 任意操作"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "倒计时归零后立刻开始下一轮工作，遮罩自动消失。"
        case .manual:
            return "倒计时归零后停留在结束界面，显示「开始下一轮」按钮。"
        case .waitForInput:
            return "倒计时归零后遮罩变为全透明（看起来已经可以操作），捕获到第一次键鼠/触控板动作后关闭遮罩并开始下一轮。"
        }
    }
}

// MARK: - 设置

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Keys {
        static let work = "workMinutes"
        static let micro = "microBreakSeconds"
        static let long = "longBreakMinutes"
        static let every = "breaksBeforeLong"
        static let endBehavior = "breakEndBehavior"
        static let autoPause = "autoPauseMedia"
        static let resume = "resumeMediaAfterBreak"
        static let bing = "useBingWallpaper"
        static let market = "wallpaperMarket"
        static let allDisplays = "allDisplays"
        static let sound = "playSound"
        static let idle = "skipWhenIdle"
        static let postpone = "postponeMinutes"
    }

    private let store = UserDefaults.standard
    private var didBootstrap = false

    @Published var workMinutes: Double = 20 { didSet { store.set(workMinutes, forKey: Keys.work) } }
    @Published var microBreakSeconds: Double = 20 { didSet { store.set(microBreakSeconds, forKey: Keys.micro) } }
    @Published var longBreakMinutes: Double = 5 { didSet { store.set(longBreakMinutes, forKey: Keys.long) } }
    @Published var breaksBeforeLong: Double = 4 { didSet { store.set(breaksBeforeLong, forKey: Keys.every) } }
    @Published var breakEndBehavior: BreakEndBehavior = .waitForInput {
        didSet { store.set(breakEndBehavior.rawValue, forKey: Keys.endBehavior) }
    }
    @Published var autoPauseMedia: Bool = true { didSet { store.set(autoPauseMedia, forKey: Keys.autoPause) } }
    @Published var resumeMediaAfterBreak: Bool = true { didSet { store.set(resumeMediaAfterBreak, forKey: Keys.resume) } }
    @Published var useBingWallpaper: Bool = true { didSet { store.set(useBingWallpaper, forKey: Keys.bing) } }
    @Published var wallpaperMarket: String = "zh-CN" { didSet { store.set(wallpaperMarket, forKey: Keys.market) } }
    @Published var allDisplays: Bool = true { didSet { store.set(allDisplays, forKey: Keys.allDisplays) } }
    @Published var playSound: Bool = true { didSet { store.set(playSound, forKey: Keys.sound) } }
    @Published var skipWhenIdle: Bool = true { didSet { store.set(skipWhenIdle, forKey: Keys.idle) } }
    @Published var postponeMinutes: Double = 5 { didSet { store.set(postponeMinutes, forKey: Keys.postpone) } }
    @Published var launchAtLogin: Bool = false { didSet { applyLoginItem() } }

    private init() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: Keys.work) as? Double { workMinutes = v }
        if let v = d.object(forKey: Keys.micro) as? Double { microBreakSeconds = v }
        if let v = d.object(forKey: Keys.long) as? Double { longBreakMinutes = v }
        if let v = d.object(forKey: Keys.every) as? Double { breaksBeforeLong = v }
        if let raw = d.string(forKey: Keys.endBehavior), let v = BreakEndBehavior(rawValue: raw) { breakEndBehavior = v }
        if let v = d.object(forKey: Keys.autoPause) as? Bool { autoPauseMedia = v }
        if let v = d.object(forKey: Keys.resume) as? Bool { resumeMediaAfterBreak = v }
        if let v = d.object(forKey: Keys.bing) as? Bool { useBingWallpaper = v }
        if let v = d.string(forKey: Keys.market) { wallpaperMarket = v }
        if let v = d.object(forKey: Keys.allDisplays) as? Bool { allDisplays = v }
        if let v = d.object(forKey: Keys.sound) as? Bool { playSound = v }
        if let v = d.object(forKey: Keys.idle) as? Bool { skipWhenIdle = v }
        if let v = d.object(forKey: Keys.postpone) as? Double { postponeMinutes = v }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        didBootstrap = true
    }

    // MARK: 计算属性

    var workSeconds: TimeInterval { max(60, workMinutes * 60) }
    var microBreakDuration: TimeInterval { max(5, microBreakSeconds) }
    var longBreakDuration: TimeInterval { max(30, longBreakMinutes * 60) }
    var longEvery: Int { max(2, Int(breaksBeforeLong)) }
    var postponeSeconds: TimeInterval { max(60, postponeMinutes * 60) }

    /// 空闲超过这个时长，认为人不在电脑前，休息没意义
    var idleThreshold: TimeInterval { 120 }

    private func applyLoginItem() {
        guard didBootstrap, Bundle.main.bundleIdentifier != nil else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 从 build 目录直接运行时会被系统拒绝，装到 /Applications 后即可生效
            NSLog("Rest: 登录项设置失败 \(error.localizedDescription)")
        }
    }
}

// MARK: - 小工具

func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

enum IdleMonitor {
    /// 距离最后一次键鼠/触控板输入的秒数（公开 API，无需权限）
    static var secondsSinceLastInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
    }
}

enum SoundFX {
    static func playBreakStart() {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
    static func playBreakEnd() {
        NSSound(named: NSSound.Name("Ping"))?.play()
    }
}
