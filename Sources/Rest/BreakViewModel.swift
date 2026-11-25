import Foundation
import AppKit
import Combine

@MainActor
final class BreakViewModel: ObservableObject {
    enum Mode: Equatable {
        case running          // 休息倒计时中
        case finishedManual   // 倒计时结束，等待点按钮
        case shield           // 全透明遮罩，等待键鼠动作
    }

    @Published var kind: BreakKind = .micro
    @Published var remaining: TimeInterval = 20
    @Published var total: TimeInterval = 20
    @Published var mode: Mode = .running

    @Published var wallpaper: NSImage?
    @Published var wallpaperCredit: String = ""

    // 音频源（休息时可能有多个应用同时在出声）
    struct AudioRow: Identifiable {
        let id: String
        /// 歌名 / 视频标题 / 页签标题，拿不到时是应用名
        let title: String
        /// 歌手 · 专辑；浏览器是站点名；再不行是状态提示
        let detail: String?
        /// 应用图标（界面里放大了当主视觉）
        let icon: NSImage?
        let isNowPlaying: Bool
        let channel: MediaChannel
        let canNext: Bool
        var paused: Bool
        var busy: Bool
    }

    @Published var audioRows: [AudioRow] = []
    @Published var audioBusyAll = false
    @Published var audioNotice: String?

    @Published var workLabel: String = "约 10 分钟"
    @Published var postponeLabel: String = "5 分钟"

    /// 严格模式 / 延后开关决定休息界面上哪些按钮可用
    @Published var canSkip = true
    @Published var canPostpone = true

    var onSkip: (() -> Void)?
    var onPostpone: (() -> Void)?
    var onContinue: (() -> Void)?
    var onExtend: (() -> Void)?
    var onToggleAudio: ((String) -> Void)?
    var onNextAudio: ((String) -> Void)?
    var onPauseAllAudio: (() -> Void)?

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    var pausedAudioCount: Int { audioRows.filter(\.paused).count }

    /// 还能一键暂停的（已经暂停的、不支持控制的不算）
    var pausableAudioCount: Int { audioRows.filter { !$0.paused && $0.channel.isControllable }.count }

    var audioHeading: String {
        if !audioRows.isEmpty, pausedAudioCount == audioRows.count { return "音频 · 已全部暂停" }
        return "音频 · \(audioRows.count) 个应用"
    }

    var footerHint: String {
        if mode != .running { return "点击按钮或按任意键继续" }
        if !canSkip { return "严格模式：这次休息不能跳过" }
        return "按 Esc 跳过本次休息"
    }
}
