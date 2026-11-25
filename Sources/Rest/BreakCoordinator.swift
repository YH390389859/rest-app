import AppKit
import SwiftUI

/// 把「调度器 → 遮罩窗口 → 媒体暂停」串起来的地方
@MainActor
final class BreakCoordinator {
    private let settings: AppSettings
    private let scheduler: Scheduler
    private let vm = BreakViewModel()
    private let windowController: BreakWindowController
    private var pausedMedia: MediaController.PauseResult?
    private var isPreview = false

    private let verbose = CommandLine.arguments.contains("--verbose")
    private var lastLoggedSecond = -1

    init(settings: AppSettings, scheduler: Scheduler) {
        self.settings = settings
        self.scheduler = scheduler
        self.windowController = BreakWindowController(viewModel: vm)
        windowController.onUserReturn = { [weak self] in
            self?.continueToWork()
        }
        wire()
    }

    private func wire() {
        scheduler.onBreakStart = { [weak self] kind, duration in
            self?.handleBreakStart(kind: kind, duration: duration)
        }
        scheduler.onBreakTick = { [weak self] remaining, _ in
            guard let self else { return }
            self.vm.remaining = remaining
            if self.verbose {
                let second = Int(remaining)
                if second != self.lastLoggedSecond {
                    self.lastLoggedSecond = second
                    NSLog("Rest: 倒计时 %d", second)
                }
            }
        }
        scheduler.onBreakFinished = { [weak self] in
            self?.handleBreakFinished()
        }
        scheduler.onWorkStart = { [weak self] in
            self?.handleWorkStart()
        }

        vm.onSkip = { [weak self] in self?.skipCurrentBreak() }
        vm.onPostpone = { [weak self] in self?.postponeBreak() }
        vm.onContinue = { [weak self] in self?.continueToWork() }
        vm.onExtend = { [weak self] in
            self?.scheduler.extendBreak(by: 60)
            self?.vm.mode = .running
        }
        vm.onPauseMedia = { [weak self] in
            Task { await self?.pauseMedia() }
        }
    }

    // MARK: 对外

    func skipCurrentBreak() {
        guard let kind = scheduler.currentKind, settings.allowsSkip(kind) else { return }
        windowController.dismiss()
        scheduler.skipBreak()
    }

    func postponeBreak() {
        guard let kind = scheduler.currentKind, settings.allowsPostpone(kind) else { return }
        windowController.dismiss()
        scheduler.postpone()
    }

    func continueToWork() {
        windowController.dismiss()
        scheduler.beginNextWork()
    }

    /// 从菜单/设置里手动触发一次预览（忽略「人不在电脑前就跳过」的判断）
    func previewBreak() {
        isPreview = true
        scheduler.startBreakNow()
    }

    // MARK: 休息开始

    private func handleBreakStart(kind: BreakKind, duration: TimeInterval) {
        pausedMedia = nil
        NSLog("Rest: 休息开始 \(kind.rawValue) \(Int(duration))s")

        vm.kind = kind
        vm.total = duration
        vm.remaining = duration
        vm.mode = .running
        vm.mediaAppName = nil
        vm.mediaPaused = false
        vm.mediaNotice = nil
        vm.busyPausing = false
        vm.workLabel = settings.nextWorkLabel
        vm.postponeLabel = "\(Int(settings.postponeMinutes)) 分钟"
        vm.canSkip = settings.allowsSkip(kind)
        vm.canPostpone = settings.allowsPostpone(kind)

        // 人不在电脑前就没必要弹遮罩
        let preview = isPreview
        isPreview = false

        if !preview, settings.skipWhenIdle, IdleMonitor.secondsSinceLastInput > settings.idleThreshold {
            NSLog("Rest: 检测到用户离开，跳过本次休息")
            DispatchQueue.main.async { [weak self] in
                self?.scheduler.beginNextWork()
            }
            return
        }

        if settings.playSound { SoundFX.playBreakStart() }

        let screens: [NSScreen] = settings.allDisplays
            ? NSScreen.screens
            : [NSScreen.main].compactMap { $0 }
        windowController.show(on: screens)

        loadWallpaper()
        inspectMedia()
    }

    private func loadWallpaper() {
        guard settings.useBingWallpaper else {
            vm.wallpaper = nil
            vm.wallpaperCredit = ""
            return
        }
        let market = settings.wallpaperMarket

        // 有预取好的就立刻换上，同时后台准备再下一张
        if let ready = WallpaperService.takePreloaded(market: market) {
            apply(ready)
            WallpaperService.prepareNext(market: market)
            return
        }

        Task { [weak self] in
            let wallpaper = await WallpaperService.nextWallpaper(market: market)
            self?.apply(wallpaper)
            WallpaperService.prepareNext(market: market)
        }
    }

    private func apply(_ wallpaper: Wallpaper?) {
        withAnimation(.easeInOut(duration: 0.6)) {
            vm.wallpaper = wallpaper?.image
            vm.wallpaperCredit = wallpaper?.credit ?? ""
        }
    }

    // MARK: 媒体

    private func inspectMedia() {
        Task { [weak self] in
            guard let self else { return }
            let info = await MediaController.shared.currentPlayback()
            guard info.hasAnything else { return }

            self.vm.mediaAppName = info.appName

            if info.isPlaying {
                if self.settings.autoPauseMedia {
                    await self.pauseMedia()
                } else {
                    self.vm.mediaNotice = "「\(info.appName ?? "播放器")」正在播放"
                }
            } else if let first = info.audioApps.first {
                self.vm.mediaNotice = "「\(first.name)」正在占用音频输出"
            }
        }
    }

    private func pauseMedia() async {
        guard !vm.busyPausing else { return }
        vm.busyPausing = true
        defer { vm.busyPausing = false }

        let result = await MediaController.shared.pauseCurrentPlayback(force: true)
        if let result {
            pausedMedia = result
            vm.mediaPaused = true
            vm.mediaAppName = result.appName
            vm.mediaNotice = nil
        } else {
            vm.mediaNotice = "没能自动暂停，可以点按钮再试一次"
        }
    }

    // MARK: 休息结束

    private func handleBreakFinished() {
        if settings.playSound { SoundFX.playBreakEnd() }

        switch settings.breakEndBehavior {
        case .auto:
            NSLog("Rest: 休息结束 → 直接进入下一轮")
            continueToWork()
        case .manual:
            NSLog("Rest: 休息结束 → 等待点击按钮")
            vm.mode = .finishedManual
        case .waitForInput:
            NSLog("Rest: 休息结束 → 进入透明遮罩，等待键鼠动作")
            windowController.beginShield()
        }
    }

    private func handleWorkStart() {
        NSLog("Rest: 进入工作计时 \(Int(scheduler.total))s")
        windowController.dismiss()
        vm.mode = .running

        if let paused = pausedMedia {
            pausedMedia = nil
            if settings.resumeMediaAfterBreak {
                Task { await MediaController.shared.resume(paused) }
            }
        }
    }
}
