// 生成 AppIcon.icns：渐变圆角方块 + 白色茶杯
// 用法：swift tools/make-icon.swift Resources/AppIcon.icns
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.icns"

// MARK: - 绘制一张

func renderIcon(pixels S: CGFloat) -> CGImage? {
    guard let ctx = CGContext(data: nil,
                              width: Int(S), height: Int(S),
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Apple 的图标网格：1024 画布里内容区 824，圆角半径 185
    let inset = S * 100 / 1024
    let radius = S * 185 / 1024
    let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // 底色：薄荷绿 → 海蓝
    let colors = [
        CGColor(red: 0.44, green: 0.83, blue: 0.73, alpha: 1),
        CGColor(red: 0.18, green: 0.42, blue: 0.56, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
    }

    // 左上角一层柔光，避免纯平
    if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
                                      CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                             locations: [0, 1]) {
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: rect.minX + rect.width * 0.22,
                                                    y: rect.maxY - rect.height * 0.16),
                               startRadius: 0,
                               endCenter: CGPoint(x: rect.minX + rect.width * 0.22,
                                                  y: rect.maxY - rect.height * 0.16),
                               endRadius: rect.width * 0.85,
                               options: [])
    }

    // 茶杯
    let withSteam = S >= 128
    let box = rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.20)
    if let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: S * 0.5, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) {
        let scale = min(box.width / symbol.size.width, box.height / symbol.size.height)
        let w = symbol.size.width * scale
        let h = symbol.size.height * scale
        let target = NSRect(x: rect.midX - w / 2,
                            y: rect.midY - h / 2 - rect.height * 0.035,
                            width: w, height: h)

        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)

        // 热气：细一点、左右等高，小尺寸下省略，否则会糊成一团
        if withSteam {
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.setLineWidth(S * 0.013)
            ctx.setLineCap(.round)
            let y0 = target.maxY + rect.height * 0.03
            for dx in [-0.075, 0.075] as [CGFloat] {
                let x = rect.midX + rect.width * dx
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x, y: y0))
                path.addCurve(to: CGPoint(x: x, y: y0 + rect.height * 0.10),
                              control1: CGPoint(x: x + S * 0.032, y: y0 + rect.height * 0.035),
                              control2: CGPoint(x: x - S * 0.032, y: y0 + rect.height * 0.068))
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    ctx.restoreGState()
    return ctx.makeImage()
}

// MARK: - 输出 iconset

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    guard let image = renderIcon(pixels: CGFloat(v.px)) else {
        FileHandle.standardError.write("渲染失败: \(v.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: v.px, height: v.px)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: iconset.appendingPathComponent("\(v.name).png"))
}

// 顺手留一张 1024 预览，方便肉眼检查
if let big = renderIcon(pixels: 1024) {
    let rep = NSBitmapImageRep(cgImage: big)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "/tmp/appicon-1024.png"))
    }
}

let out = URL(fileURLWithPath: outPath)
try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
print("已生成 \(out.path)（\(variants.count) 个尺寸）")
