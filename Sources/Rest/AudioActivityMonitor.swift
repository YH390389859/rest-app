import Foundation
import CoreAudio
import AppKit

/// 一个正在使用音频输出的应用
struct AudioApp: Identifiable, Hashable {
    let pid: pid_t
    let bundleID: String
    let name: String

    var id: String { "\(bundleID)#\(pid)" }
}

/// 基于 CoreAudio 的「进程对象」枚举（macOS 14.2+ 公开 API，无需任何权限）
///
/// 关键属性：
///  - kAudioHardwarePropertyProcessObjectList  系统里所有参与音频的进程对象
///  - kAudioProcessPropertyIsRunningOutput     该进程当前是否有活跃的输出流
///  - kAudioProcessPropertyBundleID            进程的 bundle id
enum AudioActivityMonitor {

    /// 系统守护进程 / 我们自己的进程，不算「用户在播放东西」
    private static let ignoredBundlePrefixes = [
        "com.yanghui.rest",
        "com.apple.mediaremoted",
        "com.apple.audiomxd",
        "systemsoundserverd",
        "com.apple.controlcenter",
        "com.apple.accessibility",
        "com.apple.avconferenced",
        "com.apple.CoreSpeech",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.speech",
        "com.apple.TelephonyUtilities",
        "com.apple.cmio",
        "com.apple.cloudpaird",
        "com.apple.MediaRemoteUIService",
        "com.apple.siri",
    ]

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func pid(_ object: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : -1
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let raw = value else { return nil }
        let str = raw.takeRetainedValue() as String
        return str.isEmpty ? nil : str
    }

    /// 当前所有正在输出音频的应用（已去重、已过滤系统进程）
    static func outputApps() -> [AudioApp] {
        var listAddr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &listAddr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &listAddr, 0, nil, &size, &objects) == noErr else {
            return []
        }

        var seen = Set<String>()
        var result: [AudioApp] = []

        for object in objects {
            guard uint32(object, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }

            let processID = pid(object)
            guard processID > 0, processID != getpid() else { continue }

            let bundle = bundleID(object)
                ?? NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
                ?? ""

            if let b = bundle.isEmpty ? nil : bundle,
               ignoredBundlePrefixes.contains(where: { b.hasPrefix($0) }) {
                continue
            }

            // Chromium / WebKit 的音频跑在 helper 进程里，归并到主应用
            var displayBundle = bundle
            let runningApp = NSRunningApplication(processIdentifier: processID)
            var displayName = runningApp?.localizedName
                ?? runningApp?.executableURL?.lastPathComponent
                ?? processName(processID)
            if bundle.contains(".helper") {
                let base = bundle.components(separatedBy: ".helper").first ?? bundle
                if let parent = NSRunningApplication.runningApplications(withBundleIdentifier: base).first {
                    displayBundle = base
                    displayName = parent.localizedName ?? displayName
                }
            }
            if displayBundle.isEmpty { displayBundle = "pid:\(processID)" }
            if seen.contains(displayBundle) { continue }
            seen.insert(displayBundle)

            result.append(AudioApp(pid: processID,
                                   bundleID: displayBundle,
                                   name: displayName ?? displayBundle))
        }

        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 命令行进程（afplay 之类）没有 bundle 也没有 localizedName，靠 proc_name 兜底
    private static func processName(_ processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = proc_name(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 是否有应用正在使用音频输出（注意：部分播放器暂停后仍保持输出流，所以这不等价于「正在播放」）
    static var hasAudioOutput: Bool { !outputApps().isEmpty }
}
