import SwiftUI

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(prominent ? Color.white : Color.white.opacity(0.14))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.white)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(prominent ? 0 : 0.22), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct MiniPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 4.5)
            .background(Color.white.opacity(0.14), in: Capsule())
            .foregroundStyle(.white.opacity(0.95))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct BreakView: View {
    @ObservedObject var vm: BreakViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if vm.mode == .shield {
                    Color.clear
                } else {
                    wallpaperLayer(size: geo.size)
                    content
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: vm.mode)
    }

    // MARK: 背景

    @ViewBuilder
    private func wallpaperLayer(size: CGSize) -> some View {
        ZStack {
            if let image = vm.wallpaper {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.16),
                                        Color(red: 0.12, green: 0.20, blue: 0.28)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.38)
            // 中间压暗一点，保证文案在明亮的壁纸上也看得清
            RadialGradient(colors: [.black.opacity(0.34), .black.opacity(0.12), .clear],
                           center: .center,
                           startRadius: 0,
                           endRadius: max(size.width, size.height) * 0.55)
            RadialGradient(colors: [.clear, .black.opacity(0.5)],
                           center: .center,
                           startRadius: max(size.width, size.height) * 0.35,
                           endRadius: max(size.width, size.height) * 0.8)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: 内容

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            Text(vm.kind.title)
                .font(.system(size: 14, weight: .bold))
                .tracking(8)
                .foregroundStyle(.white.opacity(0.85))
                .textCase(.uppercase)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 1)

            Spacer().frame(height: 34)

            if vm.mode == .finishedManual {
                finishedBlock
            } else {
                runningBlock
            }

            Spacer(minLength: 40)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 48)
        .transition(.opacity)
    }

    private var runningBlock: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.13), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: vm.progress)
                    .stroke(Color.white.opacity(0.92),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: vm.progress)

                VStack(spacing: 2) {
                    Text(formatClock(vm.remaining))
                        .font(.system(size: 78, weight: .thin, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 14)
                    Text("剩余")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 262, height: 262)

            Text(vm.kind.caption)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 1)

            audioCard

            HStack(spacing: 12) {
                Button("延后 \(vm.postponeLabel)") { vm.onPostpone?() }
                    .buttonStyle(PillButtonStyle())
                    .opacity(vm.canPostpone ? 1 : 0)
                    .disabled(!vm.canPostpone)
                Button("跳过") { vm.onSkip?() }
                    .buttonStyle(PillButtonStyle())
                    .opacity(vm.canSkip ? 1 : 0)
                    .disabled(!vm.canSkip)
            }
            .padding(.top, 4)
        }
    }

    // MARK: 音频卡片

    @ViewBuilder
    private var audioCard: some View {
        if !vm.audioRows.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(vm.audioHeading)
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 16)
                    if vm.pausableAudioCount > 0 {
                        Button(vm.audioBusyAll ? "正在暂停…" : "全部暂停") { vm.onPauseAllAudio?() }
                            .buttonStyle(MiniPillButtonStyle())
                            .disabled(vm.audioBusyAll)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 32)

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 0.5)

                rowsStack

                if let notice = vm.audioNotice {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 0.5)
                        Text(notice)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: 500)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.06), .clear],
                                                 startPoint: .top,
                                                 endPoint: .center))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .animation(.easeInOut(duration: 0.2), value: vm.audioNotice)
        }
    }

    /// 超过 3 个时压缩行高；最多列 5 个，其余在底部说明（「全部暂停」仍会一并处理）
    private var isCompactAudio: Bool { vm.audioRows.count > 3 }
    private var audioRowHeight: CGFloat { isCompactAudio ? 52 : 64 }
    private var iconSide: CGFloat { isCompactAudio ? 34 : 46 }
    private var visibleAudioRows: [BreakViewModel.AudioRow] { Array(vm.audioRows.prefix(5)) }
    private var hiddenAudioCount: Int { max(0, vm.audioRows.count - 5) }

    private var rowsStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleAudioRows.enumerated()), id: \.element.id) { index, row in
                audioRow(row)
                if index < visibleAudioRows.count - 1 {
                    divider
                }
            }
            if hiddenAudioCount > 0 {
                divider
                Text("还有 \(hiddenAudioCount) 个应用，可用「全部暂停」一起处理")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
            }
        }
        .padding(.vertical, 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
            .padding(.leading, 14 + iconSide + 11)
    }

    private func audioRow(_ row: BreakViewModel.AudioRow) -> some View {
        HStack(spacing: 11) {
            iconTile(row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: isCompactAudio ? 12.5 : 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(row.paused ? 0.62 : 0.98))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: isCompactAudio ? 10 : 11))
                        .foregroundStyle(.white.opacity(row.paused ? 0.38 : 0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            audioAction(for: row)
        }
        .padding(.horizontal, 14)
        .frame(height: audioRowHeight)
        .contentShape(Rectangle())
    }

    /// 主视觉用应用自己的图标：比抓专辑封面稳定，也一眼能看出是哪个应用在响
    private func iconTile(_ row: BreakViewModel.AudioRow) -> some View {
        let side = iconSide
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.17), Color.white.opacity(0.05)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))

            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side * 0.68, height: side * 0.68)
            } else {
                Text(String(row.title.prefix(1)))
                    .font(.system(size: side * 0.38, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.6)
        )
        .opacity(row.paused ? 0.6 : 1)
        .saturation(row.paused ? 0.4 : 1)
    }

    @ViewBuilder
    private func audioAction(for row: BreakViewModel.AudioRow) -> some View {
        if row.busy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 58, height: 22)
        } else if !row.channel.isControllable {
            Text("无法自动暂停")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.38))
        } else {
            circleControl(row.paused ? "play.fill" : "pause.fill",
                          size: 11,
                          help: row.paused ? "恢复播放" : "暂停") {
                vm.onToggleAudio?(row.id)
            }
        }
    }

    private func circleControl(_ symbol: String,
                               size: CGFloat,
                               help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var finishedBlock: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.9))

            VStack(spacing: 8) {
                Text("休息结束")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                Text("准备好了就继续，下一轮 \(vm.workLabel)")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.68))
            }

            HStack(spacing: 12) {
                Button("开始下一轮 · \(vm.workLabel)") { vm.onContinue?() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button("再休息 1 分钟") { vm.onExtend?() }
                    .buttonStyle(PillButtonStyle())
            }
            .padding(.top, 6)
        }
    }

    private var footer: some View {
        HStack {
            Text(vm.footerHint)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .shadow(color: .black.opacity(0.4), radius: 6)
            Spacer()
            if !vm.wallpaperCredit.isEmpty {
                Text(vm.wallpaperCredit)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 520, alignment: .trailing)
            }
        }
        .padding(.bottom, 22)
    }
}
