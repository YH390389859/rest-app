import AppKit
import Foundation

struct Wallpaper {
    let image: NSImage
    let credit: String
    let id: String
}

/// 必应每日壁纸。
///
/// 需求是「每次进入休息都换一张」，而 `idx=0&n=1` 一天只有一张图，
/// 所以这里取 `n=8`（必应保留的最近 8 天），用持久化游标在它们之间轮换，
/// 并按图片 id 缓存文件——同一张图第二次用到就不再下载。
///
/// 另外提供 `prepareNext`：显示当前这张的同时，后台把下一张拉好，
/// 这样下一次休息是「立刻」出现新壁纸，不用等网络。
@MainActor
enum WallpaperService {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 已预取、等待下一次休息使用的壁纸（按地区）
    private static var preloaded: [String: Wallpaper] = [:]
    private static var preparing: Set<String> = []

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Rest/wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Item {
        let id: String
        let url: URL
        let credit: String
    }

    // MARK: 对外

    /// 取一张新的壁纸（游标轮换，并跳过与上一张重复的）
    static func nextWallpaper(market: String) async -> Wallpaper? {
        guard let items = await archive(market: market) else {
            return latestCached()
        }

        let cursorKey = "wallpaperCursor-\(market)"
        let lastKey = "wallpaperLast-\(market)"
        let defaults = UserDefaults.standard

        var cursor = defaults.integer(forKey: cursorKey)
        var picked = items[cursor % items.count]
        if items.count > 1, picked.id == defaults.string(forKey: lastKey) {
            cursor += 1
            picked = items[cursor % items.count]
        }
        cursor += 1
        defaults.set(cursor, forKey: cursorKey)
        defaults.set(picked.id, forKey: lastKey)

        NSLog("Rest: 本次壁纸 \(picked.id)")
        return await download(picked) ?? latestCached()
    }

    /// 取走已预取好的那一张（有则立刻可用）
    static func takePreloaded(market: String) -> Wallpaper? {
        guard let wallpaper = preloaded[market] else { return nil }
        preloaded[market] = nil
        return wallpaper
    }

    /// 后台准备下一张
    static func prepareNext(market: String) {
        guard preloaded[market] == nil, !preparing.contains(market) else { return }
        preparing.insert(market)
        Task {
            let wallpaper = await nextWallpaper(market: market)
            preparing.remove(market)
            if let wallpaper { preloaded[market] = wallpaper }
        }
    }

    // MARK: 内部

    private static func archive(market: String) async -> [Item]? {
        guard let api = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=\(market)"),
              let (data, _) = try? await session.data(from: api),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]] else {
            return nil
        }

        var items: [Item] = []
        for dict in images {
            guard var path = dict["url"] as? String else { continue }
            if path.hasPrefix("/") { path = "https://www.bing.com" + path }
            path += (path.contains("?") ? "&" : "?") + "uhd=1&uhdwidth=3840&uhdheight=2160"
            guard let url = URL(string: path) else { continue }
            items.append(Item(id: safeID(from: path),
                              url: url,
                              credit: dict["copyright"] as? String ?? ""))
        }
        return items.isEmpty ? nil : items
    }

    /// 从 `...&id=OHR.Xxx_ZH-CN12345_1920x1080.jpg&...` 取出稳定的图片 id
    private static func safeID(from path: String) -> String {
        var raw: String
        if let range = path.range(of: "id=") {
            raw = String(path[range.upperBound...].prefix { $0 != "&" })
        } else {
            var hash: UInt64 = 1469598103934665603
            for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
            raw = String(hash, radix: 16)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = raw.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        return cleaned.isEmpty ? "bing" : String(cleaned.prefix(80))
    }

    private static func download(_ item: Item) async -> Wallpaper? {
        let file = cacheDirectory.appendingPathComponent("\(item.id).jpg")
        let creditFile = cacheDirectory.appendingPathComponent("\(item.id).txt")

        if let image = NSImage(contentsOf: file) {
            let credit = item.credit.isEmpty
                ? ((try? String(contentsOf: creditFile, encoding: .utf8)) ?? "")
                : item.credit
            return Wallpaper(image: image, credit: credit, id: item.id)
        }

        guard let (data, _) = try? await session.data(from: item.url),
              let image = NSImage(data: data) else { return nil }

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
            try? jpeg.write(to: file)
            try? item.credit.write(to: creditFile, atomically: true, encoding: .utf8)
            trimCache()
        }
        return Wallpaper(image: image, credit: item.credit, id: item.id)
    }

    private static func latestCached() -> Wallpaper? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "jpg" }), !files.isEmpty else { return nil }

        guard let newest = files.max(by: { date($0) < date($1) }),
              let image = NSImage(contentsOf: newest) else { return nil }
        let creditFile = newest.deletingPathExtension().appendingPathExtension("txt")
        let credit = (try? String(contentsOf: creditFile, encoding: .utf8)) ?? ""
        return Wallpaper(image: image, credit: credit, id: newest.deletingPathExtension().lastPathComponent)
    }

    private static func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// 只保留最近 24 张，避免缓存无限增长
    private static func trimCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "jpg" }) else { return }
        guard files.count > 24 else { return }
        let sorted = files.sorted { date($0) > date($1) }
        for old in sorted.dropFirst(24) {
            try? fm.removeItem(at: old)
            try? fm.removeItem(at: old.deletingPathExtension().appendingPathExtension("txt"))
        }
    }
}
