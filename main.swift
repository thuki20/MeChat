import AppKit
import Foundation

// MARK: - 常量

let presetColors: [String] = ["#07C160", "#0A84FF", "#FF9F0A", "#FF453A",
                              "#BF5AF2", "#64D2FF", "#FF375F", "#8E8E93"]
let skinNames = ["自动", "浅色", "深色"]

// 翻转容器：让列表内容从顶部向下排列（新实例加在下方）
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// 液态玻璃卡片：半透明白 + 顶部内高光 + 柔和投影，自动适配深浅色
final class GlassView: NSView {
    var cornerRadius: CGFloat = 12
    var baseAlpha: CGFloat = 0.55
    var hoverAlpha: CGFloat = 0.92
    var shadowEnabled = false
    private var isHover = false

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateTrackingAreas()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        isHover = true
        refresh(animated: true)
    }
    override func mouseExited(with event: NSEvent) {
        isHover = false
        refresh(animated: true)
    }
    override func viewDidChangeEffectiveAppearance() {
        refresh()
    }

    func refresh(animated: Bool = false) {
        guard let l = layer else { return }
        let dark = isDark
        let a = isHover ? hoverAlpha : baseAlpha
        let bg = NSColor(calibratedWhite: 1, alpha: dark ? a * 0.13 : a).cgColor
        if animated {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = l.backgroundColor
            anim.toValue = bg
            anim.duration = 0.18
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(anim, forKey: "glassHover")
        }
        l.cornerRadius = cornerRadius
        l.backgroundColor = bg
        l.borderColor = NSColor(calibratedWhite: 1, alpha: dark ? 0.16 : 0.7).cgColor
        l.borderWidth = 1
        if shadowEnabled {
            l.shadowColor = (dark ? NSColor.black
                                  : NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.28, alpha: 1)).cgColor
            l.shadowOpacity = dark ? 0.4 : 0.10
            l.shadowRadius = dark ? 14 : 12
            l.shadowOffset = NSSize(width: 0, height: dark ? -3 : -5)
        }
    }
}

// 柔和渐变背景，让半透明玻璃卡片有「层次」可透过，是浅色液态玻璃的关键
final class GradientBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = dark ? NSColor(calibratedWhite: 0.10, alpha: 1)
                       : NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1)
        let bottom = dark ? NSColor(calibratedWhite: 0.14, alpha: 1)
                          : NSColor(calibratedRed: 0.84, green: 0.88, blue: 0.94, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)
    }
    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }
}

// MARK: - 应用代理

