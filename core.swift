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

    // Launch Services / Dock 会缓存 app 图标，只 setIcon 不够：
    // 必须重新注册 bundle 并重启 Dock，已有程序坞图标才会跟着换色。
    let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    shell(["/usr/bin/touch", appPath])
    shell([lsregister, "-f", appPath])

    let link = expand("~/Applications/\((appPath as NSString).lastPathComponent)")
    if FileManager.default.fileExists(atPath: link) {
        // 启动台/程序坞若固定的是 ~/Applications 链接，链接自身的图标也要刷
        _ = NSWorkspace.shared.setIcon(img, forFile: link)
        shell(["/usr/bin/touch", "-h", link])
        shell([lsregister, "-f", link])
    }
    shell(["/usr/bin/killall", "Dock"])
}

/// 同步 app 的显示名：Info.plist + 所有 *.lproj/InfoPlist.strings。
/// 本地化 strings 优先级高于 plist，漏改会导致启动台/访达仍显示旧名（如"微信"）。
/// 注意：这些 plist 文件带 xattr，重签前必须清 xattr 否则报 detritus not allowed。
func updateDisplayNames(_ appPath: String, to name: String) {
    let fm = FileManager.default
    let plist = appPath + "/Contents/Info.plist"
    shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleName \(name)", plist])
    shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleDisplayName \(name)", plist])
    let res = appPath + "/Contents/Resources"
    if let items = try? fm.contentsOfDirectory(atPath: res) {
        for d in items where d.hasSuffix(".lproj") {
            let f = res + "/" + d + "/InfoPlist.strings"
            guard fm.fileExists(atPath: f) else { continue }
            // 微信的 InfoPlist.strings 是 XML plist 格式，用 PlistBuddy 改最稳
            shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleDisplayName \(name)", f])
            shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleName \(name)", f])
        }
    }
    // 清 xattr + 重签，否则改过的 bundle 会因 detritus 拒绝签名/启动
    shell(["/usr/bin/xattr", "-cr", appPath])
    shell(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", appPath])
}

/// 在 ~/Applications 维护指向实例副本的符号链接，让 Launchpad/应用程序收录多开实例。
func syncLauncherLink(instanceName: String, appPath: String, remove: Bool = false) {
    let fm = FileManager.default
    let appsDir = expand("~/Applications")
    try? fm.createDirectory(atPath: appsDir, withIntermediateDirectories: true)
    let link = appsDir + "/\(instanceName).app"
    if remove {
        if fm.fileExists(atPath: link) { try? fm.removeItem(atPath: link) }
    } else {
        // 若已有同名链接指向别处，先删再建（改名场景）
        if fm.fileExists(atPath: link) { try? fm.removeItem(atPath: link) }
        try? fm.createSymbolicLink(atPath: link, withDestinationPath: appPath)
    }
    // 通知 Launch Services 刷新单个 app（扫整个 ~/Applications 会报 -10811 权限错）
    let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    shell([lsregister, "-f", link])
}

/// 删除实例时清理 ~/Applications 下的启动台链接
func removeLauncherLink(instanceName: String) {
    syncLauncherLink(instanceName: "", appPath: "", remove: true)
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
                // 同步 plist + 所有 lproj 本地化显示名，并清 xattr、重签
                updateDisplayNames(dest, to: name)
            }
            onStep("准备应用信息", 70)

            onStep("完成系统授权", 72)
            // updateDisplayNames 已完成清 xattr 与重签，这里复核签名有效性
            if err == nil {
                let (o2, c2) = shell(["/usr/bin/codesign", "-v", dest])
                if c2 != 0 { err = "系统授权失败：\(o2.isEmpty ? "临时签名未通过" : o2)" }
            }
            onStep("完成系统授权", 88)

            if err == nil {
                applyIcon(to: dest, colorHex: colorHex)
                // 在 ~/Applications 建启动台链接
                syncLauncherLink(instanceName: name, appPath: dest)
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

    /// 删除实例：彻底清理应用副本与数据容器，返回删除失败项（不静默吞错）。
    /// 兼容老版本把副本放在配置根目录的情况；容器被占用时如实上报，由 UI 提示用户。
    @discardableResult
    func delete(_ inst: Instance) -> (removed: [String], failed: [String]) {
        var removed: [String] = []
        var failed: [String] = []
        let name = (inst.appPath as NSString).lastPathComponent
        // 副本可能在 实例/ 子目录（现行）或配置根目录（老版本），都尝试清理
        let appPaths = [inst.appPath, copiesDir + "/" + name, appSupportDir + "/" + name]
        var seen = Set<String>()
        for p in appPaths where !seen.contains(p) {
            seen.insert(p)
            guard FileManager.default.fileExists(atPath: p) else { continue }
            do {
                try FileManager.default.removeItem(atPath: p)
                removed.append("应用副本 \(name)")
            } catch {
                failed.append("应用副本 \(p)：\(error.localizedDescription)")
            }
        }
        // 数据容器：删除失败通常是微信仍在运行，必须让用户知道
        let container = expand("~/Library/Containers/\(inst.bundleId)")
        if FileManager.default.fileExists(atPath: container) {
            do {
                try FileManager.default.removeItem(atPath: container)
                removed.append("数据容器 \(inst.bundleId)")
            } catch {
                failed.append("数据容器 \(inst.bundleId)：\(error.localizedDescription)（请先退出该微信实例）")
            }
        }
        // 清理 ~/Applications 下的启动台链接
        removeLauncherLink(instanceName: inst.name)
        ConfigStore.shared.instances.removeAll { $0.id == inst.id }
        ConfigStore.shared.save()
        return (removed, failed)
    }
}