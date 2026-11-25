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

    // 媒体相关
    @Published var mediaAppName: String?
    @Published var mediaPaused = false
    @Published var busyPausing = false
    @Published var mediaNotice: String?

    @Published var workLabel: String = "20 分钟"
    @Published var postponeLabel: String = "5 分钟"

    var onSkip: (() -> Void)?
    var onPostpone: (() -> Void)?
    var onContinue: (() -> Void)?
    var onExtend: (() -> Void)?
    var onPauseMedia: (() -> Void)?

    var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    var hasMediaAction: Bool { mediaAppName != nil && !mediaPaused }

    var footerHint: String {
        mode == .running ? "按 Esc 跳过本次休息" : "点击按钮或按任意键继续"
    }
}
