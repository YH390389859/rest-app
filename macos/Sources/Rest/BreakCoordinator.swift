import AppKit
import SwiftUI

/// 把「调度器 → 遮罩窗口 → 媒体暂停」串起来的地方
@MainActor
final class BreakCoordinator {
    private let settings: AppSettings
    private let scheduler: Scheduler
    private let vm = BreakViewModel()
    private let windowController: BreakWindowController
    private let media = MediaController.shared
    private var isPreview = false

    /// 当前这轮休息看到的音频源（点击行按钮时按 id 找回来）
    private var sources: [MediaSource] = []
    /// 已被我们暂停、但可能已经从音频列表里消失的应用（保留在界面上，方便手动恢复）
    private var pausedExtras: [String: MediaSource] = [:]
    private var busyAudioIDs: Set<String> = []
    private var audioRefreshTask: Task<Void, Never>?

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
        vm.onToggleAudio = { [weak self] id in self?.toggleAudio(id) }
        vm.onPauseAllAudio = { [weak self] in
            Task { await self?.pauseAllAudio() }
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
        NSLog("Rest: 休息开始 \(kind.rawValue) \(Int(duration))s")

        vm.kind = kind
        vm.total = duration
        vm.remaining = duration
        vm.mode = .running
        vm.audioRows = []
        vm.audioNotice = nil
        vm.audioBusyAll = false
        sources = []
        pausedExtras = [:]
        busyAudioIDs = []
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
        // 传闭包而不是数组：休息途中改分辨率/插拔屏幕时要按当前设置重新算
        windowController.show(on: screens) { [weak self] in
            guard let self else { return NSScreen.screens }
            return self.settings.allDisplays
                ? NSScreen.screens
                : [NSScreen.main].compactMap { $0 }
        }

        loadWallpaper()
        startAudioTracking()
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

    // MARK: 音频

    /// 休息开始时抓一次音频源，之后每 5 秒刷新（用户中途开新视频也能列出来）
    private func startAudioTracking() {
        audioRefreshTask?.cancel()
        let autoPause = settings.autoPauseMedia
        audioRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAudio(pausePlaying: autoPause)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, self.scheduler.currentKind != nil else { break }
                await self.refreshAudio(pausePlaying: false)
            }
        }
    }

    private func refreshAudio(pausePlaying: Bool) async {
        let list = await media.snapshot()
        sources = list
        applyAudioRows(list)

        guard pausePlaying else { return }
        let targets = list.filter { !media.isPaused($0.bundleID) && $0.channel.isControllable }
        guard !targets.isEmpty else { return }

        vm.audioBusyAll = true
        var failed: [String] = []
        for source in targets {
            if await media.pause(source) == nil {
                failed.append(source.name)
            } else {
                pausedExtras[source.bundleID] = source
            }
        }
        vm.audioBusyAll = false
        applyAudioRows(sources)
        if !failed.isEmpty {
            vm.audioNotice = "「\(failed.joined(separator: "、"))」没响应暂停指令，可以手动暂停"
        }
    }

    private func applyAudioRows(_ list: [MediaSource]) {
        var merged = list
        for (id, source) in pausedExtras
        where media.isPaused(id) && !merged.contains(where: { $0.bundleID == id }) {
            merged.append(source)
        }

        vm.audioRows = merged.map { source in
            BreakViewModel.AudioRow(id: source.bundleID,
                                    title: source.displayTitle,
                                    detail: detail(for: source),
                                    icon: source.icon(),
                                    isNowPlaying: source.isNowPlaying,
                                    channel: source.channel,
                                    paused: media.isPaused(source.bundleID),
                                    busy: busyAudioIDs.contains(source.bundleID))
        }
    }

    private func detail(for source: MediaSource) -> String? {
        if let detail = source.displayDetail { return detail }
        if media.isPaused(source.bundleID) { return nil }
        if source.isBrowser { return "网页音频" }
        if source.channel == .mediaRemote { return "系统正在播放" }
        if source.channel == .accessibility, !PerAppMediaControl.accessibilityTrusted {
            return "需「辅助功能」授权"
        }
        return "正在播放"
    }

    private func toggleAudio(_ id: String) {
        Task { [weak self] in
            guard let self,
                  let source = self.sources.first(where: { $0.bundleID == id }) ?? self.pausedExtras[id] else {
                return
            }

            if self.media.isPaused(id) {
                self.pausedExtras[id] = nil
                await self.media.resume(bundleID: id)
                self.applyAudioRows(self.sources)
                return
            }

            self.busyAudioIDs.insert(id)
            self.applyAudioRows(self.sources)
            // 需要辅助功能但还没授权：这次先拉起系统引导，授权后再点一次就生效
            if source.channel == .accessibility, !PerAppMediaControl.accessibilityTrusted {
                PerAppMediaControl.requestAccessibility()
            }
            let channel = await self.media.pause(source)
            self.busyAudioIDs.remove(id)

            if channel != nil {
                self.pausedExtras[id] = source
                self.vm.audioNotice = nil
            } else {
                self.vm.audioNotice = self.failureNotice(for: source)
            }
            self.applyAudioRows(self.sources)
        }
    }

    private func pauseAllAudio() async {
        guard !vm.audioBusyAll else { return }
        vm.audioBusyAll = true
        defer { vm.audioBusyAll = false }

        var failed: [String] = []
        for source in sources where !media.isPaused(source.bundleID) && source.channel.isControllable {
            if await media.pause(source) == nil {
                failed.append(source.name)
            } else {
                pausedExtras[source.bundleID] = source
            }
        }
        applyAudioRows(sources)
        vm.audioNotice = failed.isEmpty
            ? nil
            : "「\(failed.joined(separator: "、"))」没响应暂停指令，可以手动暂停"
    }

    private func failureNotice(for source: MediaSource) -> String {
        if source.channel == .accessibility, !PerAppMediaControl.accessibilityTrusted {
            return "「\(source.name)」需要「辅助功能」授权，允许后再点一次即可"
        }
        return "「\(source.name)」没响应暂停指令，可以手动暂停"
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

        audioRefreshTask?.cancel()
        audioRefreshTask = nil
        sources = []
        pausedExtras = [:]
        busyAudioIDs = []
        vm.audioRows = []
        vm.audioNotice = nil

        if settings.resumeMediaAfterBreak {
            Task { await media.resumeAll() }
        } else {
            media.discardPaused()
        }
    }
}
