import AppKit
import Foundation

// ============================================================
//  微信多开助手 · 原创版（液态玻璃 UI + 实例管理 + 数据来源）
// ============================================================

let ORIGINAL_ID = "com.tencent.xinWeChat"
let appSupportDir = expand("~/Library/Application Support/微信多开助手")
let configPath = appSupportDir + "/instances.json"
let copiesDir = appSupportDir + "/实例"
let sourcePath = "/Applications/WeChat.app"

// MARK: - 工具函数

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

@discardableResult
func shell(_ args: [String]) -> (String, Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return ("\(error)", -1) }
    p.waitUntilExit()
    return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "", p.terminationStatus)
}

// MARK: - 模型

struct Instance: Codable {
    var id: Int
    var name: String
    var colorHex: String
    var dataSource: String  // "fresh" | "seed"
    var bundleId: String
    var appPath: String
}

final class ConfigStore {
    static let shared = ConfigStore()
    var instances: [Instance] = []

    private init() {
        try? FileManager.default.createDirectory(atPath: copiesDir, withIntermediateDirectories: true)
        load()
    }
    func load() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let arr = try? JSONDecoder().decode([Instance].self, from: data) else { return }
        instances = arr
    }
    func save() {
        try? FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        let data = try? JSONEncoder().encode(instances)
        try? data?.write(to: URL(fileURLWithPath: configPath))
    }
    func nextID() -> Int {
        (instances.map { $0.id }.max() ?? 0) + 1
    }
}

// MARK: - 矢量图标绘制

func color(_ hex: String) -> NSColor {
    var s = hex; if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff)/255,
                   green: CGFloat((v >> 8) & 0xff)/255,
                   blue: CGFloat(v & 0xff)/255, alpha: 1)
}

func hex(_ c: NSColor) -> String {
    guard let rgb = c.usingColorSpace(.sRGB) else { return "#34C759" }
    return String(format: "#%02X%02X%02X",
                  Int(rgb.redComponent*255), Int(rgb.greenComponent*255), Int(rgb.blueComponent*255))
}

func makeVectorIcon(_ colorHex: String, size: CGFloat = 128) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                          xRadius: size*0.20, yRadius: size*0.20)
    color(colorHex).setFill(); bg.fill()

    // 白色微信聊天气泡矢量图形（两枚气泡 + 圆点）
    let s = size
    NSColor.white.setFill()
    // 大气泡
    let b1 = NSBezierPath(roundedRect: NSRect(x: s*0.18, y: s*0.30, width: s*0.56, height: s*0.40),
                          xRadius: s*0.09, yRadius: s*0.09)
    b1.fill()
    // 小气泡
    let b2 = NSBezierPath(roundedRect: NSRect(x: s*0.44, y: s*0.18, width: s*0.38, height: s*0.34),
                          xRadius: s*0.09, yRadius: s*0.09)
    b2.fill()
    // 眼睛
    color(colorHex).setFill()
    for p in [CGPoint(x: s*0.32, y: s*0.49), CGPoint(x: s*0.52, y: s*0.49),
              CGPoint(x: s*0.60, y: s*0.33), CGPoint(x: s*0.72, y: s*0.33)] {
        NSBezierPath(ovalIn: NSRect(x: p.x - s*0.025, y: p.y - s*0.025, width: s*0.05, height: s*0.05)).fill()
    }
    return img
}

func applyIcon(to appPath: String, colorHex: String) {
    let img = makeVectorIcon(colorHex)
    _ = NSWorkspace.shared.setIcon(img, forFile: appPath)
}

// MeChat 主 LOGO（微信风格，绿底白气泡）
func makeLogo(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }
    let s = size
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.22, yRadius: s * 0.22)
    color("#07C160").setFill(); bg.fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.16, y: s * 0.36, width: s * 0.54, height: s * 0.34),
                 xRadius: s * 0.10, yRadius: s * 0.10).fill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.46, y: s * 0.22, width: s * 0.36, height: s * 0.30),
                 xRadius: s * 0.09, yRadius: s * 0.09).fill()
    color("#07C160").setFill()
    for p in [CGPoint(x: s * 0.30, y: s * 0.55), CGPoint(x: s * 0.50, y: s * 0.55),
              CGPoint(x: s * 0.59, y: s * 0.36), CGPoint(x: s * 0.72, y: s * 0.36)] {
        NSBezierPath(ovalIn: NSRect(x: p.x - s * 0.024, y: p.y - s * 0.024,
                                    width: s * 0.048, height: s * 0.048)).fill()
    }
    return img
}

// MARK: - 创建 / 管理逻辑

final class WeChatManager {
    typealias Step = (String, Int) -> Void  // (文案, 进度0-100)

    func createInstance(name: String, colorHex: String, seedSource: String?,
                        onStep: @escaping Step, done: @escaping (Instance?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let id = ConfigStore.shared.nextID()
            let bundleId = "com.tencent.xinWeChat.multi\(id)"
            let dest = copiesDir + "/\(name).app"
            var err: String? = nil

            onStep("复制微信应用", 15)
            if FileManager.default.fileExists(atPath: dest) {
                try? FileManager.default.removeItem(atPath: dest)
            }
            let (o1, c1) = shell(["/bin/cp", "-R", sourcePath, dest])
            if c1 != 0 { err = "复制微信应用失败：\(o1.isEmpty ? "无法读取\(sourcePath)" : o1)" }
            onStep("复制微信应用", 45)

            onStep("准备应用信息", 50)
            if err == nil {
                let plist = dest + "/Contents/Info.plist"
                shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier \(bundleId)", plist])
                shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleName \(name)", plist])
                shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleDisplayName \(name)", plist])
            }
            onStep("准备应用信息", 70)

            onStep("完成系统授权", 72)
            if err == nil {
                let (o2, c2) = shell(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", dest])
                if c2 != 0 { err = "系统授权失败：\(o2.isEmpty ? "临时签名未通过" : o2)" }
            }
            onStep("完成系统授权", 88)

            if err == nil {
                applyIcon(to: dest, colorHex: colorHex)
            }

            // 数据来源
            if err == nil, let src = seedSource {
                onStep("沿用微信数据", 90)
                self.seedData(from: src, toBundle: bundleId)
                onStep("沿用微信数据", 97)
            }

            onStep("完成", 100)
            guard err == nil else { done(nil, err); return }

            let inst = Instance(id: id, name: name, colorHex: colorHex,
                                dataSource: seedSource == nil ? "fresh" : "seed",
                                bundleId: bundleId, appPath: dest)
            ConfigStore.shared.instances.append(inst)
            ConfigStore.shared.save()
            done(inst, nil)
        }
    }

    private func seedData(from originalData: String, toBundle bundleId: String) {
        let newData = expand("~/Library/Containers/\(bundleId)/Data")
        guard FileManager.default.fileExists(atPath: originalData) else { return }
        try? FileManager.default.createDirectory(atPath: newData, withIntermediateDirectories: true)
        _ = shell(["/bin/cp", "-R", originalData + "/.", newData + "/"])
    }

    func launch(_ path: String) {
        if !FileManager.default.fileExists(atPath: path) { return }
        _ = shell(["/usr/bin/open", path])
    }

    func delete(_ inst: Instance) {
        try? FileManager.default.removeItem(atPath: inst.appPath)
        try? FileManager.default.removeItem(atPath: expand("~/Library/Containers/\(inst.bundleId)"))
        ConfigStore.shared.instances.removeAll { $0.id == inst.id }
        ConfigStore.shared.save()
    }
}