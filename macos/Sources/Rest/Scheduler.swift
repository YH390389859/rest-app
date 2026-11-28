import Foundation
import Combine

enum BreakKind: String, Equatable {
    case micro
    case long

    /// Stretchly 里的说法：小憩 / 休息
    var title: String { self == .long ? "休息" : "小憩" }

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
///
/// 节奏模型照抄 Stretchly：**每一段工作长度都等于小憩间隔**，
/// 休息第几次到来由计数器决定 —— `breakNumber % (microsBeforeLong + 1) == 0` 时来一次长休息。
/// 所以「休息 每 30 分」在 10 分钟小憩间隔下 = 每 3 个槽位一次，也就是「2 次小憩后」。
///
/// 只负责计时与状态流转，不碰任何 UI；休息结束后不会自行进入下一轮，
/// 必须由外部调用 beginNextWork()，这样才能实现「等用户点了才继续」。
@MainActor
final class Scheduler {
    private let settings: AppSettings
    private var timer: Timer?
    /// 本次工作阶段的结束时刻
    private var deadline: Date?
    /// 已经过了几个槽位（Stretchly 的 breakNumber）
    private var breakNumber = 0
    /// 暂停的开始时刻，恢复时据此平移
    private var pausedAt: Date?
    /// 本次工作阶段的长度（推迟时会临时变短/变长）
    private var span: TimeInterval = 0

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
        breakNumber = 0
        enterWork(span: settings.workSpanSeconds)
    }

    func togglePause() {
        switch state {
        case .working(let paused):
            if paused {
                if let since = pausedAt {
                    deadline = deadline?.addingTimeInterval(Date().timeIntervalSince(since))
                }
                pausedAt = nil
                state = .working(paused: false)
                runTimer()
            } else {
                pausedAt = Date()
                state = .working(paused: true)
                stopTimer()
            }
            notifyState()
        case .stopped:
            start()
        default:
            break
        }
    }

    /// 手动立刻进入休息（按当前计数器判断该来哪一种）
    func startBreakNow() {
        startBreak()
    }

    /// 跳过当前休息，直接开始下一轮工作
    func skipBreak() {
        guard let kind = currentKind, settings.allowsSkip(kind) else { return }
        // 跳过的那一次不再占用周期里的位置
        if kind == .long { breakNumber = 0 }
        enterWork(span: settings.workSpanSeconds)
    }

    /// 推迟当前休息：回到工作状态，N 分钟后再来同一种休息
    func postpone() {
        guard let kind = currentKind, settings.allowsPostpone(kind) else { return }
        // 这一种休息还没真正发生，把计数退回去
        breakNumber = max(0, breakNumber - 1)
        enterWork(span: settings.postponeSeconds)
    }

    /// 休息结束，进入下一轮工作
    func beginNextWork() {
        if currentKind == .long { breakNumber = 0 }
        enterWork(span: settings.workSpanSeconds)
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

    // MARK: 状态查询

    var statusText: String {
        switch state {
        case .stopped:
            return "开始"
        case .working(let paused):
            return paused ? "暂停" : formatClock(remaining)
        case .breaking(let kind):
            return (kind == .long ? "休息 " : "小憩 ") + formatClock(remaining)
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

    /// 当前正在休息（或刚结束）的类型
    var currentKind: BreakKind? {
        switch state {
        case .breaking(let k), .breakFinished(let k): return k
        default: return nil
        }
    }

    /// 即将到来的那次休息是什么类型
    var upcomingKind: BreakKind {
        if !settings.microEnabled { return .long }
        if !settings.longEnabled { return .micro }
        return (breakNumber + 1) % settings.slotsPerLong == 0 ? .long : .micro
    }

    /// 距离下一次长休息还要经过几次小憩（Stretchly 的「N 次小憩后」）。
    /// 0 表示下一次就是长休息。
    var microsBeforeNextLong: Int? {
        guard settings.microEnabled, settings.longEnabled else { return nil }
        let slots = settings.slotsPerLong
        return max(0, slots - 1 - (breakNumber % slots))
    }

    // MARK: 内部

    private func enterWork(span seconds: TimeInterval) {
        stopTimer()
        guard settings.microEnabled || settings.longEnabled else {
            // 两类休息都关掉了，就没有可计时的东西
            state = .stopped
            deadline = nil
            span = 0
            remaining = 0
            total = 0
            onWorkStart?()
            notifyState()
            return
        }
        span = max(1, seconds)
        state = .working(paused: false)
        deadline = Date().addingTimeInterval(span)
        total = span
        remaining = span
        onWorkStart?()
        notifyState()
        runTimer()
    }

    private func startBreak() {
        stopTimer()
        guard settings.microEnabled || settings.longEnabled else { return }

        breakNumber += 1
        let kind: BreakKind = {
            if !settings.microEnabled { return .long }
            if !settings.longEnabled { return .micro }
            return breakNumber % settings.slotsPerLong == 0 ? .long : .micro
        }()
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
            if remaining <= 0 {
                // 推迟过的工作段走完，下一次就轮到本该来的那种休息
                startBreak()
            }
            notifyState()
        case .breaking(let kind):
            guard let d = deadline else { return }
            remaining = max(0, d.timeIntervalSinceNow)
            if remaining <= 0 {
                stopTimer()
                deadline = nil
                completedBreaks += 1
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