final class AppDelegate: NSObject, NSApplicationDelegate,
                          NSTableViewDataSource, NSTableViewDelegate {

    private var window: NSWindow!
    private var rootEffect: NSVisualEffectView!
    private var skinControl: NSSegmentedControl!

    private var nameField: NSTextField!
    private var colorButtons: [NSButton] = []
    private var colorWell: NSColorWell!
    private var dataSeg: NSSegmentedControl!
    private var selectedColor = presetColors[0]

    private var createBtn: NSButton!
    private var dataCardContainer: NSView!
    private var selectedSummaryLabel: NSTextField!
    private var selectedSource: WeChatDataSource?
    private var activeDrawer: DataSourceDrawerController?

    private var listContainer: FlippedView!
    private var instancesHeader: NSTextField!

    private var stepCircles: [NSImageView] = []
    private var stepLabels: [NSTextField] = []
    private var stepDone = [false, false, false]
    private var progressBar: NSProgressIndicator!
    private var progressPercent: NSTextField!
    private var progressDetail: NSTextField!

    private let mgr = WeChatManager()

    // macOS 圆形步骤卡片（待处理 / 进行中 / 完成）
    private enum StepState { case pending, active, done }
    private func makeStepCircle(state: StepState, number: Int) -> NSImage {
        let s: CGFloat = 28
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        defer { img.unlockFocus() }
        let bg: NSColor
        switch state {
        case .pending: bg = NSColor.controlColor
        case .active:  bg = NSColor.controlAccentColor
        case .done:    bg = NSColor.systemGreen
        }
        bg.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: s, height: s)).fill()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13),
                                                    .foregroundColor: NSColor.white,
                                                    .paragraphStyle: para]
        let txt = (state == .done ? "✓" : "\(number)") as NSString
        txt.draw(in: NSRect(x: 0, y: (s - 16) / 2, width: s, height: 16), withAttributes: attrs)
        return img
    }

    private func setStepState(_ i: Int, _ state: StepState) {
        guard i >= 0, i < stepCircles.count else { return }
        stepCircles[i].image = makeStepCircle(state: state, number: i + 1)
        stepLabels[i].textColor = state == .done ? .systemGreen
            : (state == .active ? .labelColor : .secondaryLabelColor)
        if state == .done { pop(stepCircles[i]) }
    }

    // 弹出动画：完成时给卡片加一个“砰”的动效
    private func pop(_ v: NSImageView) {
        v.wantsLayer = true
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 0.5
        a.toValue = 1.0
        a.duration = 0.28
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        v.layer?.add(a, forKey: "pop")
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildUI()
        refreshList()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: 界面搭建

    private func buildUI() {
        let size = NSSize(width: 560, height: 740)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "MeChat"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 540, height: 700)
        window.maxSize = NSSize(width: 700, height: 1000)
        window.center()

        rootEffect = NSVisualEffectView(frame: window.contentView!.bounds)
        rootEffect.material = .underWindowBackground
        rootEffect.blendingMode = .behindWindow
        rootEffect.state = .active
        rootEffect.autoresizingMask = [.width, .height]
        window.contentView = rootEffect

        // 液态玻璃需要一块有层次的渐变底，玻璃卡片才能透出深浅
        let gradient = GradientBackground(frame: window.contentView!.bounds)
        gradient.autoresizingMask = [.width, .height]
        rootEffect.addSubview(gradient)

        let base = FlippedView(frame: window.contentView!.bounds)
        base.autoresizingMask = [.width, .height]
        rootEffect.addSubview(base)

        let w = size.width
        var y: CGFloat = 32

        // 标题（LOGO + MeChat），顶部让开红绿灯按钮
        let logo = NSImageView(image: makeLogo(size: 28))
        logo.frame = NSRect(x: 22, y: y, width: 28, height: 28)
        base.addSubview(logo)
        let title = NSTextField(labelWithString: "MeChat")
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        title.frame = NSRect(x: 58, y: y, width: 240, height: 28)
        base.addSubview(title)

        skinControl = NSSegmentedControl(labels: skinNames, trackingMode: .selectOne,
                                         target: self, action: #selector(skinChanged))
        skinControl.selectedSegment = 0
        skinControl.frame = NSRect(x: 360, y: y + 1, width: 178, height: 26)
        base.addSubview(skinControl)
        y += 44

        base.addSubview(line(y: y))
        y += 26

        sectionHeader("创建新微信", in: base, y: &y)

        _ = field("名称", in: base, at: y)
        nameField = NSTextField(string: defaultName())
        nameField.frame = NSRect(x: 130, y: y, width: w - 152, height: 26)
        nameField.placeholderString = "如：工作微信"
        base.addSubview(nameField)
        y += 42

        _ = field("图标颜色", in: base, at: y)
        var cx: CGFloat = 130
        for hx in presetColors {
            let b = colorSwatchButton(hx)
            b.frame = NSRect(x: cx, y: y, width: 30, height: 30)
            b.target = self; b.action = #selector(colorPressed(_:))
            colorButtons.append(b)
            base.addSubview(b)
            cx += 46
        }
        colorWell = NSColorWell(frame: NSRect(x: cx, y: y + 3, width: 30, height: 24))
        colorWell.color = color(selectedColor)
        colorWell.target = self; colorWell.action = #selector(colorWellChanged)
        base.addSubview(colorWell)
        y += 44

        _ = field("数据来源", in: base, at: y)
        dataSeg = NSSegmentedControl(labels: ["全新数据", "沿用已有微信数据"],
                                     trackingMode: .selectOne, target: self, action: #selector(dataSourceChanged))
        dataSeg.selectedSegment = 0
        dataSeg.frame = NSRect(x: 130, y: y, width: w - 152, height: 28)
        base.addSubview(dataSeg)
        y += 48

        // 数据来源卡片（紧凑卡片）
        dataCardContainer = NSView(frame: NSRect(x: 22, y: y, width: w - 44, height: 76))
        base.addSubview(dataCardContainer)
        y += 76

        // 卡片下方：已选数据的大小 / 最后修改
        selectedSummaryLabel = NSTextField(labelWithString: "")
        selectedSummaryLabel.font = NSFont.systemFont(ofSize: 12)
        selectedSummaryLabel.textColor = .secondaryLabelColor
        selectedSummaryLabel.frame = NSRect(x: 22, y: y, width: w - 44, height: 20)
        base.addSubview(selectedSummaryLabel)
        y += 32

        createBtn = NSButton(title: "开始创建多开微信", target: self, action: #selector(createPressed))
        createBtn.bezelStyle = .rounded
        createBtn.keyEquivalent = "\r"
        createBtn.frame = NSRect(x: 22, y: y, width: w - 44, height: 34)
        base.addSubview(createBtn)
        y += 44

        base.addSubview(line(y: y))
        y += 26

        instancesHeader = makeHeader("我的微信（0）")
        instancesHeader.frame = NSRect(x: 22, y: y, width: 400, height: 22)
        base.addSubview(instancesHeader)
        y += 32

        let hint = NSTextField(labelWithString: "每个实例都是独立 App，可点「访达」定位后拖到 Dock 或应用程序单独打开。")
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 22, y: y, width: w - 44, height: 18)
        base.addSubview(hint)
        y += 24

        // 我的微信列表（可伸缩）
        let listHeight = size.height - y - 124
        let scroll = NSScrollView(frame: NSRect(x: 22, y: y, width: w - 44, height: max(listHeight, 40)))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        listContainer = FlippedView(frame: NSRect(x: 0, y: 0, width: w - 44, height: 100))
        scroll.documentView = listContainer
        base.addSubview(scroll)

        // 创建进度（钉在底部，横向三步骤，只占一行）
        let prog = FlippedView(frame: NSRect(x: 0, y: size.height - 112, width: w, height: 112))
        prog.autoresizingMask = [.width, .maxYMargin]
        base.addSubview(prog)
        buildProgressSection(in: prog, width: w)

        refreshDataSourceCard()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildProgressSection(in prog: FlippedView, width w: CGFloat) {
        // 底层卡片（与「我的微信」实例行同款），文字浮于卡片之上更有层次
        let card = GlassView(frame: NSRect(x: 16, y: 2, width: w - 32, height: 108))
        card.cornerRadius = 14
        card.baseAlpha = 0.85
        card.hoverAlpha = 0.85
        card.refresh()
        prog.addSubview(card)

        // 卡片标题
        let ph = makeHeader("创建进度")
        ph.frame = NSRect(x: 40, y: 8, width: 200, height: 20)
        prog.addSubview(ph)

        // 三个步骤横向排成一行，节省垂直空间
        let phases = ["复制微信应用", "准备应用信息", "完成系统授权"]
        let stepY: CGFloat = 32
        let stepWidth: CGFloat = 176
        for (i, ph) in phases.enumerated() {
            let x = 40 + CGFloat(i) * stepWidth
            let circle = NSImageView(image: makeStepCircle(state: .pending, number: i + 1))
            circle.frame = NSRect(x: x, y: stepY, width: 28, height: 28)
            prog.addSubview(circle)
            stepCircles.append(circle)

            let l = NSTextField(labelWithString: ph)
            l.textColor = .secondaryLabelColor
            l.font = NSFont.systemFont(ofSize: 13)
            l.frame = NSRect(x: x + 34, y: stepY + 3, width: stepWidth - 34, height: 22)
            prog.addSubview(l)
            stepLabels.append(l)
        }

        progressBar = NSProgressIndicator(frame: NSRect(x: 40, y: 66, width: w - 160, height: 12))
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        prog.addSubview(progressBar)

        progressPercent = NSTextField(labelWithString: "0%")
        progressPercent.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        progressPercent.textColor = .controlAccentColor
        progressPercent.alignment = .right
        progressPercent.frame = NSRect(x: w - 128, y: 66, width: 74, height: 14)
        prog.addSubview(progressPercent)

        progressDetail = NSTextField(labelWithString: "")
        progressDetail.font = NSFont.systemFont(ofSize: 12)
        progressDetail.textColor = .secondaryLabelColor
        progressDetail.frame = NSRect(x: 40, y: 82, width: w - 80, height: 18)
        prog.addSubview(progressDetail)
    }

    private func line(y: CGFloat) -> NSBox {
        let l = NSBox()
        l.boxType = .separator
        l.frame = NSRect(x: 22, y: y, width: window.frame.width - 44, height: 1)
        return l
    }

    private func sectionHeader(_ s: String, in base: NSView, y: inout CGFloat) {
        let l = makeHeader(s)
        l.frame = NSRect(x: 22, y: y, width: 400, height: 22)
        base.addSubview(l)
        y += 32
    }

    private func makeHeader(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    @discardableResult
    private func field(_ s: String, in base: NSView, at y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 14)
        l.frame = NSRect(x: 22, y: y, width: 100, height: 22)
        base.addSubview(l)
        return l
    }

    private func colorSwatchButton(_ hx: String) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.isBordered = false
        let img = NSImage(size: NSSize(width: 22, height: 22))
        img.lockFocus()
        color(hx).setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 18, height: 18)).fill()
        img.unlockFocus()
        b.image = img
        b.imagePosition = .imageOnly
        return b
    }

    private func defaultName() -> String {
        "微信 \(ConfigStore.shared.nextID())"
    }

    // MARK: 动作

    @objc private func skinChanged() {
        let idx = skinControl.selectedSegment
        switch idx {
        case 1: window.appearance = NSAppearance(named: .aqua)
        case 2: window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = nil
        }
    }

    @objc private func colorPressed(_ sender: NSButton) {
        for b in colorButtons { b.contentTintColor = b === sender ? .controlAccentColor : nil }
        if let idx = colorButtons.firstIndex(of: sender) {
            selectedColor = presetColors[idx]
            colorWell.color = color(selectedColor)
        }
    }

    @objc private func colorWellChanged() {
        selectedColor = hex(colorWell.color)
        for b in colorButtons { b.contentTintColor = nil }
    }

    @objc private func dataSourceChanged() {
        refreshDataSourceCard()
    }

    private func refreshDataSourceCard() {
        for v in dataCardContainer.subviews { v.removeFromSuperview() }
        selectedSource = nil
        if dataSeg.selectedSegment == 0 {
            buildFreshCard()
            createBtn.isEnabled = true
            selectedSummaryLabel.stringValue = ""
        } else {
            buildReuseCard()
            createBtn.isEnabled = false
            selectedSummaryLabel.stringValue = "请点击「自动查找」扫描可沿用的微信数据。"
        }
    }

    private func cardBox() -> GlassView {
        let card = GlassView(frame: dataCardContainer.bounds)
        card.baseAlpha = 0.85
        card.hoverAlpha = 0.85
        card.refresh()
        return card
    }

    // 让一个视图呈现为 macOS 卡片：圆角 + 浅色底 + 细边框

    private func buildFreshCard() {
        let card = cardBox()
        dataCardContainer.addSubview(card)

        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles",
                                              accessibilityDescription: nil) ?? makeLogo(size: 28))
        icon.contentTintColor = .systemGreen
        icon.frame = NSRect(x: 20, y: 24, width: 30, height: 30)
        card.addSubview(icon)

        let t = NSTextField(wrappingLabelWithString: "将创建一个全新的微信，不会读取你现有微信的聊天记录。")
        t.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        t.frame = NSRect(x: 60, y: 20, width: 440, height: 40)
        t.maximumNumberOfLines = 2
        card.addSubview(t)
    }

    private func buildReuseCard() {
        let card = cardBox()
        dataCardContainer.addSubview(card)

        let title = NSTextField(labelWithString: "选择要沿用的微信数据")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 16, y: 40, width: 220, height: 20)
        card.addSubview(title)

        let hint = NSTextField(labelWithString: "可沿用你电脑上已有的微信数据，聊天记录直接可用。")
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 18, width: 260, height: 18)
        card.addSubview(hint)

        let scanBtn = NSButton(title: "自动查找", target: self, action: #selector(openDrawerPressed))
        scanBtn.bezelStyle = .rounded
        scanBtn.keyEquivalent = "\r"
        scanBtn.frame = NSRect(x: 400, y: 24, width: 100, height: 30)
        card.addSubview(scanBtn)
    }

    @objc private func openDrawerPressed() {
        let drawer = DataSourceDrawerController(parent: window)
        activeDrawer = drawer
        drawer.show { [weak self] src in
            guard let self = self else { return }
            self.activeDrawer = nil
            if let s = src {
                self.selectedSource = s
                self.createBtn.isEnabled = true
                self.updateSummary(s)
            }
        }
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
            selectedSource = ds
            createBtn.isEnabled = true
            updateSummary(ds)
        }
    }

    private func updateSummary(_ s: WeChatDataSource) {
        selectedSummaryLabel.stringValue = "已选数据：\(s.friendlyLabel) · 大小 \(s.sizeString) · 最后修改 \(s.modifiedString)"
    }

    @objc private func createPressed() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let finalName = name.isEmpty ? defaultName() : name

        var seedSource: String? = nil
        if dataSeg.selectedSegment == 1 {
            guard let src = selectedSource else {
                let a = NSAlert()
                a.messageText = "请先选择一个微信数据来源"
                a.informativeText = "在「沿用已有微信数据」卡片中选择一份数据，或用「手动选择」指定，再开始创建。"
                a.runModal()
                return
            }
            seedSource = src.dataPath
        }

        resetProgress()
        mgr.createInstance(name: finalName, colorHex: selectedColor, seedSource: seedSource,
                           onStep: { [weak self] text, p in
            DispatchQueue.main.async { self?.setProgress(text, p) }
        }, done: { [weak self] inst, err in
            DispatchQueue.main.async {
                if let e = err { self?.logDetail("创建失败：\(e)") }
                else if inst != nil { self?.logDetail("创建完成：\(finalName)") }
                else { self?.logDetail("创建失败：未知错误") }
                self?.refreshList()
            }
        })
    }

    private func resetProgress() {
        let phases = ["复制微信应用", "准备应用信息", "完成系统授权"]
        stepDone = [false, false, false]
        for i in stepCircles.indices {
            stepCircles[i].image = makeStepCircle(state: i == 0 ? .active : .pending, number: i + 1)
            stepLabels[i].stringValue = phases[i]
            stepLabels[i].textColor = i == 0 ? .labelColor : .secondaryLabelColor
        }
        progressBar.doubleValue = 0
        progressPercent.stringValue = "0%"
        progressDetail.stringValue = "准备创建…"
    }

    private func setProgress(_ text: String, _ p: Int) {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.25
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progressBar.animator().doubleValue = Double(p)
        }
        progressPercent.stringValue = "\(p)%"
        progressDetail.stringValue = text
        let phases = ["复制微信应用", "准备应用信息", "完成系统授权"]
        for (i, ph) in phases.enumerated() {
            if text.hasPrefix(ph), i < stepCircles.count {
                stepDone[i] = true
                setStepState(i, .done)
            }
        }
        let activeIdx = stepDone.firstIndex(of: false)
        for i in stepCircles.indices {
            if !stepDone[i] { setStepState(i, i == activeIdx ? .active : .pending) }
        }
        if text == "沿用微信数据" {
            logDetail("正在复制所选微信数据到新实例…")
        }
    }

    private func logDetail(_ s: String) {
        progressDetail.stringValue = s
    }

    private func refreshList() {
        instancesHeader.stringValue = "我的微信（\(ConfigStore.shared.instances.count)）"
        for v in listContainer.subviews { v.removeFromSuperview() }
        var y: CGFloat = 6
        if ConfigStore.shared.instances.isEmpty {
            let l = NSTextField(labelWithString: "还没有多开实例，先在上面创建一个吧。")
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 4, y: y, width: 400, height: 22)
            listContainer.addSubview(l)
            y += 22
        } else {
            for inst in ConfigStore.shared.instances {
                let row = instanceRow(inst)
                row.frame = NSRect(x: 4, y: y, width: 496, height: 40)
                listContainer.addSubview(row)
                y += 50
            }
        }
        listContainer.frame = NSRect(x: 0, y: 0, width: 512, height: max(y + 6, 100))
    }

    private func instanceRow(_ inst: Instance) -> NSView {
        let row = GlassView(frame: NSRect(x: 0, y: 0, width: 496, height: 40))
        row.cornerRadius = 10
        row.baseAlpha = 0.5
        row.hoverAlpha = 0.9
        row.refresh()

        let iconView = NSImageView(image: makeVectorIcon(inst.colorHex, size: 28))
        iconView.frame = NSRect(x: 8, y: 6, width: 28, height: 28)
        row.addSubview(iconView)

        let name = NSTextField(labelWithString: inst.name)
        name.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        name.frame = NSRect(x: 44, y: 10, width: 110, height: 22)
        row.addSubview(name)

        let tag = NSTextField(labelWithString: inst.dataSource == "seed" ? "沿用数据" : "全新数据")
        tag.font = NSFont.systemFont(ofSize: 11)
        tag.textColor = .secondaryLabelColor
        tag.frame = NSRect(x: 158, y: 13, width: 76, height: 16)
        row.addSubview(tag)

        var bx: CGFloat = 246
        let btns: [(String, Selector)] = [("打开", #selector(openPressed(_:))),
                                          ("改名", #selector(renamePressed(_:))),
                                          ("换色", #selector(colorChangePressed(_:))),
                                          ("删除", #selector(deletePressed(_:))),
                                          ("访达", #selector(revealPressed(_:)))]
        for (t, sel) in btns {
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = inst.id
            b.frame = NSRect(x: bx, y: 4, width: 44, height: 28)
            row.addSubview(b)
            bx += 47
        }
        return row
    }

    private func instance(_ id: Int) -> Instance? {
        ConfigStore.shared.instances.first { $0.id == id }
    }

    @objc private func openPressed(_ s: NSButton) {
        guard let i = instance(s.tag) else { return }
        mgr.launch(i.appPath)
    }

    @objc private func revealPressed(_ s: NSButton) {
        guard let i = instance(s.tag) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.appPath)])
    }

    @objc private func renamePressed(_ s: NSButton) {
        guard let i = instance(s.tag) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名实例"
        alert.informativeText = "输入新的名称："
        let tf = NSTextField(string: i.name)
        tf.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = tf
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = tf.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty, newName != i.name else { return }
            // 重命名 app 目录
            let newPath = copiesDir + "/\(newName).app"
            try? FileManager.default.moveItem(atPath: i.appPath, toPath: newPath)
            let plist = newPath + "/Contents/Info.plist"
            shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleName \(newName)", plist])
            shell(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleDisplayName \(newName)", plist])
            shell(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", newPath])
            applyIcon(to: newPath, colorHex: i.colorHex)
            if let idx = ConfigStore.shared.instances.firstIndex(where: { $0.id == i.id }) {
                ConfigStore.shared.instances[idx].name = newName
                ConfigStore.shared.instances[idx].appPath = newPath
            }
            ConfigStore.shared.save()
            refreshList()
        }
    }

    @objc private func colorChangePressed(_ s: NSButton) {
        guard let i = instance(s.tag) else { return }
        let c = NSColorPanel.shared
        c.color = color(i.colorHex)
        c.setTarget(self)
        c.setAction(#selector(colorPanelDone(_:)))
        c.makeKeyAndOrderFront(nil)
        pendingColorInstance = i
    }
    private var pendingColorInstance: Instance?

    @objc private func colorPanelDone(_ sender: NSColorPanel) {
        guard let i = pendingColorInstance else { return }
        let newHex = hex(sender.color)
        applyIcon(to: i.appPath, colorHex: newHex)
        if let idx = ConfigStore.shared.instances.firstIndex(where: { $0.id == i.id }) {
            ConfigStore.shared.instances[idx].colorHex = newHex
        }
        ConfigStore.shared.save()
        refreshList()
    }

    @objc private func deletePressed(_ s: NSButton) {
        guard let i = instance(s.tag) else { return }
        let alert = NSAlert()
        alert.messageText = "删除实例“\(i.name)”？"
        alert.informativeText = "将删除该微信的独立副本与数据容器（原版微信不受影响）。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            mgr.delete(i)
            refreshList()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()