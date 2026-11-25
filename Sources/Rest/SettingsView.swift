import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onPreview: () -> Void = {}

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
                Text("检测方式：CoreAudio 进程音频流 + 系统 Now Playing 状态；暂停通过系统媒体控制下发，不需要额外权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("视频与音乐")
            }

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
                    Button("打开辅助功能设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text("只有在极少数播放器不响应系统媒体控制时，才会退化为模拟媒体键，那时需要「辅助功能」授权。")
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
