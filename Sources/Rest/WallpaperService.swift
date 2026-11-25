import AppKit
import Foundation

struct Wallpaper {
    let image: NSImage
    let credit: String
}

/// 必应每日壁纸：https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN
/// 返回 4K 原图（uhd=1），并按天缓存到 Application Support，断网时回退到最近一张。
enum WallpaperService {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Rest/wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func load(market: String) async -> Wallpaper? {
        let stamp = dayStamp()
        let cacheFile = cacheDirectory.appendingPathComponent("\(stamp)-\(market).jpg")
        let creditFile = cacheDirectory.appendingPathComponent("\(stamp)-\(market).txt")

        if let image = NSImage(contentsOf: cacheFile) {
            let credit = (try? String(contentsOf: creditFile, encoding: .utf8)) ?? ""
            return Wallpaper(image: image, credit: credit)
        }

        guard let wallpaper = await download(market: market) else {
            return latestCached()
        }

        if let tiff = wallpaper.image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
            try? jpeg.write(to: cacheFile)
            try? wallpaper.credit.write(to: creditFile, atomically: true, encoding: .utf8)
            cleanOldCaches(keeping: cacheFile)
        }
        return wallpaper
    }

    private static func download(market: String) async -> Wallpaper? {
        guard let api = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=\(market)"),
              let (data, _) = try? await session.data(from: api),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]],
              let first = images.first,
              var path = first["url"] as? String else { return nil }

        if path.hasPrefix("/") { path = "https://www.bing.com" + path }
        path += (path.contains("?") ? "&" : "?") + "uhd=1&uhdwidth=3840&uhdheight=2160"

        guard let imageURL = URL(string: path),
              let (imageData, _) = try? await session.data(from: imageURL),
              let image = NSImage(data: imageData) else { return nil }

        let credit = (first["copyright"] as? String) ?? ""
        return Wallpaper(image: image, credit: credit)
    }

    private static func latestCached() -> Wallpaper? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "jpg" }) else { return nil }

        let newest = files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let newest, let image = NSImage(contentsOf: newest) else { return nil }
        let creditURL = newest.deletingPathExtension().appendingPathExtension("txt")
        let credit = (try? String(contentsOf: creditURL, encoding: .utf8)) ?? ""
        return Wallpaper(image: image, credit: credit)
    }

    private static func cleanOldCaches(keeping: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent != keeping.lastPathComponent
            && !file.lastPathComponent.hasPrefix(keeping.deletingPathExtension().lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    /// 提前把今天的壁纸下好，休息开始时就不用等网络
    static func prefetch(market: String) {
        Task.detached(priority: .utility) {
            _ = await load(market: market)
        }
    }
}
