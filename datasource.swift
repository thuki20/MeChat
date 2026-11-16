import AppKit
import Foundation

// MARK: - 微信数据源模型

struct WeChatDataSource {
    let bundleId: String
    let isOriginal: Bool
    let dataPath: String
    let sizeBytes: Int64
    let modifiedDate: Date

    var tagString: String { isOriginal ? "原版" : "多开" }

    var friendlyLabel: String {
        if isOriginal { return "微信（原版）" }
        if let known = ConfigStore.shared.instances.first(where: { $0.bundleId == bundleId })?.name {
            return "\(known)（多开）"
        }
        return "多开实例"
    }

    var sizeString: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: sizeBytes)
    }

    var modifiedString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: modifiedDate)
    }
}

// MARK: - 扫描器

final class WeChatDataScanner {
    static let shared = WeChatDataScanner()

    private let cachePath = appSupportDir + "/scan_cache.json"
    private var sizeCache: [String: (size: Int64, mod: TimeInterval)] = [:]

    init() {
        loadCache()
    }

    /// 扫描 ~/Library/Containers 下微信相关容器：仅原版 + 当前有效多开实例。
    /// 已删除实例残留的孤儿容器不再列入（否则用户删掉的实例会反复出现在数据源抽屉）。
    func scan() -> [WeChatDataSource] {
        let containers = expand("~/Library/Containers")
        var out: [WeChatDataSource] = []
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: containers) else { return out }
        // 有效 bundleId = 当前配置里的实例；原版单独放行
        let activeIds = Set(ConfigStore.shared.instances.map { $0.bundleId })
        for id in items {
            let lower = id.lowercased()
            guard lower.contains("wechat") || lower.contains("xinwechat") else { continue }
            // 排除微信的辅助/扩展容器（非数据源）
            if lower.contains("fileproviderextension") || lower.contains("macshare") || lower.contains("helper") { continue }
            // 排除孤儿多开容器：既不是原版，也不在当前实例配置里
            if id != ORIGINAL_ID && !activeIds.contains(id) { continue }
            let dataPath = containers + "/\(id)/Data"
            guard FileManager.default.fileExists(atPath: dataPath) else { continue }
            out.append(make(bundleId: id, dataPath: dataPath))
        }
        sort(&out)
        return out
    }

    /// 由用户手动选择的目录构造数据源
    func makeManual(path: String) -> WeChatDataSource? {
        let resolved = expand(path)
        guard FileManager.default.fileExists(atPath: resolved) else { return nil }
        let ds = make(bundleId: "手动选择", dataPath: resolved, isManual: true)
        return ds
    }

    private func make(bundleId: String, dataPath: String, isManual: Bool = false) -> WeChatDataSource {
        var mod = Date.distantPast
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dataPath),
           let d = attrs[.modificationDate] as? Date {
            mod = d
        }
        return WeChatDataSource(bundleId: bundleId,
                                isOriginal: !isManual && bundleId == ORIGINAL_ID,
                                dataPath: dataPath,
                                sizeBytes: cachedOrComputeSize(dataPath, mod: mod),
                                modifiedDate: mod)
    }

    private func sort(_ arr: inout [WeChatDataSource]) {
        arr.sort { a, b in
            if a.isOriginal != b.isOriginal { return a.isOriginal }
            return a.sizeBytes > b.sizeBytes
        }
    }

    private func dirSize(_ path: String) -> Int64 {
        let (out, code) = shell(["/usr/bin/du", "-sk", path])
        guard code == 0,
              let first = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let kb = Int64(first) else { return 0 }
        return kb * 1024
    }

    // MARK: 大小缓存 —— 目录 mtime 没变就直接用上次算好的大小，避免每次都跑 du 扫整棵大目录树

    private func cachedOrComputeSize(_ path: String, mod: Date) -> Int64 {
        let t = mod.timeIntervalSince1970
        if let hit = sizeCache[path], hit.mod == t {
            return hit.size
        }
        let size = dirSize(path)
        sizeCache[path] = (size, t)
        saveCache()
        return size
    }

    private func loadCache() {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (k, v) in obj {
            guard let arr = v as? [Double], arr.count == 2 else { continue }
            sizeCache[k] = (Int64(arr[0]), arr[1])
        }
    }

    private func saveCache() {
        var obj: [String: [Double]] = [:]
        for (k, v) in sizeCache { obj[k] = [Double(v.size), v.mod] }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: cachePath))
        }
    }
}

// MARK: - 底部抽屉（选择微信数据）

