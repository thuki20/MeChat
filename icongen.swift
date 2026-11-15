import AppKit
import Foundation

// 生成 MeChat 微信风格 LOGO 的 iconset（各尺寸 PNG）
// 用法: icongen <输出 iconset 目录>

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./MeChat.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func draw(into rep: NSBitmapImageRep, size: CGFloat) {
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size

    // 微信绿底圆角方块
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.22, yRadius: s * 0.22)
    NSColor(calibratedRed: 0.027, green: 0.757, blue: 0.376, alpha: 1).setFill()
    bg.fill()

    // 白色双聊天气泡
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.16, y: s * 0.36, width: s * 0.54, height: s * 0.34),
                 xRadius: s * 0.10, yRadius: s * 0.10).fill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.46, y: s * 0.22, width: s * 0.36, height: s * 0.30),
                 xRadius: s * 0.09, yRadius: s * 0.09).fill()

    // 气泡上的"眼睛"（绿色圆点）
    NSColor(calibratedRed: 0.027, green: 0.757, blue: 0.376, alpha: 1).setFill()
    for p in [CGPoint(x: s * 0.30, y: s * 0.55), CGPoint(x: s * 0.50, y: s * 0.55),
              CGPoint(x: s * 0.59, y: s * 0.36), CGPoint(x: s * 0.72, y: s * 0.36)] {
        NSBezierPath(ovalIn: NSRect(x: p.x - s * 0.024, y: p.y - s * 0.024,
                                    width: s * 0.048, height: s * 0.048)).fill()
    }

    // "MeChat" 字样（仅在较大尺寸清晰，小尺寸保留气泡识别度）
    if s >= 128 {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: s * 0.14),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para
        ]
        let txt = "MeChat" as NSString
        txt.draw(in: NSRect(x: 0, y: s * 0.04, width: s, height: s * 0.20), withAttributes: attrs)
    }
}

// name -> (png尺寸, 是否为 @2x)
let jobs: [(String, Int, Bool)] = [
    ("icon_16x16.png", 16, false),
    ("icon_16x16@2x.png", 32, true),
    ("icon_32x32.png", 32, false),
    ("icon_32x32@2x.png", 64, true),
    ("icon_128x128.png", 128, false),
    ("icon_128x128@2x.png", 256, true),
    ("icon_256x256.png", 256, false),
    ("icon_256x256@2x.png", 512, true),
    ("icon_512x512.png", 512, false),
    ("icon_512x512@2x.png", 1024, true),
]

for (name, px, _) in jobs {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    draw(into: rep, size: CGFloat(px))
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: outputDir + "/" + name))
        print("wrote \(name)")
    }
}
print("done: \(outputDir)")