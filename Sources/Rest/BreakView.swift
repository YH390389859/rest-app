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

            mediaBanner

            HStack(spacing: 12) {
                if vm.hasMediaAction {
                    Button(vm.busyPausing ? "正在暂停…" : "暂停「\(vm.mediaAppName ?? "")」") {
                        vm.onPauseMedia?()
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(vm.busyPausing)
                }
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

    @ViewBuilder
    private var mediaBanner: some View {
        if let notice = vm.mediaNotice {
            Label(notice, systemImage: "speaker.wave.2")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: Capsule())
        } else if vm.mediaPaused, let name = vm.mediaAppName {
            Label("已暂停「\(name)」的播放", systemImage: "pause.circle")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: Capsule())
        }
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