final class DataSourceDrawerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let parent: NSWindow
    private var drawer: NSWindow!
    private let tableView = NSTableView()
    private var okButton: NSButton!
    private var sources: [WeChatDataSource] = []
    private var onDone: ((WeChatDataSource?) -> Void)?
    private var selected: WeChatDataSource?

    private let drawerHeight: CGFloat = 420

    init(parent: NSWindow) {
        self.parent = parent
        super.init()
    }

    func show(completion: @escaping (WeChatDataSource?) -> Void) {
        onDone = completion
        reload()
        let w = parent.frame.width
        let x = parent.frame.minX
        let bottomY = parent.frame.minY

        drawer = NSWindow(contentRect: NSRect(x: x, y: bottomY, width: w, height: drawerHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        drawer.isOpaque = false
        drawer.backgroundColor = .clear
        drawer.hasShadow = true
        drawer.isReleasedWhenClosed = false

        buildUI()
        parent.addChildWindow(drawer, ordered: .above)

        // 抽屉式向上弹出
        drawer.setFrame(NSRect(x: x, y: bottomY, width: w, height: 0), display: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            drawer.animator().setFrame(NSRect(x: x, y: bottomY, width: w, height: drawerHeight), display: true)
        }
    }

    private func reload() {
        sources = WeChatDataScanner.shared.scan()
        tableView.reloadData()
    }

    private func buildUI() {
        let cw = drawer.frame.width
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: cw, height: drawerHeight))
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        root.layer?.masksToBounds = true
        drawer.contentView = root

        let title = NSTextField(labelWithString: "选择要沿用的微信数据")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.frame = NSRect(x: 20, y: drawerHeight - 46, width: 300, height: 26)
        root.addSubview(title)

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 60, width: cw - 28, height: drawerHeight - 116))
        scroll.hasVerticalScroller = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 30
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true

        let cName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        cName.title = "微信数据"; cName.width = 150
        tableView.addTableColumn(cName)
        let cPath = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        cPath.title = "根目录"; cPath.width = 220
        tableView.addTableColumn(cPath)
        let cSize = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        cSize.title = "大小"; cSize.width = 90
        tableView.addTableColumn(cSize)
        let cMod = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mod"))
        cMod.title = "最后修改"; cMod.width = 100
        tableView.addTableColumn(cMod)

        scroll.documentView = tableView
        root.addSubview(scroll)

        let manualBtn = NSButton(title: "手动选择", target: self, action: #selector(manualPressed))
        manualBtn.bezelStyle = .rounded
        manualBtn.frame = NSRect(x: 20, y: 12, width: 100, height: 32)
        root.addSubview(manualBtn)

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: cw - 196, y: 12, width: 80, height: 32)
        root.addSubview(cancelBtn)

        okButton = NSButton(title: "选用此数据", target: self, action: #selector(okPressed))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.isEnabled = false
        okButton.frame = NSRect(x: cw - 108, y: 12, width: 92, height: 32)
        root.addSubview(okButton)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, row < sources.count else { return nil }
        let s = sources[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell?.addSubview(tf)
            cell?.textField = tf
            tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4).isActive = true
            tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor).isActive = true
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell!.trailingAnchor, constant: -4).isActive = true
        }
        let tf = cell!.textField!
        switch col.identifier.rawValue {
        case "name":
            tf.stringValue = "[\(s.tagString)] \(s.friendlyLabel)"
            tf.textColor = s.isOriginal ? .systemBlue : .labelColor
            tf.font = NSFont.systemFont(ofSize: 13, weight: s.isOriginal ? .semibold : .regular)
        case "path":
            tf.stringValue = s.dataPath
            tf.textColor = .secondaryLabelColor
            tf.font = NSFont.systemFont(ofSize: 11)
        case "size":
            tf.stringValue = s.sizeString
            tf.textColor = .secondaryLabelColor
            tf.font = NSFont.systemFont(ofSize: 13)
        default:
            tf.stringValue = s.modifiedString
            tf.textColor = .secondaryLabelColor
            tf.font = NSFont.systemFont(ofSize: 13)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        okButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc private func okPressed() {
        let row = tableView.selectedRow
        guard row >= 0 && row < sources.count else { return }
        selected = sources[row]
        closeDrawer()
    }

    @objc private func cancelPressed() {
        selected = nil
        closeDrawer()
    }

    @objc private func manualPressed() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "请选择微信数据所在的 Data 目录"
        if panel.runModal() == .OK, let url = panel.url,
           let ds = WeChatDataScanner.shared.makeManual(path: url.path) {
            selected = ds
            closeDrawer()
        }
    }

    private func closeDrawer() {
        let r = selected
        selected = nil
        let x = parent.frame.minX
        let bottomY = parent.frame.minY
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            drawer.animator().setFrame(NSRect(x: x, y: bottomY, width: parent.frame.width, height: 0), display: true)
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            self.parent.removeChildWindow(self.drawer)
            self.drawer.orderOut(nil)
            self.onDone?(r)
            self.onDone = nil
        }
    }
}