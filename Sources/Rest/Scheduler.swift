import Foundation
import Combine

enum BreakKind: String, Equatable {
    case micro
    case long

    var title: String { self == .long ? "长休息" : "微休息" }

    var caption: String {
        self == .long
            ? "起来走两步，活动肩颈，让眼睛看看远处"
            : "抬头看向远处 20 秒，眨眨眼睛，松开肩膀"
    }
}

enum SchedulerState: Equatable {
    case stopped
    case working(paused: Bool)
    case breaking(BreakKind)
    case breakFinished(BreakKind)
}

/// 工作时间 / 休息时间状态机。
/// 只负责计时与状态流转，不碰任何 UI；休息结束后不会自行进入下一轮，
/// 必须由外部调用 beginNextWork()，这样才能实现「等用户点了才继续」。
@MainActor
final class Scheduler {
    private let settings: AppSettings
    private var timer: Timer?
    private var deadline: Date?

    private(set) var state: SchedulerState = .stopped
    private(set) var remaining: TimeInterval = 0
    private(set) var total: TimeInterval = 0
    private(set) var completedBreaks = 0

    var onStateChange: (() -> Void)?
    var onBreakStart: ((BreakKind, TimeInterval) -> Void)?
    /// 休息期间每 0.25s 触发一次，参数为（剩余, 总时长）——界面倒计时靠它驱动
    var onBreakTick: ((TimeInterval, TimeInterval) -> Void)?
    var onBreakFinished: (() -> Void)?
    var onWorkStart: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: 对外操作

    func start() {
        beginWork(after: settings.workSeconds)
    }

    func togglePause() {
        switch state {
        case .working(let paused):
            if paused {
                deadline = Date().addingTimeInterval(remaining)
                state = .working(paused: false)
                runTimer()
            } else {
                state = .working(paused: true)
                stopTimer()
            }
            notifyState()
        case .stopped:
            beginWork(after: settings.workSeconds)
        default:
            break
        }
    }

    /// 手动立刻进入休息
    func startBreakNow() {
        startBreak()
    }

    /// 跳过当前休息，直接开始下一轮工作（跳过也计入长休息周期）
    func skipBreak() {
        beginNextWork()
    }

    /// 推迟休息：相当于把工作时间再延长 N 分钟
    func postpone() {
        stopTimer()
        beginWork(after: settings.postponeSeconds)
    }

    func beginNextWork() {
        completedBreaks += 1
        beginWork(after: settings.workSeconds)
    }

    /// 休息结束界面点「再休息一会儿」
    func extendBreak(by seconds: TimeInterval) {
        switch state {
        case .breaking:
            guard let d = deadline else { return }
            deadline = d.addingTimeInterval(seconds)
            total += seconds
            remaining = deadline!.timeIntervalSinceNow
            runTimer()
        case .breakFinished(let kind):
            total += seconds
            remaining = seconds
            state = .breaking(kind)
            deadline = Date().addingTimeInterval(seconds)
            runTimer()
        default:
            break
        }
        notifyState()
    }

    var statusText: String {
        switch state {
        case .stopped:
            return "开始"
        case .working(let paused):
            return paused ? "暂停" : formatClock(remaining)
        case .breaking(let kind):
            return (kind == .long ? "长休 " : "休 ") + formatClock(remaining)
        case .breakFinished:
            return "休息结束"
        }
    }

    var isBreaking: Bool {
        switch state {
        case .breaking, .breakFinished: return true
        default: return false
        }
    }

    // MARK: 内部

    private func beginWork(after seconds: TimeInterval) {
        stopTimer()
        state = .working(paused: false)
        deadline = Date().addingTimeInterval(seconds)
        total = seconds
        remaining = seconds
        onWorkStart?()
        notifyState()
        runTimer()
    }

    private func startBreak() {
        stopTimer()
        let nextIndex = completedBreaks + 1
        let kind: BreakKind = (nextIndex % settings.longEvery == 0) ? .long : .micro
        let duration = (kind == .long) ? settings.longBreakDuration : settings.microBreakDuration

        state = .breaking(kind)
        deadline = Date().addingTimeInterval(duration)
        total = duration
        remaining = duration
        onBreakStart?(kind, duration)
        notifyState()
        runTimer()
    }

    private func runTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        switch state {
        case .working(let paused):
            guard !paused, let d = deadline else { return }
            remaining = max(0, d.timeIntervalSinceNow)
            if remaining <= 0 { startBreak() }
            notifyState()
        case .breaking(let kind):
            guard let d = deadline else { return }
            remaining = max(0, d.timeIntervalSinceNow)
            if remaining <= 0 {
                stopTimer()
                deadline = nil
                state = .breakFinished(kind)
                onBreakFinished?()
                notifyState()
            } else {
                onBreakTick?(remaining, total)
                notifyState()
            }
        default:
            stopTimer()
        }
    }

    private func notifyState() {
        onStateChange?()
    }
}
