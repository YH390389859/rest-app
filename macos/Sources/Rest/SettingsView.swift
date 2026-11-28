import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onPreview: () -> Void = {}

    @State private var mediaAccessTrusted = PerAppMediaControl.accessibilityTrusted
    @State private var mediaAuthHint: String?
    @State private var authPollTask: Task<Void, Never>?

    /// 点「去授权」：弹系统引导（可能已经被系统吞掉）+ 一定打开设置面板，然后轮询授权状态
    private func requestMediaAccess() {
        PerAppMediaControl.requestAccessibility()
        mediaAuthHint = "已打开「系统设置 → 隐私与安全性 → 辅助功能」，在列表里把 Rest 勾上（没有这一项就点「+」添加 build/Rest.app）。授权后这里会自动变成「已授权」。"
        startAuthPolling()
    }

    /// 系统设置是另一个进程，勾选后不会通知我们，只能轮询
    private func startAuthPolling() {
        authPollTask?.cancel()
        authPollTask = Task {
            for _ in 0..<180 {
                if Task.isCancelled { return }
                if PerAppMediaControl.accessibilityTrusted {
                    mediaAccessTrusted = true
                    mediaAuthHint = "已获得辅助功能权限，Chrome / Safari 这类应用的「暂停」按钮现在可以自动按了。"
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private let markets: [(code: String, name: String)] = [
        ("zh-CN", "中国"),
        ("en-US", "美国"),
        ("ja-JP", "日本"),
        ("en-GB", "英国"),
        ("de-DE", "德国"),
        ("fr-FR", "法国"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("启用「小憩」", isOn: $settings.microEnabled)
                LabeledContent("持续时间") {
                    Stepper(value: $settings.microBreakSeconds, in: 5...300, step: 5) {
                        Text("\(Int(settings.microBreakSeconds)) 秒").monospacedDigit()
                    }
                }
                LabeledContent("每") {
                    Stepper(value: $settings.microBreakEveryMinutes, in: 1...120, step: 1) {
                        Text("\(Int(settings.microBreakEveryMinutes)) 分钟").monospacedDigit()
                    }
                }
                Toggle("允许延后小憩", isOn: $settings.microAllowPostpone)
                    .disabled(!settings.microEnabled || settings.microStrictMode)
                Toggle("严格模式（不能跳过小憩）", isOn: $settings.microStrictMode)
                    .disabled(!settings.microEnabled)
            } header: {
                Text("小憩")
            } footer: {
                Text("「小憩」是频率较高的短暂休息，可以用来伸展和放松。默认每 10 分钟一次，每次 20 秒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("启用「休息」", isOn: $settings.longEnabled)
                LabeledContent("持续时间") {
                    Stepper(value: $settings.longBreakMinutes, in: 1...60, step: 1) {
                        Text("\(Int(settings.longBreakMinutes)) 分钟").monospacedDigit()
                    }
                }
                LabeledContent("每") {
                    Stepper(value: $settings.microsBeforeLong, in: 1...12, step: 1) {
                        Text("\(Int(settings.microsBeforeLong)) 次小憩（约每 \(Int(settings.longCycleMinutes)) 分钟）")
                            .monospacedDigit()
                    }
                }
                Toggle("允许延后休息", isOn: $settings.longAllowPostpone)
                    .disabled(!settings.longEnabled || settings.longStrictMode)
                Toggle("严格模式（不能跳过休息）", isOn: $settings.longStrictMode)
                    .disabled(!settings.longEnabled)
            } header: {
                Text("休息")
            } footer: {
                Text("「休息」频率较低、持续时间更长。默认每 3 个槽位一次，也就是 2 次小憩后、约 30 分钟时来一次 5 分钟的休息。\n休息是挂在槽位上的：小憩间隔 ×（小憩次数 + 1）。修改后从下一轮开始生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("延后时长") {
                    Stepper(value: $settings.postponeMinutes, in: 1...30, step: 1) {
                        Text("\(Int(settings.postponeMinutes)) 分钟").monospacedDigit()
                    }
                }
            } header: {
                Text("延后")
            }

            Section {
                Picker("倒计时结束后", selection: $settings.breakEndBehavior) {
                    ForEach(BreakEndBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.breakEndBehavior.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("休息结束后的行为")
            }

            Section {
                Toggle("休息开始时自动暂停正在播放的视频 / 音乐", isOn: $settings.autoPauseMedia)
                Toggle("休息结束后自动恢复播放", isOn: $settings.resumeMediaAfterBreak)
                    .disabled(!settings.autoPauseMedia)
                LabeledContent("辅助功能权限") {
                    HStack(spacing: 8) {
                        if mediaAccessTrusted {
                            Label("已授权", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.green)
                        } else {
                            Button("去授权") { requestMediaAccess() }
                            Button("重新检测") { mediaAccessTrusted = PerAppMediaControl.accessibilityTrusted }
                        }
                    }
                }
                if let mediaAuthHint {
                    Text(mediaAuthHint)
                        .font(.caption)
                        .foregroundStyle(mediaAccessTrusted ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("多个播放器同时出声时，会逐个应用暂停：系统正在播放的那个走系统媒体控制（无需权限），其余应用优先用它们自己的 AppleScript 脚本，再退化为辅助功能按下「暂停」按钮。没有辅助功能权限时，列表里仍会显示每个应用，但只能手动暂停。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("注意：本地打包的应用是 ad-hoc 签名，重新编译后签名会变，系统会把旧授权作废。建议把 build/Rest.app 拖到「应用程序」里再用；如果列表里的 Rest 已勾选但这里仍显示未授权，点「−」删掉再重新添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("视频与音乐")
            }
            .onAppear {
                mediaAccessTrusted = PerAppMediaControl.accessibilityTrusted
                if !mediaAccessTrusted { startAuthPolling() }
            }
            .onDisappear { authPollTask?.cancel() }

            Section {
                Toggle("使用必应每日壁纸作为休息背景", isOn: $settings.useBingWallpaper)
                Picker("壁纸地区", selection: $settings.wallpaperMarket) {
                    ForEach(markets, id: \.code) { market in
                        Text(market.name).tag(market.code)
                    }
                }
                .disabled(!settings.useBingWallpaper)
                Toggle("在全部显示器上显示遮罩", isOn: $settings.allDisplays)
            } header: {
                Text("外观")
            }

            Section {
                Toggle("休息开始 / 结束时播放提示音", isOn: $settings.playSound)
                Toggle("检测到我离开电脑时跳过这次休息", isOn: $settings.skipWhenIdle)
                Toggle("登录时自动启动", isOn: $settings.launchAtLogin)
            } header: {
                Text("其他")
            }

            Section {
                HStack {
                    Button("预览休息界面") { onPreview() }
                    Spacer()
                    Button("打开辅助功能设置") { PerAppMediaControl.openAccessibilitySettings() }
                }
                Text("「辅助功能」用于在播放器界面里按下它的暂停按钮；开发版每次重新编译签名会变，需要重新授权一次（装到「应用程序」文件夹后授权更稳定）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 780)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private var window: NSWindow?
    private let onPreview: () -> Void

    init(settings: AppSettings, onPreview: @escaping () -> Void) {
        self.settings = settings
        self.onPreview = onPreview
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(settings: settings, onPreview: onPreview))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 780),
                               styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered,
                               defer: false)
            win.title = "Rest 设置"
            win.contentView = hosting
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
