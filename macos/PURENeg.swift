import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

private let appTitle = "PURE Neg"

private func makeIcon(_ size: CGFloat = 256) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        StudioStyle.charcoal.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.08, dy: size * 0.08), xRadius: size * 0.20, yRadius: size * 0.20).fill()
        let film = NSRect(x: size * 0.21, y: size * 0.28, width: size * 0.58, height: size * 0.44)
        StudioStyle.amber.setFill()
        NSBezierPath(roundedRect: film, xRadius: size * 0.03, yRadius: size * 0.03).fill()
        let scan = NSRect(x: size * 0.56, y: size * 0.22, width: size * 0.027, height: size * 0.56)
        StudioStyle.laser.setFill()
        NSBezierPath(roundedRect: scan, xRadius: scan.width / 2, yRadius: scan.width / 2).fill()
        return true
    }
}

enum StudioStyle {
    static let charcoal = rgb(0x141517)
    static let amber = rgb(0xF0A055)
    static let laser = rgb(0xFF3D24)
    static let light = rgb(0xF2EDE4)
    static let secondaryText = NSColor(white: 0.77, alpha: 1)
    static let photoWell = charcoal

    static let artwork = loadArtwork("png") ?? loadArtwork("icns") ?? makeIcon()
    static let appIcon = loadArtwork("icns") ?? artwork
    static let wordmarkArtwork = loadArtwork("png", named: "PURENeg-wordmark")
    static let launchArtwork = loadArtwork("png", named: "PURENeg-launch")

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private static func loadArtwork(_ type: String, named name: String = "PURENeg") -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: type) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func wordmark(width: CGFloat, maxHeight: CGFloat, fallbackSize: CGFloat) -> NSView {
        if let artwork = wordmarkArtwork, artwork.size.width > 0, artwork.size.height > 0 {
            let height = min(maxHeight, width * artwork.size.height / artwork.size.width)
            let view = NSImageView(image: artwork)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityElement(true)
            view.setAccessibilityLabel(appTitle)
            view.widthAnchor.constraint(equalToConstant: height * artwork.size.width / artwork.size.height).isActive = true
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
            return view
        }
        let label = NSTextField(labelWithString: appTitle)
        label.font = .systemFont(ofSize: fallbackSize, weight: .semibold)
        label.textColor = amber
        return label
    }

    static func installBackdrop(in window: NSWindow, root: NSView) {
        window.isOpaque = false
        window.backgroundColor = .clear
        // Only the window chrome samples the desktop and other windows.
        let backdrop = DesktopBackdrop(frame: .zero)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        // Keep white text readable over light wallpapers without adding a color cast.
        let contrastVeil = NSView()
        contrastVeil.wantsLayer = true
        contrastVeil.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.26).cgColor
        embed(contrastVeil, in: backdrop, horizontal: 0, vertical: 0)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    static func expandWorkspaceWindow(_ window: NSWindow, from source: NSWindow) {
        guard let screen = source.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: false)
    }

    static func section(_ number: String, _ title: String, size: CGFloat = 13) -> NSStackView {
        let index = NSTextField(labelWithString: number)
        index.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        index.textColor = secondaryText
        index.setAccessibilityElement(false)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: size, weight: .semibold)
        name.textColor = light
        let header = NSStackView(views: [index, name])
        header.alignment = .firstBaseline
        header.spacing = 8
        return header
    }

    static func actionControl(_ button: NSButton) -> NSView {
        button.isBordered = false
        button.focusRingType = .exterior
        let control = glassControl(button, horizontal: 12, vertical: 4)
        if let primary = button as? PrimaryActionButton {
            primary.updateTreatment = { [weak control, weak primary] enabled in
                let tint = enabled ? amber : nil
                primary?.contentTintColor = enabled ? charcoal : nil
                #if compiler(>=6.2)
                if #available(macOS 26.0, *), let glass = control as? CapsuleGlassEffectView {
                    glass.tintColor = tint
                    return
                }
                #endif
                (control as? GlassPanel)?.setControlTint(tint)
            }
            primary.updateTreatment?(primary.isEnabled)
        }
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return control
    }

    fileprivate static func segmentedControl(_ control: StudioSegments) -> NSView {
        glassControl(control, horizontal: 2, vertical: 2)
    }

    static func checkboxControl(_ checkbox: NSButton) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { checkbox.tintProminence = .none }
        #endif
        return glassControl(checkbox)
    }

    static func embed(_ view: NSView, in host: NSView, horizontal: CGFloat, vertical: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if view.superview == nil { host.addSubview(view) }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: horizontal),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -horizontal),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: vertical),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -vertical)
        ])
    }

    static func glassControl(_ control: NSView, horizontal: CGFloat = 8, vertical: CGFloat = 4) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = CapsuleGlassEffectView()
            glass.style = .clear
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            #endif
            let content = NSView()
            glass.contentView = content
            embed(content, in: glass, horizontal: 0, vertical: 0)
            embed(control, in: content, horizontal: horizontal, vertical: vertical)
            return glass
        }
        #endif
        let panel = GlassPanel(material: .popover, capsule: true)
        panel.place(control, horizontal: horizontal, vertical: vertical)
        return panel
    }
}

private final class StudioSegments: NSControl {
    private var choices: [SegmentButton] = []
    var selectedSegment = 0 { didSet { updateSelection() } }

    init(labels: [String]) {
        super.init(frame: .zero)
        choices = labels.enumerated().map { index, label in
            let button = SegmentButton(title: label, target: self, action: #selector(select(_:)))
            button.tag = index
            button.isBordered = false
            button.setButtonType(.onOff)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(label)
            button.wantsLayer = true
            button.moveSelection = { [weak self] delta in self?.selectAdjacent(from: index, delta: delta) }
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: button.intrinsicContentSize.width + 16).isActive = true
            button.heightAnchor.constraint(equalToConstant: 21).isActive = true
            return button
        }
        let row = NSStackView(views: choices)
        row.distribution = .fillEqually
        row.spacing = 2
        StudioStyle.embed(row, in: self, horizontal: 0, vertical: 0)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        updateSelection()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { updateSelection() } }
    override func accessibilityChildren() -> [Any]? { choices }

    func setToolTip(_ tip: String, forSegment index: Int) { choices[index].toolTip = tip }

    private func updateSelection() {
        for (index, button) in choices.enumerated() {
            let selected = index == selectedSegment
            button.isEnabled = isEnabled
            button.state = selected ? .on : .off
            button.contentTintColor = selected && isEnabled ? StudioStyle.amber : nil
            button.layer?.backgroundColor = selected && isEnabled ? StudioStyle.amber.withAlphaComponent(0.14).cgColor : nil
        }
    }

    @objc private func select(_ sender: SegmentButton) {
        selectedSegment = sender.tag
        _ = sendAction(action, to: target)
    }

    private func selectAdjacent(from index: Int, delta: Int) {
        guard isEnabled, !choices.isEmpty else { return }
        let next = choices[(index + delta + choices.count) % choices.count]
        window?.makeFirstResponder(next)
        select(next)
    }

    private final class SegmentButton: NSButton {
        var moveSelection: ((Int) -> Void)?

        override func accessibilityChildren() -> [Any]? { [] }
        override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            performClick(nil)
            return true
        }

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.height / 2
        }

        override func keyDown(with event: NSEvent) {
            switch event.specialKey {
            case .leftArrow: moveSelection?(-1)
            case .rightArrow: moveSelection?(1)
            default: super.keyDown(with: event)
            }
        }
    }
}

final class PrimaryActionButton: NSButton {
    var updateTreatment: ((Bool) -> Void)?

    override var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled { updateTreatment?(isEnabled) }
        }
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private final class CapsuleGlassEffectView: NSGlassEffectView {
    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        if cornerRadius != radius { cornerRadius = radius }
    }
}
#endif

private final class StartupWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class StartupArtworkView: NSView {
    private let artwork: NSImage

    // The supplied artwork has a thin white frame outside the graphite card.
    private static let crop = NSRect(x: 22.0 / 2974, y: 26.0 / 1800, width: 2925.0 / 2974, height: 1750.0 / 1800)
    static let aspectRatio: CGFloat = 2925.0 / 1750

    init(frame: NSRect, artwork: NSImage) {
        self.artwork = artwork
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(appTitle)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let crop = Self.crop
        let source = NSRect(x: crop.minX * artwork.size.width, y: crop.minY * artwork.size.height,
                            width: crop.width * artwork.size.width, height: crop.height * artwork.size.height)
        NSBezierPath(roundedRect: bounds, xRadius: 22, yRadius: 22).addClip()
        artwork.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high])
    }
}

private final class DesktopBackdrop: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class GlassPanel: NSVisualEffectView {
    private let capsule: Bool
    private var controlTint: NSView?

    init(material: NSVisualEffectView.Material = .hudWindow, radius: CGFloat = 16, capsule: Bool = false) {
        self.capsule = capsule
        super.init(frame: .zero)
        self.material = material
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        let contrast: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.32 : 0.14
        layer?.borderColor = NSColor.white.withAlphaComponent(contrast).cgColor
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if capsule { layer?.cornerRadius = bounds.height / 2 }
    }

    func place(_ view: NSView, horizontal: CGFloat = 16, vertical: CGFloat = 14) {
        StudioStyle.embed(view, in: self, horizontal: horizontal, vertical: vertical)
    }

    func setControlTint(_ color: NSColor?) {
        guard let color else {
            controlTint?.removeFromSuperview()
            controlTint = nil
            return
        }
        let tint = controlTint ?? NSView()
        if controlTint == nil {
            addSubview(tint, positioned: .below, relativeTo: nil)
            tint.wantsLayer = true
            StudioStyle.embed(tint, in: self, horizontal: 0, vertical: 0)
            controlTint = tint
        }
        tint.layer?.backgroundColor = color.cgColor
    }
}

final class LaserProgressBar: NSView {
    var doubleValue: Double = 0 {
        didSet {
            guard oldValue != doubleValue else { return }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }
    override func accessibilityLabel() -> String? { L10n.text("处理进度") }
    override func accessibilityValue() -> Any? { doubleValue }
    override func accessibilityMinValue() -> Any? { 0.0 }
    override func accessibilityMaxValue() -> Any? { 1.0 }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: bounds.midY - 2, width: bounds.width, height: 4)
        let outline = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(0.2).setFill()
        outline.fill()
        let width = track.width * doubleValue
        if width > 0 {
            StudioStyle.laser.setFill()
            let rect = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
            let radius = min(2, width / 2)
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }
}

private enum DetectionKind: String, CaseIterable {
    case dust, scratches, fibers

    var label: String {
        switch self {
        case .dust: return L10n.text("灰尘")
        case .scratches: return L10n.text("划痕")
        case .fibers: return L10n.text("毛发／纤维")
        }
    }
}

private enum ReviewExportFormat: String, CaseIterable {
    case tiff, jpeg, png

    var label: String { rawValue.uppercased() }
}

private struct ReviewSession {
    let path: String
    let sourcePath: String
    let sourceName: String
    let cleanedPath: String
    let maskPath: String
    let width: Int
    let height: Int
    let regions: [DustRegion]
    let detectionKinds: [DetectionKind]
    let context: String
    let outputRoot: String?

    init(event: [String: Any]) throws {
        guard let path = event["reviewPath"] as? String,
              let review = event["review"] as? [String: Any],
              let source = review["sourcePath"] as? String,
              let cleaned = review["cleanedPath"] as? String,
              let mask = review["maskPath"] as? String,
              let width = review["width"] as? Int,
              let height = review["height"] as? Int,
              width > 0, height > 0,
              let values = review["regions"] as? [[String: Any]], values.count <= 100_000,
              [path, source, cleaned, mask].allSatisfy({ $0.hasPrefix("/") }) else {
            throw NSError(domain: "PURENeg", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("预览数据不完整，请重新生成预览。")])
        }
        var regions: [DustRegion] = []
        var identifiers = Set<Int>()
        for value in values {
            let id = (value["id"] as? Int) ?? (value["id"] as? String).flatMap(Int.init)
            guard let id = id,
                  let x = value["x"] as? Int, let y = value["y"] as? Int,
                  let w = value["width"] as? Int, let h = value["height"] as? Int,
                  x >= 0, y >= 0, w > 0, h > 0,
                  w <= width, h <= height, x <= width - w, y <= height - h,
                  identifiers.insert(id).inserted else {
                throw NSError(domain: "PURENeg", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("灰尘区域数据无效，请重新生成预览。")])
            }
            regions.append(DustRegion(id: id, rect: NSRect(x: x, y: y, width: w, height: h), pixels: value["pixels"] as? Int ?? 0))
        }
        self.path = path
        sourcePath = source
        sourceName = (review["sourceName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: source).lastPathComponent
        cleanedPath = cleaned
        maskPath = mask
        self.width = width
        self.height = height
        self.regions = regions
        let kindIDs = (review["stats"] as? [String: Any])?["detection_types"] as? [String] ?? []
        let kinds = kindIDs.compactMap(DetectionKind.init(rawValue:))
        detectionKinds = kinds.count == kindIDs.count ? kinds : []
        context = review["context"] as? String ?? "file"
        outputRoot = review["outputRoot"] as? String
    }
}

private struct ReviewRasters {
    let cleaned: URL
    let mask: URL
}

private final class ReviewWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var session: ReviewSession?
    let canvas = PreviewCanvasView(frame: .zero)
    let batchSidebar: BatchReviewSidebar?
    var onConfirm: ((URL?, Bool) -> Void)?
    var onExportCurrent: (() -> Void)?
    var onPreviewReady: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onFinish: (() -> Void)?
    var onEditsChange: (() -> Void)?
    private(set) var excludedRegions = Set<Int>()
    private(set) var strokes: [ReviewStroke] = []
    private var appliedStrokeCount = 0
    private var strokePointCount = 0
    private var lastManualResult: String?
    private let table = NSTableView()
    private let viewMode = StudioSegments(labels: [L10n.text("原图"), L10n.text("修复后"), L10n.text("分割对比")])
    private let tools = StudioSegments(labels: [L10n.text("检查"), L10n.text("画笔"), L10n.text("橡皮擦")])
    private let overlay = NSButton(checkboxWithTitle: L10n.text("显示修复蒙版"), target: nil, action: nil)
    private let maskColorWell = NSColorWell(frame: .zero)
    private let markers = NSButton(checkboxWithTitle: L10n.text("显示自动检测圈"), target: nil, action: nil)
    private let maskOpacity = NSSlider(value: 70, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let maskOpacityLabel = NSTextField(labelWithString: "70%")
    private let radius = NSSlider(value: 8, minValue: 1, maxValue: 96, target: nil, action: nil)
    private let radiusLabel = NSTextField(labelWithString: "8 px")
    private static var inspectionHint: String { L10n.text("点位列表可排除自动修复。按 V、B、E 切换工具。") }
    private let toolHint = NSTextField(wrappingLabelWithString: ReviewWindowController.inspectionHint)
    private let kindsLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: L10n.text("适应"))
    private let sourceLabel = NSTextField(labelWithString: "")
    private let loadingView = ReviewLoadingView()
    private let loadingLabel = NSTextField(wrappingLabelWithString: L10n.text("正在准备预览…"))
    private var loadingSourceURL: URL?
    private let counts = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: L10n.text("已准备好预览。"))
    private let exportFormat = StudioSegments(labels: ReviewExportFormat.allCases.map(\.label))
    private let confirmButton = PrimaryActionButton(title: "", target: nil, action: nil)
    private let discardButton = NSButton(title: L10n.text("取消"), target: nil, action: nil)
    private let undoButton = NSButton(title: L10n.text("撤销上一笔"), target: nil, action: nil)
    private let retryButton = NSButton(title: L10n.text("重试预览"), target: nil, action: nil)
    private lazy var fitButton = NSButton(title: L10n.text("适应"), target: self, action: #selector(fit))
    private lazy var sizeButton = NSButton(title: "100%", target: self, action: #selector(actualSize))
    private lazy var listToggle = NSButton(checkboxWithTitle: L10n.text("展开点位列表"), target: self, action: #selector(changeList(_:)))
    private lazy var previousButton = NSButton(title: L10n.text("上一处"), target: self, action: #selector(previous))
    private lazy var nextButton = NSButton(title: L10n.text("下一处"), target: self, action: #selector(next))
    private lazy var savedReturn = PrimaryActionButton(title: isBatch ? L10n.text("返回灯板") : L10n.text("处理下一张"), target: self, action: #selector(nextPhoto))
    private let savedFilename = NSTextField(labelWithString: "")
    private let savedPath = NSTextField(wrappingLabelWithString: "")
    private weak var retryControl: NSView?
    private weak var exportControls: NSStackView?
    private weak var savedControls: NSStackView?
    private var outputFile: URL?
    private var outputDirectory: URL?
    private var listBody: NSStackView?
    private var selectingRegion = false
    private var working = false
    private var pending = false
    private var choosingOutput = false
    private var saved = false
    private var canExportCurrent = false
    private var closingAfterConfirmation = false
    private var hasDisplayedPreview = false
    private var canReturn = true
    private var isBatch: Bool { batchSidebar != nil }
    private var regions: [DustRegion] { session?.regions ?? [] }
    private var canView: Bool { hasDisplayedPreview && !working && !choosingOutput }
    private var canEdit: Bool { canView && (!saved || session?.context == "file") }
    var hasExportablePreview: Bool { hasDisplayedPreview && !pending && !saved && canvas.isDisplayReady }

    init(session: ReviewSession?, batchSidebar: BatchReviewSidebar? = nil) throws {
        self.session = session
        self.batchSidebar = batchSidebar
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: batchSidebar == nil ? min(1180, screen.width - 70) : min(1430, screen.width - 48),
                          height: min(780, screen.height - (batchSidebar == nil ? 70 : 60)))
        let reviewWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: reviewWindow)
        setSourceName(session?.sourceName ?? L10n.text("批量处理"))
        reviewWindow.titleVisibility = .hidden
        reviewWindow.contentMinSize = NSSize(width: isBatch ? 1090 : 980, height: 655)
        reviewWindow.appearance = NSAppearance(named: .darkAqua)
        reviewWindow.titlebarAppearsTransparent = true
        reviewWindow.isReleasedWhenClosed = false
        reviewWindow.delegate = self
        reviewWindow.center()
        buildInterface()
        if let session {
            try loadPreview(session)
            hasDisplayedPreview = canvas.isDisplayReady
            if !hasDisplayedPreview { loadingView.setSource(URL(fileURLWithPath: session.sourcePath)) }
        }
        loadingView.setAnimating(session != nil)
        batchSidebar?.onThumbnailReady = { [weak self] url, image in
            guard let self, self.loadingSourceURL == url, !self.hasDisplayedPreview else { return }
            self.loadingView.setSource(url, thumbnail: image)
        }
        canvas.onSelectRegion = { [weak self] id in self?.selectRegion(id, focus: false) }
        canvas.onToggleRegion = { [weak self] id in self?.toggleRegion(id) }
        canvas.onStroke = { [weak self] stroke in self?.appendStroke(stroke) }
        canvas.onUndoStroke = { [weak self] in self?.undoStroke() }
        canvas.onToolChange = { [weak self] tool in self?.chooseTool(tool) }
        canvas.onDisplayReadyChange = { [weak self] in
            guard let self else { return }
            if self.canvas.isDisplayReady {
                self.hasDisplayedPreview = true
                self.canvas.pendingStrokes = Array(self.strokes.dropFirst(self.appliedStrokeCount))
            }
            self.updateSelection()
            self.onPreviewReady?()
        }
        canvas.onZoomChange = { [weak self] percent in self?.zoomLabel.stringValue = String(format: "%.0f%%", percent) }
        updateSelection()
    }

    required init?(coder: NSCoder) { nil }

    private var selectedExportFormat: ReviewExportFormat {
        let formats = ReviewExportFormat.allCases
        return formats.indices.contains(exportFormat.selectedSegment) ? formats[exportFormat.selectedSegment] : .tiff
    }

    private func loadPreview(_ session: ReviewSession, rasters: ReviewRasters? = nil) throws {
        try canvas.load(sourceURL: URL(fileURLWithPath: session.sourcePath),
                        cleanedURL: rasters?.cleaned ?? URL(fileURLWithPath: session.cleanedPath),
                        maskURL: rasters?.mask ?? URL(fileURLWithPath: session.maskPath),
                        width: session.width, height: session.height, regions: session.regions)
    }

    private func updateDetectionKinds() {
        let kinds = session?.detectionKinds.map(\.label).joined(separator: " · ") ?? ""
        kindsLabel.stringValue = kinds
        kindsLabel.toolTip = kinds
        kindsLabel.isHidden = kinds.isEmpty
    }

    var confirmationFormatArguments: [String] {
        session?.context == "photocraft" ? [] : ["--format", selectedExportFormat.rawValue, "--revise-export"]
    }

    func setSourceName(_ name: String) {
        window?.title = "\(appTitle) · \(name)"
        sourceLabel.stringValue = name
        sourceLabel.toolTip = name
    }

    private func text(_ value: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        if secondary { field.textColor = StudioStyle.secondaryText }
        return field
    }

    private func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 10) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = vertical ? .vertical : .horizontal
        result.alignment = vertical ? .leading : .centerY
        result.spacing = spacing
        return result
    }

    private func button(_ title: String, action: Selector) -> NSView {
        let result = NSButton(title: title, target: self, action: action)
        return StudioStyle.actionControl(result)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func buildInterface() {
        guard let window, let root = window.contentView, let layout = window.contentLayoutGuide as? NSLayoutGuide else { return }
        StudioStyle.installBackdrop(in: window, root: root)
        viewMode.selectedSegment = PreviewMode.repaired.rawValue
        viewMode.target = self
        viewMode.action = #selector(changePreviewMode)
        viewMode.setAccessibilityLabel(L10n.text("照片对比模式"))
        tools.selectedSegment = ReviewTool.inspect.rawValue
        tools.target = self
        tools.action = #selector(changeTool)
        tools.setAccessibilityLabel(L10n.text("修整工具"))
        tools.setToolTip(L10n.text("V · 检查自动检测点"), forSegment: 0)
        tools.setToolTip(L10n.text("B · 在漏掉的灰尘上涂抹"), forSegment: 1)
        tools.setToolTip(L10n.text("E · 涂抹误修区域以恢复原始像素"), forSegment: 2)
        overlay.target = self
        overlay.action = #selector(changeOverlay)
        overlay.state = .on
        canvas.maskColor = ReviewMaskColor.load()
        maskColorWell.color = canvas.maskColor.color
        maskColorWell.supportsAlpha = false
        maskColorWell.isContinuous = true
        maskColorWell.target = self
        maskColorWell.action = #selector(changeMaskColor)
        maskColorWell.toolTip = L10n.text("更改修复蒙版和补修画笔的显示颜色")
        maskColorWell.setAccessibilityLabel(L10n.text("修复蒙版颜色"))
        markers.target = self
        markers.action = #selector(changeMarkers)
        for label in [zoomLabel, maskOpacityLabel, radiusLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = StudioStyle.amber
            label.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        maskOpacity.target = self
        maskOpacity.action = #selector(changeOpacity)
        maskOpacity.isContinuous = true
        maskOpacity.setAccessibilityLabel(L10n.text("蒙版透明度"))
        radius.target = self
        radius.action = #selector(changeRadius)
        radius.isContinuous = true
        radius.setAccessibilityLabel(L10n.text("画笔半径"))
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            maskOpacity.tintProminence = .none
            radius.tintProminence = .none
        }
        #endif
        let wordmark = StudioStyle.wordmark(width: 100, maxHeight: 23, fallbackSize: 14)
        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = StudioStyle.secondaryText
        sourceLabel.maximumNumberOfLines = 1
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        let toolbar = GlassPanel(material: .headerView, radius: 12)
        toolbar.place(stack([
            stack([wordmark, sourceLabel], spacing: 7), StudioStyle.segmentedControl(viewMode), NSView(),
            StudioStyle.actionControl(fitButton), StudioStyle.actionControl(sizeButton), zoomLabel,
            SupportWindows.supportControl()
        ], spacing: 11), horizontal: 13, vertical: 7)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = StudioStyle.photoWell
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        scroll.documentView = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let sidebar = GlassPanel(material: .sidebar)
        sidebar.widthAnchor.constraint(equalToConstant: 286).isActive = true
        counts.font = .systemFont(ofSize: 13, weight: .semibold)
        counts.textColor = StudioStyle.amber
        toolHint.font = .systemFont(ofSize: 11)
        toolHint.textColor = StudioStyle.secondaryText
        toolHint.maximumNumberOfLines = 2
        let checkColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        checkColumn.width = 28
        checkColumn.minWidth = 28
        checkColumn.maxWidth = 28
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("region"))
        nameColumn.width = 180
        table.addTableColumn(checkColumn)
        table.addTableColumn(nameColumn)
        table.headerView = nil
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 3, height: 0)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.documentView = table
        tableScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        let listBody = stack([tableScroll, stack([StudioStyle.actionControl(previousButton), StudioStyle.actionControl(nextButton)])], vertical: true, spacing: 4)
        self.listBody = listBody
        listBody.isHidden = true
        tableScroll.widthAnchor.constraint(equalTo: listBody.widthAnchor).isActive = true
        undoButton.target = self
        undoButton.action = #selector(undoStroke)
        undoButton.toolTip = L10n.text("撤销最后提交的画笔或橡皮擦笔画（⌘Z）")
        retryButton.target = self
        retryButton.action = #selector(retryPreview)
        let retryControl = StudioStyle.actionControl(retryButton)
        self.retryControl = retryControl
        retryControl.isHidden = true
        let overlayRow = stack([
            StudioStyle.checkboxControl(overlay), NSView(),
            StudioStyle.glassControl(stack([text(L10n.text("颜色"), size: 11, secondary: true), maskColorWell], spacing: 5), horizontal: 6, vertical: 2)
        ], spacing: 6)
        let opacityRow = StudioStyle.glassControl(stack([text(L10n.text("不透明度"), size: 11, secondary: true), maskOpacity, maskOpacityLabel], spacing: 7))
        let radiusRow = StudioStyle.glassControl(stack([text(L10n.text("画笔半径"), size: 11, secondary: true), radius, radiusLabel], spacing: 7))
        let toolsGlass = StudioStyle.segmentedControl(tools)
        kindsLabel.font = .systemFont(ofSize: 11)
        kindsLabel.textColor = StudioStyle.secondaryText
        kindsLabel.lineBreakMode = .byTruncatingTail
        kindsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateDetectionKinds()
        let detectionHeader = stack([StudioStyle.section("01", L10n.text("检测"), size: 14), NSView(), kindsLabel], spacing: 7)
        let sidebarItems: [NSView] = [
            detectionHeader, counts, overlayRow, opacityRow, StudioStyle.checkboxControl(markers), StudioStyle.checkboxControl(listToggle), listBody,
            separator(), StudioStyle.section("02", L10n.text("修整"), size: 14), toolsGlass, toolHint, radiusRow, StudioStyle.actionControl(undoButton),
            NSView(), separator()
        ]
        var exportItems: [NSView] = [StudioStyle.section("03", isBatch ? L10n.text("导出") : L10n.text("应用"), size: 14)]
        if !isBatch && session?.context != "photocraft" {
            exportFormat.selectedSegment = ReviewExportFormat.allCases.firstIndex {
                $0.rawValue == AppPreferences.exportFormat
            } ?? 0
            exportFormat.target = self
            exportFormat.action = #selector(changeExportFormat)
            exportFormat.setAccessibilityLabel(L10n.text("修复图像导出格式"))
            exportItems.append(stack([
                text(L10n.text("导出格式"), size: 11, secondary: true),
                StudioStyle.segmentedControl(exportFormat)
            ], spacing: 7))
        }
        exportItems += [message, retryControl, stack([
            StudioStyle.actionControl(discardButton), StudioStyle.actionControl(confirmButton)
        ], spacing: 6)]
        let exportControls = stack(exportItems, vertical: true, spacing: 9)
        self.exportControls = exportControls
        savedFilename.font = .systemFont(ofSize: 12, weight: .medium)
        savedFilename.lineBreakMode = .byTruncatingMiddle
        savedFilename.isSelectable = true
        savedPath.font = .systemFont(ofSize: 11)
        savedPath.textColor = StudioStyle.secondaryText
        savedPath.maximumNumberOfLines = 2
        savedPath.lineBreakMode = .byTruncatingMiddle
        savedPath.isSelectable = true
        let savedControls = stack([
            StudioStyle.section("03", L10n.text("保存完成"), size: 14), savedFilename, savedPath,
            stack([button(L10n.text("在访达显示"), action: #selector(revealSavedResult)), StudioStyle.actionControl(savedReturn)], spacing: 6)
        ], vertical: true, spacing: 7)
        self.savedControls = savedControls
        savedControls.isHidden = true
        let sidebarContent = stack(sidebarItems + [exportControls, savedControls], vertical: true, spacing: 9)
        sidebar.place(sidebarContent, horizontal: 15, vertical: 14)
        for view in [detectionHeader, overlayRow, opacityRow, radiusRow, toolsGlass, toolHint, exportControls, savedControls] as [NSView] {
            view.widthAnchor.constraint(equalTo: sidebarContent.widthAnchor).isActive = true
        }
        message.widthAnchor.constraint(equalTo: exportControls.widthAnchor).isActive = true
        savedFilename.widthAnchor.constraint(equalTo: savedControls.widthAnchor).isActive = true
        savedPath.widthAnchor.constraint(equalTo: savedControls.widthAnchor).isActive = true
        for box in sidebarContent.arrangedSubviews.compactMap({ $0 as? NSBox }) {
            box.widthAnchor.constraint(equalTo: sidebarContent.widthAnchor).isActive = true
        }

        message.font = .systemFont(ofSize: 12)
        message.textColor = StudioStyle.secondaryText
        message.maximumNumberOfLines = 3
        if isBatch {
            confirmButton.title = L10n.surface("导出当前")
            discardButton.title = L10n.text("返回灯板")
        } else {
            changeExportFormat()
        }
        confirmButton.target = self
        confirmButton.action = #selector(confirm)
        confirmButton.keyEquivalent = "\r"
        discardButton.target = self
        discardButton.action = #selector(discard)
        discardButton.keyEquivalent = "\u{1b}"
        let legend = text(L10n.text("蒙版标出修复像素　·　滚动缩放　·　空格 + 拖动平移"), size: 11, secondary: true)
        let main = stack([scroll, legend], vertical: true, spacing: 9)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(sidebar)
        root.addSubview(main)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(loadingView)
        loadingLabel.font = .systemFont(ofSize: 14, weight: .medium)
        loadingLabel.textColor = StudioStyle.light
        loadingLabel.alignment = .center
        loadingLabel.maximumNumberOfLines = 3
        let loadingStatus = NSView()
        loadingStatus.translatesAutoresizingMaskIntoConstraints = false
        loadingStatus.wantsLayer = true
        loadingStatus.layer?.cornerRadius = 13
        loadingStatus.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor
        loadingView.addSubview(loadingStatus)
        StudioStyle.embed(loadingLabel, in: loadingStatus, horizontal: 14, vertical: 7)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: layout.topAnchor, constant: 12),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sidebar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            main.topAnchor.constraint(equalTo: sidebar.topAnchor),
            main.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: main.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            loadingView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: scroll.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            loadingStatus.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            loadingStatus.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor),
            loadingStatus.widthAnchor.constraint(lessThanOrEqualTo: loadingView.widthAnchor, constant: -32)
        ])
        if let batchSidebar {
            batchSidebar.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(batchSidebar)
            NSLayoutConstraint.activate([
                batchSidebar.leadingAnchor.constraint(equalTo: main.trailingAnchor, constant: 12),
                batchSidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                batchSidebar.topAnchor.constraint(equalTo: sidebar.topAnchor),
                batchSidebar.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
                batchSidebar.widthAnchor.constraint(equalToConstant: 238)
            ])
        } else {
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12).isActive = true
        }
        listBody.widthAnchor.constraint(equalTo: sidebarContent.widthAnchor).isActive = true
    }

    func present(from source: NSWindow? = nil) {
        guard let window else { return }
        if let source { StudioStyle.expandWorkspaceWindow(window, from: source) }
        window.makeKeyAndOrderFront(nil)
        if source != nil {
            DispatchQueue.main.async { [weak self] in self?.canvas.fitToWindow() }
        }
    }

    func setWorking(_ value: Bool, status: String? = nil) {
        working = value
        updateSelection()
        if value {
            message.stringValue = status ?? (session?.context == "photocraft" ? L10n.text("正在应用已审核的修复…") : L10n.text("正在保存已审核的修复…"))
        }
    }

    func setBatchState(locked: Bool, canReturn: Bool, canExportCurrent: Bool, status: String, detectingCurrent: Bool) {
        let actionsChanged = self.canReturn != canReturn || self.canExportCurrent != canExportCurrent
        self.canReturn = canReturn
        self.canExportCurrent = canExportCurrent
        if working != locked {
            setWorking(locked, status: status)
            if !locked && !pending && session != nil { setPreviewPending(false) }
        } else if actionsChanged {
            updateSelection()
        }
        if session == nil {
            loadingView.setAnimating(detectingCurrent)
            message.stringValue = L10n.text("预览就绪后即可检查并导出。")
            loadingLabel.stringValue = status.isEmpty ? L10n.text("从右侧选择一张照片开始处理。") : status
        }
    }

    func setPreviewPending(_ value: Bool, error: String? = nil) {
        pending = value
        retryControl?.isHidden = error == nil || !value
        message.textColor = error == nil ? StudioStyle.secondaryText : .labelColor
        if let error = error { message.stringValue = error }
        else if value { message.stringValue = L10n.text("正在更新修复图和蒙版…") }
        else { message.stringValue = lastManualResult ?? (isBatch ? L10n.text("检查修复结果后即可导出。") : L10n.text("预览已更新，等待应用。")) }
        updateSelection()
    }

    func setBatchPhoto(_ frame: BatchFrame, loadingThumbnail: CGImage? = nil) throws {
        // PreviewCanvas validates the incoming files before replacing the current photo.
        let rasters = frame.displaysExport ? frame.exportedRasters : nil
        if let session = frame.session {
            try loadPreview(session, rasters: rasters)
        } else {
            canvas.clearImages()
            zoomLabel.stringValue = L10n.text("适应")
        }
        session = frame.session
        hasDisplayedPreview = canvas.isDisplayReady
        loadingSourceURL = frame.url
        loadingView.setSource(frame.url, thumbnail: loadingThumbnail)
        loadingView.setAnimating(session != nil)
        loadingLabel.stringValue = L10n.text("正在准备预览…")
        setSourceName(session?.sourceName ?? frame.url.lastPathComponent)
        updateDetectionKinds()
        saved = false
        outputFile = nil
        outputDirectory = nil
        exportControls?.isHidden = false
        savedControls?.isHidden = true
        viewMode.selectedSegment = PreviewMode.repaired.rawValue
        canvas.mode = .repaired
        tools.selectedSegment = ReviewTool.inspect.rawValue
        canvas.tool = .inspect
        toolHint.stringValue = Self.inspectionHint
        overlay.state = .on
        markers.state = .off
        maskOpacity.doubleValue = 70
        radius.doubleValue = 8
        listToggle.state = .off
        changeOverlay()
        changeMarkers()
        changeOpacity()
        changeRadius()
        changeList(listToggle)
        excludedRegions = frame.excludedRegions
        strokes = frame.strokes
        appliedStrokeCount = rasters == nil ? 0 : strokes.count
        lastManualResult = nil
        strokePointCount = strokes.reduce(0) { $0 + $1.points.count }
        if canvas.isDisplayReady { canvas.pendingStrokes = Array(strokes.dropFirst(appliedStrokeCount)) }
        table.deselectAll(nil)
        table.reloadData()
        setPreviewPending(false)
        if frame.displaysExport, let output = frame.output {
            showSavedResult(file: output, directory: output.deletingLastPathComponent(), includedMask: frame.exportedWithMask)
        }
    }

    func updateCleanedImage(_ path: String, maskPath: String, stats: [String: Any]) throws {
        try canvas.updateCleanedImage(url: URL(fileURLWithPath: path), maskURL: URL(fileURLWithPath: maskPath))
        appliedStrokeCount = strokes.count
        if canvas.isDisplayReady { canvas.pendingStrokes = [] }
        if strokes.isEmpty {
            lastManualResult = nil
        } else {
            let added = max(0, stats["added_pixels"] as? Int ?? 0)
            let restored = max(0, stats["restored_pixels"] as? Int ?? 0)
            lastManualResult = L10n.text("手动补修 \(added) 像素 · 恢复 \(restored) 像素")
        }
    }

    func finishAndClose() {
        closingAfterConfirmation = true
        close()
    }

    func showSavedResult(file: URL?, directory: URL?, includedMask: Bool) {
        saved = true
        outputFile = file
        outputDirectory = directory ?? file?.deletingLastPathComponent()
        let filename = file?.lastPathComponent ?? L10n.text("修复图像已保存")
        let path = outputDirectory?.path ?? ""
        savedFilename.stringValue = includedMask ? L10n.text("\(filename) · 附修复蒙版") : filename
        savedFilename.toolTip = savedFilename.stringValue
        savedPath.stringValue = path
        savedPath.toolTip = path
        tools.selectedSegment = ReviewTool.inspect.rawValue
        canvas.tool = .inspect
        canvas.selectedRegionID = nil
        toolHint.stringValue = L10n.text("可继续用画笔或橡皮擦修整，再保存新版本。")
        overlay.state = .off
        markers.state = .off
        changeOverlay()
        changeMarkers()
        viewMode.selectedSegment = PreviewMode.repaired.rawValue
        changePreviewMode()
        exportControls?.isHidden = true
        savedControls?.isHidden = false
        window?.makeFirstResponder(canvas)
        setWorking(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { canReturn && !working && !choosingOutput }

    func windowWillClose(_ notification: Notification) {
        maskColorWell.deactivate()
        canvas.onDisplayReadyChange = nil
        loadingView.setLoading(false, animated: false)
        loadingView.setSource(nil)
        canvas.clearImages()
        guard !closingAfterConfirmation else { return }
        if saved { onFinish?() }
        else { onDiscard?() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { regions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard regions.indices.contains(row) else { return nil }
        let region = regions[row]
        if tableColumn?.identifier.rawValue == "enabled" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheckbox(_:)))
            check.tag = region.id
            check.state = excludedRegions.contains(region.id) ? .off : .on
            check.isEnabled = canEdit
            check.toolTip = excludedRegions.contains(region.id) ? L10n.text("保留原图；点击恢复修复") : L10n.text("将修复；点击保留原图")
            return check
        }
        let title = text(L10n.text("第 \(row + 1) 处"), size: 12, weight: .medium)
        let caption = text("\(Int(region.rect.width)) × \(Int(region.rect.height)) px · \(excludedRegions.contains(region.id) ? L10n.text("保留") : L10n.text("修复"))", size: 10, secondary: true)
        let cell = stack([title, caption], vertical: true, spacing: 2)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard regions.indices.contains(row) else { return }
        canvas.selectedRegionID = regions[row].id
        if !selectingRegion { canvas.focusRegion(id: regions[row].id) }
        updateSelection()
    }

    private func selectRegion(_ id: Int, focus: Bool) {
        guard let row = regions.firstIndex(where: { $0.id == id }) else { return }
        selectingRegion = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectingRegion = false
        table.scrollRowToVisible(row)
        canvas.selectedRegionID = id
        if focus { canvas.focusRegion(id: id) }
        updateSelection()
    }

    private func updateSelection() {
        counts.stringValue = hasDisplayedPreview ? L10n.text("自动 \(regions.count - excludedRegions.count) 处  ·  手动 \(strokes.count) 笔") : L10n.text("等待检测结果")
        counts.textColor = hasDisplayedPreview ? StudioStyle.amber : StudioStyle.secondaryText
        loadingView.setLoading(!hasDisplayedPreview)
        canvas.isUserInteractionEnabled = canView
        if table.isEnabled != canEdit {
            table.isEnabled = canEdit
            table.enumerateAvailableRowViews { _, row in
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSButton)?.isEnabled = canEdit
            }
        }
        viewMode.isEnabled = canView
        fitButton.isEnabled = canView
        sizeButton.isEnabled = canView
        tools.isEnabled = canEdit
        markers.isEnabled = canView
        overlay.isEnabled = markers.isEnabled
        if !canEdit { maskColorWell.deactivate() }
        maskColorWell.isEnabled = canEdit
        maskOpacity.isEnabled = overlay.isEnabled && overlay.state == .on
        radius.isEnabled = canEdit
        listToggle.isEnabled = canEdit
        previousButton.isEnabled = canEdit
        nextButton.isEnabled = canEdit
        retryButton.isEnabled = canEdit
        exportFormat.isEnabled = canEdit
        discardButton.isEnabled = canReturn && !working && !choosingOutput && !saved
        savedReturn.isEnabled = canReturn && !working && !choosingOutput
        undoButton.isEnabled = canEdit && !strokes.isEmpty
        confirmButton.isEnabled = canEdit && hasExportablePreview && (!isBatch || canExportCurrent)
        canvas.excludedRegions = excludedRegions
    }

    private func toggleRegion(_ id: Int) {
        guard canEdit, regions.contains(where: { $0.id == id }) else { return }
        if !excludedRegions.insert(id).inserted { excludedRegions.remove(id) }
        table.reloadData()
        updateSelection()
        editsChanged()
    }

    @objc private func toggleCheckbox(_ sender: NSButton) { selectRegion(sender.tag, focus: false); toggleRegion(sender.tag) }
    @objc private func changeList(_ sender: NSButton) { listBody?.isHidden = sender.state == .off }
    @objc private func changeOverlay() {
        canvas.showMask = overlay.state == .on
        maskOpacity.isEnabled = overlay.isEnabled && overlay.state == .on
    }
    @objc private func changeMaskColor() {
        guard canEdit, let color = ReviewMaskColor(color: maskColorWell.color) else { return }
        canvas.maskColor = color
        color.save()
    }
    @objc private func changeOpacity() {
        let percent = Int(maskOpacity.doubleValue.rounded())
        canvas.maskOpacity = CGFloat(percent) / 100
        maskOpacityLabel.stringValue = "\(percent)%"
    }
    @objc private func changeRadius() {
        let pixels = Int(radius.doubleValue.rounded())
        canvas.brushRadius = pixels
        radiusLabel.stringValue = "\(pixels) px"
    }
    @objc private func changeTool() {
        guard let tool = ReviewTool(rawValue: tools.selectedSegment) else { return }
        chooseTool(tool)
        window?.makeFirstResponder(canvas)
    }
    private func chooseTool(_ tool: ReviewTool) {
        guard canEdit else { return }
        tools.selectedSegment = tool.rawValue
        canvas.tool = tool
        if tool != .inspect && canvas.mode == .original {
            viewMode.selectedSegment = PreviewMode.repaired.rawValue
            changePreviewMode()
        }
        switch tool {
        case .inspect: toolHint.stringValue = Self.inspectionHint
        case .add: toolHint.stringValue = L10n.text("在漏掉的灰尘上涂抹。建议在 100% 下检查。")
        case .erase: toolHint.stringValue = L10n.text("涂抹拉链、纽扣等误修部位以恢复原像素。")
        }
    }
    private func appendStroke(_ stroke: ReviewStroke) {
        guard canEdit else { return }
        guard strokes.count < 128, strokePointCount + stroke.points.count <= 16_000 else {
            message.textColor = .labelColor
            message.stringValue = L10n.text("已达到本次审核的笔画上限。可撤销一笔或应用当前修改。")
            return
        }
        strokes.append(stroke)
        strokePointCount += stroke.points.count
        canvas.pendingStrokes = Array(strokes.dropFirst(appliedStrokeCount))
        editsChanged()
    }
    @objc private func undoStroke() {
        guard canEdit, let removed = strokes.popLast() else { return }
        strokePointCount -= removed.points.count
        appliedStrokeCount = min(appliedStrokeCount, strokes.count)
        canvas.pendingStrokes = Array(strokes.dropFirst(appliedStrokeCount))
        editsChanged()
    }

    private func editsChanged() {
        if saved {
            saved = false
            outputFile = nil
            outputDirectory = nil
            exportControls?.isHidden = false
            savedControls?.isHidden = true
            if canvas.tool == .inspect { toolHint.stringValue = Self.inspectionHint }
        }
        onEditsChange?()
    }

    @objc private func retryPreview() {
        guard canEdit else { return }
        onEditsChange?()
    }
    @objc private func changePreviewMode() {
        canvas.mode = PreviewMode(rawValue: viewMode.selectedSegment) ?? .repaired
        if canvas.mode == .original && canvas.tool != .inspect { chooseTool(.inspect) }
    }
    @objc private func changeMarkers() { canvas.showRegions = markers.state == .on }
    @objc private func changeExportFormat() {
        confirmButton.title = session?.context == "photocraft" ? L10n.text("应用并导回") : L10n.text("保存 \(selectedExportFormat.label)…")
    }
    @objc private func fit() { canvas.fitToWindow() }
    @objc private func actualSize() { canvas.zoom100() }
    @objc private func previous() { navigate(-1) }
    @objc private func next() { navigate(1) }
    private func navigate(_ direction: Int) {
        guard canEdit, !regions.isEmpty else { return }
        let row = table.selectedRow < 0 ? (direction > 0 ? -1 : 0) : table.selectedRow
        let next = (row + direction + regions.count) % regions.count
        selectRegion(regions[next].id, focus: true)
    }
    @objc private func confirm() {
        guard confirmButton.isEnabled, let session else { return }
        if isBatch {
            onExportCurrent?()
            return
        }
        if session.context == "photocraft" {
            onConfirm?(nil, false)
            return
        }
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择保存位置")
        panel.message = L10n.text("修复图像将保存在所选位置的结果文件夹中。")
        panel.prompt = L10n.text("保存 \(selectedExportFormat.label)")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let includeMask = NSButton(checkboxWithTitle: L10n.text("同时保存修复蒙版"), target: nil, action: nil)
        includeMask.state = AppPreferences.includeMask ? .on : .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        includeMask.frame = NSRect(x: 10, y: 5, width: 260, height: 20)
        accessory.addSubview(includeMask)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        if let path = AppPreferences.exportFolder?.path ?? session.outputRoot {
            var folder = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            while !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                let parent = folder.deletingLastPathComponent()
                guard parent != folder else { break }
                folder = parent
            }
            panel.directoryURL = folder
        }
        choosingOutput = true
        updateSelection()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.choosingOutput = false
            self.updateSelection()
            if response == .OK, let folder = panel.url { self.onConfirm?(folder, includeMask.state == .on) }
        }
    }
    @objc private func discard() { guard canReturn && !working && !choosingOutput else { return }; close() }
    @objc private func nextPhoto() {
        guard saved, canReturn, !working, !choosingOutput else { return }
        close()
    }
    @objc private func revealSavedResult() {
        if let outputFile { NSWorkspace.shared.activateFileViewerSelecting([outputFile]) }
        else if let outputDirectory { NSWorkspace.shared.open(outputDirectory) }
    }
}

private struct BatchFrame {
    let id = UUID()
    let url: URL
    var session: ReviewSession?
    var excludedRegions = Set<Int>()
    var strokes: [ReviewStroke] = []
    var output: URL?
    var exportedRasters: ReviewRasters?
    var exportedWithMask = false
    var revisingExport = false
    var error: String?

    var hasEdits: Bool { !excludedRegions.isEmpty || !strokes.isEmpty }
    var displaysExport: Bool { output != nil && !revisingExport }
    var canExport: Bool { !displaysExport && session != nil }
}

private final class BatchSession {
    struct Export {
        let folder: URL
        let format: ReviewExportFormat
        let includeMask: Bool
        var pending: [UUID]
        var saved = 0
        var failed = 0
    }

    enum Job {
        case prepare(UUID, background: Bool)
        case export(UUID)

        var id: UUID {
            switch self {
            case .prepare(let id, _), .export(let id): return id
            }
        }

        var isBackground: Bool {
            if case .prepare(_, true) = self { return true }
            return false
        }
    }

    enum BackgroundMode { case automatic, requested, stopped }
    enum DetectionWorker { case running, paused, yielding }

    let workDirectory: URL
    let detectionArguments: [String]
    let controller = BatchLightTableController()
    var frames: [BatchFrame]
    var picked = Set<UUID>()
    var exportChecked = Set<UUID>()
    var current: UUID?
    var reviewAfterDetection: UUID?
    var backgroundMode = BackgroundMode.automatic
    var detectionWorker = DetectionWorker.running
    var backgroundStatus = ""
    var export: Export?
    var job: Job?
    var jobReview: ReviewSession?
    var jobOutput: URL?
    var jobRasters: ReviewRasters?
    var detectionProgress: Double?
    var status = ""
    var choosingExport = false

    init(urls: [URL], detectionArguments: [String]) throws {
        frames = urls.map { BatchFrame(url: $0) }
        self.detectionArguments = detectionArguments
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PURENeg-Batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func index(for id: UUID) -> Int? { frames.firstIndex { $0.id == id } }
    func includes(_ id: UUID) -> Bool { picked.isEmpty || picked.contains(id) }
    var scope: [BatchFrame] { frames.filter { includes($0.id) } }
    var isBusy: Bool { job != nil || hasForegroundWork }
    var hasForegroundWork: Bool { reviewLocked || job?.isBackground == false }
    var allowsBackgroundDetection: Bool {
        switch backgroundMode {
        case .automatic: return AppPreferences.autoDetectWhenIdle
        case .requested: return true
        case .stopped: return false
        }
    }
    var nextBackgroundFrame: BatchFrame? {
        frames.first { includes($0.id) && $0.session == nil && $0.error == nil }
    }
    var reviewLocked: Bool { export != nil || choosingExport || reviewAfterDetection != nil }
    var detectingID: UUID? {
        if case .prepare(let id, _) = job { return id }
        return nil
    }
    var hasUnsavedReview: Bool {
        frames.contains { !$0.displaysExport && ($0.hasEdits || $0.revisingExport || exportChecked.contains($0.id)) }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private enum InputSource: Int { case file, photoCraft, photoshop }
    private static let fileSourceNote = L10n.text("可一次选择多张 TIFF 或 JPEG。审核完成后选择格式和保存位置。")
    private static let chooseInputHint = L10n.text("选择要处理的 TIFF 或 JPEG")
    private static let waitingDetail = L10n.text("检测完成后会打开审核窗口。逐处检查并确认，再保存或导回 PhotoCraft。")
    private static let photoCraftHint = L10n.text("启动专用 PhotoCraft 会话，然后在其中打开扫描件。")
    private var window: NSWindow!
    private let inputPath = NSTextField(labelWithString: AppDelegate.chooseInputHint)
    private let outputPath = NSTextField(labelWithString: "")
    private weak var outputRow: NSStackView?
    private let mode = StudioSegments(labels: [L10n.text("独立处理"), L10n.text("从 PhotoCraft 载入"), L10n.text("从 Photoshop 载入")])
    private let fileRow = NSStackView()
    private let photoRow = NSStackView()
    private let sourceNote = NSTextField(wrappingLabelWithString: AppDelegate.fileSourceNote)
    private let connection = NSTextField(wrappingLabelWithString: AppDelegate.photoCraftHint)
    private var photoCraftConnection = AppDelegate.photoCraftHint
    private let connectButton = NSButton(title: L10n.text("启动 / 连接 PhotoCraft"), target: nil, action: nil)
    private let chooseButton = NSButton(title: L10n.text("选择图像…"), target: nil, action: nil)
    private let folderButton = NSButton(title: L10n.text("更改…"), target: nil, action: nil)
    private let polarity = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sensitivity = NSSlider(value: 1, minValue: 0.5, maxValue: 2, target: nil, action: nil)
    private let sensitivityValue = NSTextField(labelWithString: "1.00")
    private let detectors = DetectionKind.allCases.map { kind in
        (kind: kind, checkbox: NSButton(checkboxWithTitle: kind.label, target: nil, action: nil))
    }
    private let detectionHint = NSTextField(labelWithString: L10n.text("可单独或组合勾选。"))
    private let startButton = PrimaryActionButton(title: L10n.text("检测并预览"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.text("取消"), target: nil, action: nil)
    private let revealButton = NSButton(title: L10n.text("显示结果"), target: nil, action: nil)
    private let progress = LaserProgressBar()
    private let status = NSTextField(wrappingLabelWithString: L10n.text("准备就绪"))
    private let detail = NSTextField(wrappingLabelWithString: AppDelegate.waitingDetail)
    private var selectedInputs: [URL] = []
    private var selectedOutput = AppPreferences.exportFolder
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/PURENeg", isDirectory: true)
    private var resultDirectory: URL?
    private var process: Process?
    private var workerStartedAt: Date?
    private var importingPhotoshop = false
    private var photoshopSnapshotDirectory: URL?
    private var taskKind = ""
    private var wasCancelled = false
    private var sawResult = false
    private var reportedError: String?
    private var stderrText = ""
    private let readQueue = DispatchQueue(label: "PURENeg.worker-output")
    private var stdoutBuffer = Data()
    private var reviewController: ReviewWindowController?
    private var previewDebounce: DispatchWorkItem?
    private var previewGeneration = 0
    private var activePreviewGeneration = 0
    private var previewNeedsRefresh = false
    private var previewWasApplied = false
    private var stoppingObsoletePreview = false
    private var activePreviewReviewPath: String?
    private var currentPreviewDirectory: URL?
    private var activeEditsFile: URL?
    private var startupWindow: StartupWindow?
    private var batch: BatchSession?
    private var batchReviewEdited = false
    private var batchActivityMonitor: Any?
    private var batchIdleTimer: Timer?
    private var lastBatchActivity: TimeInterval = 0
    private var terminateAfterBackgroundDetection = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = StudioStyle.appIcon
        createMenu()
        buildWindow()
        if let index = CommandLine.arguments.firstIndex(of: "--open-review") {
            showMainWindow()
            guard CommandLine.arguments.indices.contains(index + 1) else { fail(L10n.text("缺少审核记录路径。")); return }
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.async { [weak self] in self?.launch(command: "inspect-review", arguments: ["--review", path]) }
        } else if let artwork = StudioStyle.launchArtwork {
            showStartupArtwork(artwork)
        } else {
            showMainWindow()
        }
    }

    private func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showStartupArtwork(_ artwork: NSImage) {
        let width = min(592, (NSScreen.main?.visibleFrame.width ?? 980) - 64)
        let rect = NSRect(x: 0, y: 0, width: width, height: width / StartupArtworkView.aspectRatio)
        let splash = StartupWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        splash.title = appTitle
        splash.isOpaque = false
        splash.backgroundColor = .clear
        splash.hasShadow = true
        splash.isReleasedWhenClosed = false
        splash.contentView = StartupArtworkView(frame: rect, artwork: artwork)
        splash.center()
        startupWindow = splash
        splash.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(720)) { [weak self] in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            self.startupWindow?.orderOut(nil)
            self.startupWindow = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let current = reviewController?.window ?? batch?.controller.window else { return true }
        if current.isMiniaturized { current.deminiaturize(nil) }
        current.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if importingPhotoshop {
            let alert = NSAlert()
            alert.messageText = L10n.text("正在载入 Photoshop 文档")
            alert.informativeText = L10n.text("请等待文档载入完成后再退出。")
            alert.addButton(withTitle: L10n.text("继续等待"))
            alert.runModal()
            return .terminateCancel
        }
        if batch?.export != nil || (process?.isRunning == true && taskKind == "confirm") {
            let alert = NSAlert()
            alert.messageText = L10n.text("正在保存审核结果")
            alert.informativeText = L10n.text("请等待当前导出完成后再退出。")
            alert.addButton(withTitle: L10n.text("继续等待"))
            alert.runModal()
            return .terminateCancel
        }
        guard process?.isRunning == true else {
            if let batch, batch.hasUnsavedReview || batchReviewEdited {
                return confirmLeavingBatch() ? .terminateNow : .terminateCancel
            }
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("正在处理扫描件")
        alert.informativeText = L10n.text("退出会停止当前处理。原始文件会保留，已完成的输出也会保留。")
        alert.addButton(withTitle: L10n.text("继续处理"))
        alert.addButton(withTitle: L10n.text("停止并退出"))
        if alert.runModal() == .alertSecondButtonReturn {
            if let batch, batch.job?.isBackground == true {
                terminateAfterBackgroundDetection = true
                stopObservingBatchActivity()
                cancelBackgroundDetection(batch)
                return .terminateLater
            }
            wasCancelled = true
            if !stoppingObsoletePreview { process?.terminate() }
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let batch, process?.isRunning != true {
            try? FileManager.default.removeItem(at: batch.workDirectory)
        }
        if process?.isRunning != true { removePhotoshopSnapshot() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !importingPhotoshop }

    private func createMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: appTitle, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appTitle)
        let about = NSMenuItem(title: L10n.text("关于 \(appTitle)"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let settings = NSMenuItem(title: L10n.text("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("退出 \(appTitle)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L10n.text("文件"))
        let choose = NSMenuItem(title: L10n.text("选择 TIFF 或 JPEG…"), action: #selector(selectInput), keyEquivalent: "o")
        choose.target = self
        fileMenu.addItem(choose)
        let openReview = NSMenuItem(title: L10n.text("打开已有审核…"), action: #selector(selectReview), keyEquivalent: "O")
        openReview.target = self
        fileMenu.addItem(openReview)
        let run = NSMenuItem(title: L10n.text("检测并预览"), action: #selector(start), keyEquivalent: "r")
        run.target = self
        fileMenu.addItem(run)
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let helpItem = NSMenuItem()
        let help = NSMenu(title: L10n.text("帮助"))
        let guide = NSMenuItem(title: SupportWindows.guideTitle, action: #selector(showGuide), keyEquivalent: "?")
        guide.target = self
        help.addItem(guide)
        help.addItem(.separator())
        let support = NSMenuItem(title: SupportWindows.supportTitle, action: #selector(showSupport), keyEquivalent: "")
        support.target = self
        help.addItem(support)
        helpItem.submenu = help
        menu.addItem(helpItem)
        NSApp.mainMenu = menu
        NSApp.helpMenu = help
    }

    @objc private func showGuide() { SupportWindows.showGuide() }
    @objc private func showSupport() { SupportWindows.showSupport() }
    @MainActor @objc private func showSettings() {
        SettingsWindow.show { [weak self] in
            guard let self else { return false }
            return self.process == nil && self.reviewController == nil && self.batch == nil && !self.importingPhotoshop
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectInput) || menuItem.action == #selector(selectReview) {
            return startupWindow == nil && process == nil && !importingPhotoshop && reviewController == nil && batch == nil
        }
        if menuItem.action == #selector(start) {
            return startupWindow == nil && process == nil && !importingPhotoshop && reviewController == nil && batch == nil && !selectedDetectors.isEmpty
        }
        return true
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appTitle,
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.6",
            .applicationIcon: StudioStyle.appIcon,
            .credits: NSAttributedString(string: L10n.text("胶片扫描除尘与修整\n\n基于 Magnus Holmes 的 film-dust（MIT）。\n通过 PhotoCraft 本地控制接口建立修复图层与蒙版。\n第三方许可见应用 Resources 中的 vendor/film-dust。"))
        ])
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        if secondary { field.textColor = StudioStyle.secondaryText }
        return field
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func card(_ content: NSStackView) -> GlassPanel {
        let panel = GlassPanel()
        panel.place(content, horizontal: 18)
        return panel
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 694), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = appTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 740, height: 660)
        window.center()
        window.delegate = self
        guard let root = window.contentView, let layout = window.contentLayoutGuide as? NSLayoutGuide else { return }
        StudioStyle.installBackdrop(in: window, root: root)

        let icon = NSImageView(image: StudioStyle.artwork)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 62).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 62).isActive = true
        let wordmark = StudioStyle.wordmark(width: 218, maxHeight: 47, fallbackSize: 33)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let badge = label(L10n.text("本地处理"), size: 11, weight: .medium, secondary: true)
        let header = horizontal([icon, wordmark, spacer, badge, SupportWindows.supportControl()], spacing: 16)

        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel(L10n.text("处理来源"))
        inputPath.lineBreakMode = .byTruncatingMiddle
        inputPath.textColor = StudioStyle.secondaryText
        inputPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inputPath.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseButton.target = self
        chooseButton.action = #selector(selectInput)
        fileRow.orientation = .horizontal
        fileRow.alignment = .centerY
        fileRow.spacing = 12
        fileRow.addArrangedSubview(inputPath)
        fileRow.addArrangedSubview(StudioStyle.actionControl(chooseButton))
        connectButton.target = self
        connectButton.action = #selector(connect)
        connection.font = .systemFont(ofSize: 12)
        connection.textColor = StudioStyle.secondaryText
        connection.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        photoRow.orientation = .horizontal
        photoRow.alignment = .centerY
        photoRow.spacing = 12
        photoRow.addArrangedSubview(connection)
        photoRow.addArrangedSubview(StudioStyle.actionControl(connectButton))
        photoRow.isHidden = true
        sourceNote.font = .systemFont(ofSize: 11)
        sourceNote.textColor = StudioStyle.secondaryText
        let sourceGlass = StudioStyle.segmentedControl(mode)
        let sourceContent = vertical([StudioStyle.section("01", L10n.text("处理来源")), sourceGlass, fileRow, photoRow, sourceNote], spacing: 10)
        let sourceCard = card(sourceContent)
        for view in [sourceGlass, fileRow, photoRow, sourceNote] { view.widthAnchor.constraint(equalTo: sourceContent.widthAnchor).isActive = true }

        outputPath.stringValue = selectedOutput.path
        outputPath.lineBreakMode = .byTruncatingMiddle
        outputPath.font = .systemFont(ofSize: 12)
        outputPath.textColor = StudioStyle.secondaryText
        outputPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outputPath.setContentHuggingPriority(.defaultLow, for: .horizontal)
        folderButton.target = self
        folderButton.action = #selector(selectOutput)
        let outputRow = horizontal([label(L10n.text("结果目录"), size: 12, weight: .medium), outputPath, StudioStyle.actionControl(folderButton)])
        self.outputRow = outputRow
        outputRow.isHidden = true
        polarity.addItems(withTitles: [L10n.text("自动判断"), L10n.text("白色灰尘 · 已反相负片"), L10n.text("黑色灰尘 · 正片 / 未反相")])
        polarity.isBordered = false
        polarity.widthAnchor.constraint(equalToConstant: 233).isActive = true
        sensitivity.target = self
        sensitivity.action = #selector(sensitivityChanged)
        sensitivity.isContinuous = true
        sensitivity.widthAnchor.constraint(equalToConstant: 150).isActive = true
        sensitivityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sensitivityValue.textColor = StudioStyle.amber
        sensitivityValue.widthAnchor.constraint(equalToConstant: 34).isActive = true
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { sensitivity.tintProminence = .none }
        #endif
        for detector in detectors {
            detector.checkbox.state = .on
            detector.checkbox.target = self
            detector.checkbox.action = #selector(updateDetectionAvailability)
        }
        detectionHint.font = .systemFont(ofSize: 11)
        detectionHint.textColor = StudioStyle.secondaryText
        let polarityGlass = StudioStyle.glassControl(polarity)
        let sensitivityGlass = StudioStyle.glassControl(horizontal([sensitivity, sensitivityValue], spacing: 8))
        let parameters = horizontal([
            vertical([label(L10n.text("灰尘类型"), size: 12, weight: .medium), polarityGlass], spacing: 6),
            vertical([label(L10n.text("灵敏度"), size: 12, weight: .medium), sensitivityGlass], spacing: 6)
        ])
        let detectorChoices = detectors.map { StudioStyle.checkboxControl($0.checkbox) }
        let detectionRow = horizontal([label(L10n.text("识别项目"), size: 12, weight: .medium)] + detectorChoices + [detectionHint], spacing: 8)
        let settingsContent = vertical([StudioStyle.section("02", L10n.text("检测设置")), parameters, detectionRow, outputRow], spacing: 12)
        let settingsCard = card(settingsContent)
        outputRow.widthAnchor.constraint(equalTo: settingsContent.widthAnchor).isActive = true

        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.maximumNumberOfLines = 3
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = StudioStyle.secondaryText
        detail.maximumNumberOfLines = 3
        let progressContent = vertical([StudioStyle.section("03", L10n.text("处理状态")), status, progress, detail], spacing: 8)
        progress.widthAnchor.constraint(equalTo: progressContent.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: progressContent.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: progressContent.widthAnchor).isActive = true
        let progressCard = card(progressContent)

        startButton.target = self
        startButton.action = #selector(start)
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 145).isActive = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.isEnabled = false
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.isEnabled = false
        let actions = horizontal([
            StudioStyle.actionControl(revealButton), NSView(), StudioStyle.actionControl(cancelButton),
            StudioStyle.actionControl(startButton)
        ], spacing: 10)
        let actionPanel = GlassPanel(material: .headerView, radius: 12)
        actionPanel.place(actions, vertical: 8)
        let main = vertical([header, sourceCard, settingsCard, progressCard, actionPanel], spacing: 14)
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            main.topAnchor.constraint(equalTo: layout.topAnchor, constant: 20),
            main.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24)
        ])
        for view in [header, sourceCard, settingsCard, progressCard, actionPanel] { view.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true }
        progressCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 106).isActive = true
    }

    private var inputSource: InputSource { InputSource(rawValue: mode.selectedSegment) ?? .file }

    @objc private func modeChanged() {
        fileRow.isHidden = inputSource != .file
        photoRow.isHidden = inputSource == .file
        outputRow?.isHidden = inputSource != .photoCraft
        switch inputSource {
        case .file:
            sourceNote.stringValue = Self.fileSourceNote
            startButton.title = selectedInputs.count > 1 ? L10n.text("打开观片台") : L10n.text("检测并预览")
        case .photoCraft:
            connection.stringValue = photoCraftConnection
            connectButton.title = L10n.text("启动 / 连接 PhotoCraft")
            sourceNote.stringValue = L10n.text("先预览并审核，确认后才向 PhotoCraft 添加修复图层和可编辑蒙版。")
            startButton.title = L10n.text("预览当前照片")
        case .photoshop:
            connection.stringValue = L10n.text("在 Photoshop 打开照片，再载入当前文档的可见图像。")
            connectButton.title = L10n.text("打开 Photoshop")
            sourceNote.stringValue = L10n.text("在 PURE Neg 审核后，可保存为 TIFF、JPEG 或 PNG。")
            startButton.title = L10n.text("载入并预览")
        }
    }

    @objc private func sensitivityChanged() { sensitivityValue.stringValue = String(format: "%.2f", sensitivity.doubleValue) }

    private var selectedDetectors: [String] {
        detectors.compactMap { $0.checkbox.state == .on ? $0.kind.rawValue : nil }
    }

    @objc private func updateDetectionAvailability() {
        let hasSelection = !selectedDetectors.isEmpty
        startButton.isEnabled = process == nil && !importingPhotoshop && reviewController == nil && batch == nil && hasSelection
        detectionHint.stringValue = hasSelection ? L10n.text("可单独或组合勾选。") : L10n.text("请至少勾选一项。")
        detectionHint.textColor = hasSelection ? StudioStyle.secondaryText : .labelColor
    }

    @objc private func selectInput() {
        guard process == nil, !importingPhotoshop, reviewController == nil, batch == nil else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择 TIFF 或 JPEG")
        panel.allowedContentTypes = [.tiff, .jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let first = panel.urls.first else { return }
            var seen = Set<URL>()
            self.selectedInputs = panel.urls.filter { seen.insert($0.standardizedFileURL).inserted }.sorted {
                let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
            }
            self.inputPath.stringValue = self.selectedInputs.count == 1
                ? first.path : L10n.text("已选择 \(self.selectedInputs.count) 张照片")
            self.inputPath.toolTip = self.selectedInputs.map(\.path).joined(separator: "\n")
            self.inputPath.textColor = .labelColor
            self.modeChanged()
        }
    }

    @objc private func selectOutput() {
        guard process == nil else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择结果保存目录")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: selectedOutput.path) ? selectedOutput : selectedOutput.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.selectedOutput = url
            self.outputPath.stringValue = url.path
            self.outputPath.toolTip = url.path
        }
    }

    @objc private func selectReview() {
        guard process == nil, !importingPhotoshop, reviewController == nil, batch == nil else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择待审核的记录")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.launch(command: "inspect-review", arguments: ["--review", url.path])
        }
    }

    @objc private func connect() {
        if inputSource == .photoshop {
            do { try PhotoshopImport.open() }
            catch { showPhotoshopError(error) }
        } else {
            launch(command: "doctor", arguments: ["--launch"])
        }
    }

    @objc private func start() {
        guard process == nil, !importingPhotoshop, batch == nil else { return }
        if let review = reviewController { review.present(); return }
        let detect = selectedDetectors
        guard !detect.isEmpty else { return }
        var args = [
            "--output", selectedOutput.path,
            "--polarity", ["auto", "bright", "dark"][max(0, min(2, polarity.indexOfSelectedItem))],
            "--sensitivity", String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), sensitivity.doubleValue),
            "--detect", detect.joined(separator: ",")
        ]
        switch inputSource {
        case .file:
            guard let input = selectedInputs.first else {
                status.stringValue = L10n.text("请先选择 TIFF 或 JPEG")
                selectInput()
                return
            }
            if selectedInputs.count > 1 {
                beginBatch(arguments: args)
                return
            }
            args += ["--input", input.path]
            launch(command: "prepare", arguments: args)
        case .photoCraft:
            launch(command: "prepare-photocraft", arguments: args)
        case .photoshop:
            preparePhotoshop(arguments: args)
        }
    }

    private func preparePhotoshop(arguments: [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pureneg-photoshop-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            showPhotoshopError(error)
            return
        }
        importingPhotoshop = true
        setBusy(true)
        progress.doubleValue = 0
        status.textColor = .labelColor
        status.stringValue = L10n.text("正在载入 Photoshop 文档…")
        detail.stringValue = L10n.text("首次载入时，macOS 可能会请你允许 PURE Neg 与 Photoshop 通信。")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try PhotoshopImport.snapshot(in: directory) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.importingPhotoshop = false
                switch result {
                case .success(let snapshot):
                    self.photoshopSnapshotDirectory = directory
                    self.launch(command: "prepare", arguments: arguments + ["--input", snapshot.url.path, "--source-name", "./" + snapshot.name])
                    if self.process == nil {
                        self.removePhotoshopSnapshot()
                        self.setBusy(false)
                    }
                case .failure(let error):
                    if !PhotoshopImport.didTimeOut(error) { self.removeTemporary(directory) }
                    self.setBusy(false)
                    self.showPhotoshopError(error)
                }
            }
        }
    }

    private func removePhotoshopSnapshot() {
        guard let directory = photoshopSnapshotDirectory else { return }
        photoshopSnapshotDirectory = nil
        removeTemporary(directory)
    }

    private func showPhotoshopError(_ error: Error) {
        status.stringValue = L10n.text("无法从 Photoshop 载入")
        status.textColor = .labelColor
        detail.stringValue = error.localizedDescription
    }

    private func beginBatch(arguments: [String]) {
        do {
            let batch = try BatchSession(urls: selectedInputs, detectionArguments: arguments)
            self.batch = batch
            batch.controller.onSelect = { [weak self] in self?.toggleBatchPick($0) }
            batch.controller.onNext = { [weak self] in self?.beginBatchReview() }
            batch.controller.onReturn = { [weak self] in self?.leaveBatch() }
            refreshBatch()
            batch.controller.present(from: window)
            window.orderOut(nil)
            setBusy(false)
        } catch {
            fail(L10n.text("无法创建批处理工作区：\(error.localizedDescription)"))
        }
    }

    private func refreshBatch() {
        guard let batch else { return }
        let items = batch.frames.map { frame in
            let label: String
            if let job = batch.job, job.id == frame.id, batch.detectionWorker != .yielding {
                if job.isBackground {
                    label = batch.detectionWorker == .running ? L10n.surface("后台检测中") : L10n.surface("后台检测已暂停")
                } else {
                    label = batch.export == nil ? L10n.text("检测中") : L10n.text("导出中")
                }
            } else if frame.displaysExport {
                label = L10n.text("已导出")
            } else if frame.error != nil {
                label = frame.session != nil ? L10n.text("导出失败") : L10n.text("检测失败")
            } else if frame.session != nil {
                label = frame.hasEdits || frame.revisingExport ? L10n.text("有未导出的修整") : L10n.text("待审核")
            } else {
                label = batch.includes(frame.id) ? L10n.text("待检测") : L10n.text("未选入本批")
            }
            return BatchLightTableItem(id: frame.id, url: frame.url, status: label,
                                       selected: batch.picked.contains(frame.id))
        }
        guard let review = reviewController else {
            batch.controller.update(items: items, status: batch.status, busy: batch.isBusy || process != nil)
            return
        }
        guard let sidebar = review.batchSidebar else { return }
        let backgroundJob = batch.job?.isBackground == true
        let busy = batch.hasForegroundWork || (process != nil && !backgroundJob) || previewNeedsRefresh
        let canStop = batch.reviewAfterDetection != nil
            || (!wasCancelled && batch.detectingID != nil && batch.detectionWorker != .yielding)
        let canSelect = canSelectBatchFrame(batch)
        let rows = zip(batch.frames, items).enumerated().compactMap { index, pair -> BatchReviewSidebar.Item? in
            let (frame, item) = pair
            guard batch.includes(frame.id) else { return nil }
            return BatchReviewSidebar.Item(id: frame.id, url: frame.url, number: index + 1,
                                           name: frame.url.lastPathComponent, status: item.status,
                                           isCurrent: frame.id == (batch.reviewAfterDetection ?? batch.current),
                                           canExport: canExportBatchFrame(frame, in: batch), canOpen: canSelect)
        }
        sidebar.update(items: rows, checked: batch.exportChecked, busy: busy)
        let detectingID = batch.detectionWorker == .yielding ? nil : batch.detectingID
        sidebar.setDetectionProgress(id: detectingID, fraction: batch.detectionProgress, follow: !backgroundJob)
        let activity: String
        if backgroundJob, !batch.hasForegroundWork, let id = batch.detectingID, let index = batch.index(for: id) {
            let filename = batch.frames[index].url.lastPathComponent
            switch batch.detectionWorker {
            case .running: activity = batch.backgroundStatus
            case .paused: activity = "\(filename) · " + L10n.surface("后台检测已暂停")
            case .yielding: activity = L10n.surface("正在暂停后台检测…")
            }
        } else if batch.status.isEmpty, batch.allowsBackgroundDetection, batch.nextBackgroundFrame != nil {
            activity = L10n.surface("闲置后将自动检测其余照片。")
        } else {
            activity = batch.status
        }
        sidebar.setActivity(activity, canDetect: !busy && !backgroundJob && batch.scope.contains { $0.session == nil }, canStop: canStop)
        let canExportCurrent = !busy && batch.current.flatMap { batch.index(for: $0) }
            .map { batch.frames[$0].canExport } == true
        review.setBatchState(locked: batch.reviewLocked, canReturn: !batch.hasForegroundWork,
                             canExportCurrent: canExportCurrent, status: batch.status,
                             detectingCurrent: batch.reviewAfterDetection != nil)
    }

    private func canBrowseBatch(_ batch: BatchSession) -> Bool {
        !batch.hasForegroundWork && !previewNeedsRefresh && (process == nil || batch.job?.isBackground == true)
    }

    private func canSelectBatchFrame(_ batch: BatchSession) -> Bool {
        guard batch.export == nil, !batch.choosingExport else { return false }
        return batch.reviewAfterDetection != nil || batch.detectingID != nil || canBrowseBatch(batch)
    }

    private func observeBatchActivity() {
        lastBatchActivity = ProcessInfo.processInfo.systemUptime
        reviewController?.window?.acceptsMouseMovedEvents = true
        let input: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .keyDown, .keyUp, .scrollWheel, .magnify, .rotate, .swipe, .pressure, .tabletPoint
        ]
        batchActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: input) { [weak self] event in
            self?.noteBatchActivity()
            return event
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.advanceIdleDetection() }
        timer.tolerance = 0.05
        batchIdleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopObservingBatchActivity() {
        if let batchActivityMonitor { NSEvent.removeMonitor(batchActivityMonitor) }
        batchActivityMonitor = nil
        batchIdleTimer?.invalidate()
        batchIdleTimer = nil
    }

    private func noteBatchActivity() {
        lastBatchActivity = ProcessInfo.processInfo.systemUptime
        if let batch { pauseBackgroundDetection(batch) }
    }

    private func advanceIdleDetection() {
        guard let batch, let review = reviewController else { return }
        guard batch.allowsBackgroundDetection else { cancelBackgroundDetection(batch); return }
        guard !batch.hasForegroundWork, !previewNeedsRefresh,
              NSApp.modalWindow == nil, review.window?.attachedSheet == nil,
              NSEvent.pressedMouseButtons == 0,
              review.session == nil || review.canvas.isDisplayReady else {
            pauseBackgroundDetection(batch)
            return
        }
        guard ProcessInfo.processInfo.systemUptime - lastBatchActivity >= AppPreferences.idleDetectionDelay else { return }
        if batch.job?.isBackground == true {
            if batch.detectionWorker == .paused, signalBackgroundWorker(SIGCONT) {
                batch.detectionWorker = .running
                refreshBatch()
            }
        } else if process == nil, batch.nextBackgroundFrame != nil {
            startNextBatchJob(allowBackground: true)
        }
    }

    private func signalBackgroundWorker(_ signal: Int32) -> Bool {
        guard let process, process.isRunning else { return false }
        let pid = process.processIdentifier
        // Foundation creates a process group for each worker. Its JPEG codec
        // inherits the group and must pause and resume with the detector.
        return pid > 1 && getpgid(pid) == pid && kill(-pid, signal) == 0
    }

    private func pauseBackgroundDetection(_ batch: BatchSession) {
        guard batch.job?.isBackground == true, batch.detectionWorker == .running,
              signalBackgroundWorker(SIGSTOP) else { return }
        batch.detectionWorker = .paused
        refreshBatch()
    }

    private func cancelBackgroundDetection(_ batch: BatchSession) {
        guard batch.job?.isBackground == true, batch.detectionWorker != .yielding else { return }
        yieldDetection(batch)
        refreshBatch()
    }

    private func yieldDetection(_ batch: BatchSession) {
        guard batch.detectingID != nil, batch.detectionWorker != .yielding, let process else { return }
        let paused = batch.detectionWorker == .paused
        batch.detectionWorker = .yielding
        if paused { _ = signalBackgroundWorker(SIGCONT) }
        if process.isRunning { process.terminate() }
    }

    private func toggleBatchPick(_ id: UUID) {
        guard let batch, reviewController == nil, !batch.isBusy, batch.index(for: id) != nil else { return }
        if !batch.picked.insert(id).inserted { batch.picked.remove(id) }
        refreshBatch()
    }

    private func makeBatchSidebar() -> BatchReviewSidebar {
        let sidebar = BatchReviewSidebar()
        sidebar.onOpen = { [weak self] in self?.selectBatchFrame($0) }
        sidebar.onToggle = { [weak self] in self?.toggleBatchExport($0) }
        sidebar.onExport = { [weak self] in self?.chooseBatchExport($0) }
        sidebar.onDetect = { [weak self] in self?.detectBatch() }
        sidebar.onStop = { [weak self] in self?.stopBatchDetection() }
        return sidebar
    }

    private func beginBatchReview() {
        guard let batch, reviewController == nil, process == nil, !batch.isBusy,
              let first = batch.scope.first else { return }
        do {
            let review = try ReviewWindowController(session: nil, batchSidebar: makeBatchSidebar())
            let onClose: () -> Void = { [weak self] in self?.returnToLightTable() }
            review.onDiscard = onClose
            review.onFinish = onClose
            review.onExportCurrent = { [weak self, weak batch] in
                guard let id = batch?.current else { return }
                self?.chooseBatchExport([id])
            }
            review.onPreviewReady = { [weak self] in self?.refreshBatch() }
            review.onEditsChange = { [weak self, weak batch] in
                guard let self, let batch, self.batch === batch, let id = batch.current,
                      let index = batch.index(for: id) else { return }
                batch.frames[index].revisingExport = batch.frames[index].output != nil
                batch.frames[index].error = nil
                self.batchReviewEdited = true
                self.schedulePreview()
                self.refreshBatch()
            }
            reviewController = review
            batch.status = ""
            observeBatchActivity()
            selectBatchFrame(first.id)
            review.present(from: batch.controller.window)
            batch.controller.window?.orderOut(nil)
        } catch {
            batch.status = error.localizedDescription
            refreshBatch()
        }
    }

    private func selectBatchFrame(_ id: UUID) {
        guard let batch, canSelectBatchFrame(batch), batch.includes(id),
              (batch.reviewAfterDetection ?? batch.current) != id, batch.index(for: id) != nil else { return }
        noteBatchActivity()
        openBatchReview(id)
    }

    private func detectBatch() {
        guard let batch, reviewController != nil, process == nil, !batch.hasForegroundWork, !previewNeedsRefresh else { return }
        for index in batch.frames.indices where batch.includes(batch.frames[index].id) && batch.frames[index].session == nil {
            batch.frames[index].error = nil
        }
        guard batch.nextBackgroundFrame != nil else {
            batch.status = L10n.text("检测已完成，点选照片进入审核。")
            refreshBatch()
            return
        }
        batch.backgroundMode = .requested
        startNextBatchJob(allowBackground: true)
    }

    private func stopBatchDetection() {
        guard let batch else { return }
        batch.backgroundMode = .stopped
        batch.reviewAfterDetection = nil
        if batch.detectingID != nil, batch.job?.isBackground == false {
            wasCancelled = true
            batch.status = L10n.text("正在停止检测…")
        } else {
            batch.status = L10n.text("已停止检测。可继续审核已完成的照片。")
        }
        yieldDetection(batch)
        refreshBatch()
    }

    private func canExportBatchFrame(_ frame: BatchFrame, in batch: BatchSession) -> Bool {
        frame.canExport && (frame.id != batch.current || reviewController?.hasExportablePreview == true)
    }

    private func toggleBatchExport(_ id: UUID) {
        guard let batch, batch.includes(id), !batch.hasForegroundWork, !previewNeedsRefresh,
              process == nil || batch.job?.isBackground == true,
              let index = batch.index(for: id), canExportBatchFrame(batch.frames[index], in: batch) else { return }
        noteBatchActivity()
        if !batch.exportChecked.insert(id).inserted { batch.exportChecked.remove(id) }
        refreshBatch()
    }

    private func chooseBatchExport(_ requested: Set<UUID>) {
        guard let batch, !batch.hasForegroundWork, !previewNeedsRefresh,
              process == nil || batch.job?.isBackground == true,
              let host = reviewController?.window else { return }
        let ids = batch.scope.filter { requested.contains($0.id) && canExportBatchFrame($0, in: batch) }.map(\.id)
        guard !ids.isEmpty else { return }
        noteBatchActivity()
        storeBatchEdits(batch)
        let panel = NSOpenPanel()
        panel.title = ids.count == 1 ? L10n.text("导出照片") : L10n.text("导出 \(ids.count) 张照片")
        panel.message = L10n.text("请选择保存目录和导出格式。")
        panel.prompt = L10n.text("导出")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let suggestedFolder = AppPreferences.exportFolder ?? selectedOutput
        panel.directoryURL = FileManager.default.fileExists(atPath: suggestedFolder.path)
            ? suggestedFolder : suggestedFolder.deletingLastPathComponent()
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: ReviewExportFormat.allCases.map(\.label))
        format.selectItem(withTitle: AppPreferences.exportFormat.uppercased())
        format.setAccessibilityLabel(L10n.text("批量导出格式"))
        let formatRow = NSStackView(views: [NSTextField(labelWithString: L10n.text("导出格式")), format])
        formatRow.spacing = 8
        let mask = NSButton(checkboxWithTitle: L10n.text("附带修复蒙版"), target: nil, action: nil)
        mask.state = AppPreferences.includeMask ? .on : .off
        let options = NSStackView(views: [formatRow, mask])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 8
        options.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        options.frame.size = options.fittingSize
        panel.accessoryView = options
        panel.isAccessoryViewDisclosed = true
        batch.choosingExport = true
        refreshBatch()
        panel.beginSheetModal(for: host) { [weak self, weak batch] response in
            guard let self, let batch, self.batch === batch else { return }
            self.noteBatchActivity()
            batch.choosingExport = false
            guard response == .OK, let folder = panel.url else { self.refreshBatch(); return }
            self.selectedOutput = folder
            self.outputPath.stringValue = folder.path
            self.outputPath.toolTip = folder.path
            batch.export = BatchSession.Export(folder: folder,
                                               format: ReviewExportFormat.allCases[format.indexOfSelectedItem],
                                               includeMask: mask.state == .on, pending: ids)
            self.cancelBackgroundDetection(batch)
            self.startNextBatchJob()
        }
    }

    private func startNextBatchJob(allowBackground: Bool = false) {
        guard let batch, process == nil, batch.job == nil else { return }
        if previewNeedsRefresh {
            if previewDebounce == nil { startPreviewIfReady() }
            return
        }
        reportedError = nil
        if let export = batch.export {
            guard let id = export.pending.first else {
                batch.export = nil
                let failures = export.failed == 0 ? "" : L10n.text(" · \(export.failed) 张可重试")
                batch.status = L10n.text("已导出 \(export.saved) 张\(failures) · \(export.folder.path)")
                refreshBatch()
                return
            }
            batch.export?.pending.removeFirst()
            guard let index = batch.index(for: id), let session = batch.frames[index].session else { return }
            let frame = batch.frames[index]
            batch.job = .export(id)
            batch.frames[index].error = nil
            batch.status = L10n.text("正在导出 \(frame.url.lastPathComponent)…")
            do {
                let edits = try editsFile(excludedRegions: frame.excludedRegions, strokes: frame.strokes)
                activeEditsFile = edits
                launch(command: "confirm", arguments: ["--review", session.path, "--edits", edits.path,
                       "--format", export.format.rawValue, "--output", export.folder.path,
                       "--mask", export.includeMask ? "yes" : "no", "--revise-export"])
            } catch {
                reportedError = error.localizedDescription
            }
        } else {
            let background = batch.reviewAfterDetection == nil
            let idleID = allowBackground && batch.allowsBackgroundDetection ? batch.nextBackgroundFrame?.id : nil
            guard let id = batch.reviewAfterDetection ?? idleID else { return }
            guard let index = batch.index(for: id) else { return }
            batch.job = .prepare(id, background: background)
            batch.detectionWorker = .running
            batch.detectionProgress = nil
            batch.frames[index].error = nil
            let url = batch.frames[index].url
            if background {
                batch.backgroundStatus = "\(url.lastPathComponent) · " + L10n.surface("后台检测中")
            } else {
                batch.status = L10n.text("正在检测 \(url.lastPathComponent)…")
            }
            launch(command: "prepare", arguments: batch.detectionArguments + ["--input", url.path])
        }
        if process == nil, let job = batch.job {
            if let edits = activeEditsFile {
                activeEditsFile = nil
                removeTemporary(edits)
            }
            finishBatchJob(batch, job: job, code: 1, errorLog: reportedError ?? status.stringValue)
        } else {
            refreshBatch()
        }
    }

    private func applyBatchEvent(_ event: [String: Any], batch: BatchSession, job: BatchSession.Job) {
        guard !wasCancelled, let index = batch.index(for: job.id) else { return }
        let filename = batch.frames[index].url.lastPathComponent
        switch event["type"] as? String {
        case "progress":
            guard batch.detectionWorker == .running else { return }
            let fraction = (event["fraction"] as? Double).flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            if case .prepare = job, let fraction { batch.detectionProgress = fraction }
            if let message = event["message"] as? String {
                let percent = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                let status = "\(filename) · \(message)\(percent)"
                if job.isBackground { batch.backgroundStatus = status }
                else { batch.status = status }
            }
            refreshBatch()
        case "error":
            reportedError = event["message"] as? String ?? L10n.text("处理失败")
        case "review":
            guard case .prepare = job else { return }
            do {
                let session = try ReviewSession(event: event)
                guard session.context == "file" else { throw CocoaError(.fileReadCorruptFile) }
                batch.jobReview = session
            } catch {
                reportedError = error.localizedDescription
            }
        case "result":
            guard case .export = job, let paths = event["paths"] as? [String: String],
                  let path = paths["cleaned"], path.hasPrefix("/") else { return }
            batch.jobOutput = URL(fileURLWithPath: path)
            if let session = batch.frames[index].session {
                batch.jobRasters = confirmedRasters(from: event, session: session)
            }
        default: break
        }
    }

    private func finishBatchJob(_ batch: BatchSession, job: BatchSession.Job, code: Int32, errorLog: String) {
        guard self.batch === batch, let index = batch.index(for: job.id) else { return }
        let review = batch.jobReview
        let output = batch.jobOutput
        let yielded = batch.detectionWorker == .yielding
        batch.job = nil
        batch.detectionWorker = .running
        batch.backgroundStatus = ""
        batch.jobReview = nil
        batch.jobOutput = nil
        batch.detectionProgress = nil
        let cancelled = wasCancelled
        wasCancelled = false
        if !job.isBackground { noteBatchActivity() }
        let error = reportedError ?? (errorLog.isEmpty ? L10n.text("引擎未返回结果。") : String(errorLog.suffix(1000)))
        switch job {
        case .prepare(let id, _):
            let shouldOpen = batch.reviewAfterDetection == id
            if shouldOpen && (!yielded || (!cancelled && code == 0 && review != nil)) { batch.reviewAfterDetection = nil }
            if cancelled {
                if batch.reviewAfterDetection == nil && batch.current == nil {
                    batch.status = L10n.text("已停止检测。可继续审核已完成的照片。")
                }
            } else if code == 0, let review {
                batch.frames[index].session = review
                if shouldOpen && reviewController != nil {
                    openBatchReview(id)
                } else if batch.reviewAfterDetection == nil && !yielded {
                    let scope = batch.scope
                    let detected = scope.filter { $0.session != nil }.count
                    let failed = scope.filter { $0.session == nil && $0.error != nil }.count
                    batch.status = L10n.text("本批已检测 \(detected)/\(scope.count) 张") + (failed == 0 ? "" : L10n.text(" · \(failed) 张失败，可重试"))
                }
            } else if !yielded {
                batch.frames[index].error = error
                batch.status = "\(batch.frames[index].url.lastPathComponent) · \(error)"
            }
        case .export:
            defer { batch.jobRasters = nil }
            if let output, FileManager.default.fileExists(atPath: output.path) {
                batch.frames[index].output = output
                batch.frames[index].exportedRasters = batch.jobRasters
                batch.frames[index].exportedWithMask = batch.export?.includeMask == true
                batch.frames[index].revisingExport = false
                batch.exportChecked.remove(job.id)
                batch.export?.saved += 1
                if batch.current == job.id {
                    reviewController?.showSavedResult(file: output, directory: output.deletingLastPathComponent(),
                                                     includedMask: batch.export?.includeMask == true)
                }
            } else {
                batch.frames[index].error = error
                batch.export?.failed += 1
                batch.status = "\(batch.frames[index].url.lastPathComponent) · \(error)"
            }
        }
        refreshBatch()
        DispatchQueue.main.async { [weak self, weak batch] in
            guard let self, let batch, self.batch === batch else { return }
            self.startNextBatchJob()
        }
    }

    private func openBatchReview(_ id: UUID) {
        guard let batch, let review = reviewController, let index = batch.index(for: id) else { return }
        let frame = batch.frames[index]
        do {
            storeBatchEdits(batch)
            try review.setBatchPhoto(frame, loadingThumbnail: batch.controller.cachedThumbnail(for: frame.url))
            resetReviewPreview()
            if frame.session != nil {
                batch.current = id
                batch.reviewAfterDetection = nil
                batch.status = ""
                if batch.job?.isBackground == false { yieldDetection(batch) }
                if frame.hasEdits && (!frame.displaysExport || frame.exportedRasters == nil) { schedulePreview() }
            } else {
                batch.current = nil
                batch.reviewAfterDetection = id
                if let detectingID = batch.detectingID {
                    if detectingID == id, batch.detectionWorker != .yielding {
                        if batch.job?.isBackground == true {
                            if batch.detectionWorker == .paused { _ = signalBackgroundWorker(SIGCONT) }
                            batch.detectionWorker = .running
                            batch.job = .prepare(id, background: false)
                            batch.status = batch.backgroundStatus
                        }
                    } else {
                        batch.status = L10n.text("正在切换到 \(frame.url.lastPathComponent)…")
                        yieldDetection(batch)
                    }
                } else {
                    startNextBatchJob()
                }
            }
            refreshBatch()
        } catch {
            batch.status = L10n.text("无法打开 \(frame.url.lastPathComponent) 的审核：\(error.localizedDescription)")
            refreshBatch()
        }
    }

    private func storeBatchEdits(_ batch: BatchSession) {
        guard let id = batch.current, let index = batch.index(for: id), let review = reviewController else { return }
        batch.frames[index].excludedRegions = review.excludedRegions
        batch.frames[index].strokes = review.strokes
        batchReviewEdited = false
    }

    private func returnToLightTable() {
        guard let batch, reviewController != nil, !batch.hasForegroundWork else { return }
        stopObservingBatchActivity()
        cancelBackgroundDetection(batch)
        storeBatchEdits(batch)
        resetReviewPreview()
        reviewController = nil
        batch.current = nil
        batch.status = ""
        refreshBatch()
        batch.controller.present()
    }

    private func confirmLeavingBatch() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.text("还有审核结果未导出")
        alert.informativeText = L10n.text("离开后会清除本次批次的审核进度和手动修整。")
        alert.addButton(withTitle: L10n.text("留在当前批次"))
        alert.addButton(withTitle: L10n.text("离开批次"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func leaveBatch() {
        guard let batch, reviewController == nil, process == nil, !batch.isBusy,
              !batch.hasUnsavedReview || confirmLeavingBatch() else { return }
        self.batch = nil
        selectedInputs = []
        inputPath.stringValue = Self.chooseInputHint
        inputPath.toolTip = nil
        inputPath.textColor = StudioStyle.secondaryText
        status.stringValue = L10n.text("准备就绪")
        status.textColor = .labelColor
        detail.stringValue = Self.waitingDetail
        progress.doubleValue = 0
        modeChanged()
        setBusy(false)
        showMainWindow()
        batch.controller.window?.orderOut(nil)
        removeTemporary(batch.workDirectory)
    }

    private func setBusy(_ busy: Bool) {
        let blocked = busy || importingPhotoshop || reviewController != nil || batch != nil
        mode.isEnabled = !blocked
        chooseButton.isEnabled = !blocked
        folderButton.isEnabled = !blocked
        connectButton.isEnabled = !blocked
        polarity.isEnabled = !blocked
        sensitivity.isEnabled = !blocked
        for detector in detectors { detector.checkbox.isEnabled = !blocked }
        startButton.isEnabled = !blocked && !selectedDetectors.isEmpty
        cancelButton.isEnabled = busy && process != nil && taskKind != "confirm" && taskKind != "preview"
    }

    private func launch(command: String, arguments: [String]) {
        guard process == nil else { return }
        guard let resources = Bundle.main.resourceURL else { fail(L10n.text("找不到应用资源，请重新构建应用。")); return }
        let node = resources.appendingPathComponent("runtime/node")
        let cli = resources.appendingPathComponent("src/cli.cjs")
        guard FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.fileExists(atPath: cli.path) else {
            fail(L10n.text("应用文件不完整，请使用 build-macos.sh 重新构建。"))
            return
        }
        let worker = Process()
        let out = Pipe()
        let err = Pipe()
        worker.executableURL = node
        worker.arguments = [cli.path, command] + arguments + (batch.map { ["--work-dir", $0.workDirectory.path] } ?? [])
        switch AppPreferences.cpuMode {
        case "responsive": worker.qualityOfService = .userInitiated
        case "efficient": worker.qualityOfService = .background
        default:
            if command == "prepare" || command == "prepare-photocraft" || command == "preview" {
                worker.qualityOfService = .utility
            }
        }
        if batch?.job?.isBackground == true, AppPreferences.cpuMode != "efficient" {
            worker.qualityOfService = .utility
        }
        worker.currentDirectoryURL = resources
        var env = ProcessInfo.processInfo.environment
        env["NODE_NO_WARNINGS"] = "1"
        env["LANG"] = AppPreferences.language == "en" ? "en_US.UTF-8" : "zh_CN.UTF-8"
        env["PURENEG_LANGUAGE"] = AppPreferences.language
        env["PURENEG_CONSERVE_MEMORY"] = AppPreferences.conserveMemory ? "1" : "0"
        worker.environment = env
        worker.standardOutput = out
        worker.standardError = err
        stdoutBuffer = Data()
        stderrText = ""
        sawResult = false
        wasCancelled = false
        reportedError = nil
        taskKind = command
        process = worker
        workerStartedAt = Date()
        setBusy(true)
        progress.doubleValue = 0
        status.textColor = .labelColor
        status.stringValue = command == "doctor" ? L10n.text("正在连接 PhotoCraft…") : L10n.text("正在准备扫描件…")
        if command == "doctor" { detail.stringValue = L10n.text("将在本机启动或连接 PhotoCraft 专用会话。") }
        else if command == "confirm" { detail.stringValue = L10n.text("正在保存已确认的修复结果，请稍等。") }
        else if command == "preview" { detail.stringValue = L10n.text("正在按您的选择更新预览，尚未保存最终结果。") }
        else { detail.stringValue = L10n.text("大幅扫描件可能需要几分钟。完成后请在审核窗口确认。") }
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.readQueue.async { [weak self] in self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.readQueue.async { [weak self] in
                guard let self = self else { return }
                self.stderrText += String(decoding: data, as: UTF8.self)
                if self.stderrText.utf8.count > 32768 { self.stderrText = String(self.stderrText.suffix(16000)) }
            }
        }
        worker.terminationHandler = { [weak self] completed in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let remaining = out.fileHandleForReading.readDataToEndOfFile()
            let remainingError = err.fileHandleForReading.readDataToEndOfFile()
            self?.readQueue.async { [weak self] in
                guard let self = self else { return }
                self.consume(remaining)
                if !self.stdoutBuffer.isEmpty { self.consumeLine(self.stdoutBuffer); self.stdoutBuffer.removeAll(keepingCapacity: false) }
                self.stderrText += String(decoding: remainingError, as: UTF8.self)
                let errorLog = self.stderrText
                DispatchQueue.main.async { [weak self] in self?.finished(code: completed.terminationStatus, errorLog: errorLog) }
            }
        }
        do { try worker.run() }
        catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            process = nil
            workerStartedAt = nil
            AppDiagnostics.record(operation: command, code: -1, duration: 0)
            setBusy(false)
            fail(L10n.text("无法启动除尘引擎：\(error.localizedDescription)"))
        }
    }

    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        guard stdoutBuffer.count <= 32_000_000 else {
            stdoutBuffer.removeAll(keepingCapacity: false)
            DispatchQueue.main.async { [weak self] in self?.reportedError = L10n.text("引擎返回了过大的状态信息。") }
            return
        }
        while let newline = stdoutBuffer.firstIndex(of: 10) {
            let line = stdoutBuffer.subdata(in: 0..<newline)
            stdoutBuffer.removeSubrange(0...newline)
            consumeLine(line)
        }
    }

    private func consumeLine(_ line: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in self?.apply(event) }
    }

    private func apply(_ event: [String: Any]) {
        if let batch, let job = batch.job {
            applyBatchEvent(event, batch: batch, job: job)
            return
        }
        switch event["type"] as? String {
        case "progress":
            if let value = event["fraction"] as? Double, value.isFinite {
                progress.doubleValue = max(0, min(1, value))
                // The brief import stage commits a complete layer and mask.
                // Once it starts, let the worker finish that transaction.
                if taskKind == "confirm" && value >= 0.95 { cancelButton.isEnabled = false }
            }
            if let message = event["message"] as? String { status.stringValue = message }
        case "error":
            if taskKind == "preview" && activePreviewGeneration != previewGeneration { return }
            let message = event["message"] as? String ?? L10n.text("处理失败")
            reportedError = message
            fail(message)
            if taskKind == "preview" { reviewController?.setPreviewPending(true, error: message) }
            if taskKind == "confirm" {
                reviewController?.setWorking(false)
                reviewController?.setPreviewPending(false, error: message)
            }
        case "review":
            sawResult = true
            do {
                let session = try ReviewSession(event: event)
                let controller = try ReviewWindowController(session: session)
                controller.onConfirm = { [weak self] folder, includeMask in
                    self?.confirmReview(folder: folder, includeMask: includeMask)
                }
                controller.onDiscard = { [weak self] in self?.discardReview() }
                controller.onFinish = { [weak self] in self?.finishReview() }
                controller.onEditsChange = { [weak self] in self?.schedulePreview() }
                reviewController = controller
                inputPath.stringValue = "\(session.sourceName) · \(session.width) × \(session.height)"
                inputPath.toolTip = session.sourcePath
                inputPath.textColor = .labelColor
                if let root = session.outputRoot {
                    selectedOutput = URL(fileURLWithPath: root, isDirectory: true)
                    outputPath.stringValue = root
                    outputPath.toolTip = root
                }
                if photoshopSnapshotDirectory == nil {
                    mode.selectedSegment = (session.context == "photocraft" ? InputSource.photoCraft : .file).rawValue
                }
                modeChanged()
                previewGeneration += 1
                previewNeedsRefresh = false
                status.stringValue = L10n.text("检测完成 · \(session.regions.count) 处待审核")
                detail.stringValue = L10n.text("请在预览窗口逐处检查。确认前不会保存最终结果或导回 PhotoCraft。")
                progress.doubleValue = 1
                controller.setPreviewPending(true)
                controller.present(from: window)
                window.orderOut(nil)
            } catch {
                reportedError = error.localizedDescription
                fail(L10n.text("无法打开预览：\(error.localizedDescription)"))
            }
        case "preview":
            sawResult = true
            guard taskKind == "preview", let reviewPath = activePreviewReviewPath else { return }
            guard let path = event["cleanedPath"] as? String, let mask = event["maskPath"] as? String,
                  let directory = previewDirectory(cleaned: path, mask: mask, review: reviewPath) else {
                reportedError = L10n.text("引擎返回了无效的预览文件路径。")
                return
            }
            guard activePreviewGeneration == previewGeneration, let review = reviewController else {
                removeTemporary(directory)
                return
            }
            do {
                try review.updateCleanedImage(path, maskPath: mask, stats: event["stats"] as? [String: Any] ?? [:])
                if let old = currentPreviewDirectory, old != directory { removeTemporary(old) }
                currentPreviewDirectory = directory
                previewWasApplied = true
            } catch {
                if currentPreviewDirectory != directory { removeTemporary(directory) }
                reportedError = error.localizedDescription
                review.setPreviewPending(true, error: error.localizedDescription)
            }
        case "result":
            sawResult = true
            if taskKind == "doctor" {
                let message = event["message"] as? String ?? ((event["connected"] as? Bool == true) ? L10n.text("PhotoCraft 已连接") : L10n.text("请在 PhotoCraft 中打开扫描件"))
                let version = event["version"] as? String
                photoCraftConnection = version.map { "PhotoCraft \($0) · \(message)" } ?? message
                if inputSource == .photoCraft { connection.stringValue = photoCraftConnection }
                status.stringValue = message
                detail.stringValue = L10n.text("在专用 PhotoCraft 会话中打开扫描件，然后点击“处理当前照片”。")
                if event["installed"] as? Bool == false { status.textColor = .labelColor }
            } else {
                let stats = event["stats"] as? [String: Any]
                let count = (stats?["retained_regions"] as? Int) ?? (stats?["healed"] as? Int) ?? 0
                let changed = event["changed"] as? Bool ?? (count > 0)
                let imported = event["imported"] as? Bool ?? false
                let paths = event["paths"] as? [String: String]
                status.stringValue = event["message"] as? String ?? (changed ? L10n.text("除尘完成 · 修复 \(count) 处痕迹") : L10n.text("处理完成 · 没有检测到需要修复的灰尘"))
                if imported {
                    detail.stringValue = L10n.text("修复结果已作为新图层返回 PhotoCraft。蒙版涂黑恢复误修；点图像缩略图用 J 补漏。")
                } else {
                    detail.stringValue = paths?["mask"] == nil ? L10n.text("修复图像已保存。") : L10n.text("修复图像和蒙版已保存。")
                }
                if let directory = event["outputDir"] as? String {
                    resultDirectory = URL(fileURLWithPath: directory, isDirectory: true)
                    revealButton.isEnabled = true
                }
                if taskKind == "confirm", let review = reviewController {
                    if review.session?.context == "file" {
                        let file = paths?["cleaned"].map { URL(fileURLWithPath: $0) }
                        if let parent = resultDirectory?.deletingLastPathComponent() {
                            selectedOutput = parent
                            outputPath.stringValue = parent.path
                            outputPath.toolTip = parent.path
                        }
                        review.showSavedResult(file: file, directory: resultDirectory, includedMask: paths?["mask"] != nil)
                    } else {
                        window.makeKeyAndOrderFront(nil)
                        review.finishAndClose()
                        reviewController = nil
                        removeCurrentPreview()
                    }
                }
            }
            progress.doubleValue = 1
        default: break
        }
    }

    private func finished(code: Int32, errorLog: String) {
        let completedKind = taskKind
        process = nil
        if let started = workerStartedAt {
            AppDiagnostics.record(operation: completedKind, code: code, duration: Date().timeIntervalSince(started))
            workerStartedAt = nil
        }
        removePhotoshopSnapshot()
        stoppingObsoletePreview = false
        activePreviewReviewPath = nil
        if let file = activeEditsFile {
            activeEditsFile = nil
            removeTemporary(file)
        }
        setBusy(false)
        if terminateAfterBackgroundDetection {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        if let batch, let job = batch.job {
            finishBatchJob(batch, job: job, code: code, errorLog: errorLog)
            return
        }
        if completedKind == "preview" {
            if batch != nil { noteBatchActivity() }
            defer {
                if batch != nil {
                    startNextBatchJob()
                    refreshBatch()
                }
            }
            guard reviewController?.session != nil else { return }
            if previewNeedsRefresh || activePreviewGeneration != previewGeneration {
                previewNeedsRefresh = true
                if previewDebounce == nil { startPreviewIfReady() }
            } else if code != 0 || !previewWasApplied {
                reviewController?.setPreviewPending(true, error: reportedError ?? L10n.text("引擎未返回更新后的图像"))
            } else {
                reviewController?.setPreviewPending(false)
            }
            return
        }
        if completedKind == "confirm" { reviewController?.setWorking(false) }
        if wasCancelled {
            status.stringValue = L10n.text("已停止处理")
            detail.stringValue = L10n.text("原始扫描件未被修改。已完成的结果仍保留在输出目录中。")
            status.textColor = StudioStyle.secondaryText
        } else if code != 0 && reportedError == nil {
            let text = errorLog.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = text.isEmpty ? L10n.text("引擎未能完成处理（退出码 \(Int(code))）。") : String(text.suffix(1200))
            fail(message)
            if completedKind == "confirm", !sawResult { reviewController?.setPreviewPending(false, error: message) }
        } else if !sawResult && reportedError == nil {
            let message = L10n.text("引擎结束时未返回结果，请检查处理记录。")
            fail(message)
            if completedKind == "confirm" { reviewController?.setPreviewPending(false, error: message) }
        }
        if previewNeedsRefresh {
            if previewDebounce == nil { startPreviewIfReady() }
        }
        else if completedKind == "prepare" || completedKind == "prepare-photocraft" || completedKind == "inspect-review" { reviewController?.setPreviewPending(false) }
    }

    private func editsFile(_ review: ReviewWindowController) throws -> URL {
        try editsFile(excludedRegions: review.excludedRegions, strokes: review.strokes)
    }

    private func editsFile(excludedRegions: Set<Int>, strokes: [ReviewStroke]) throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = batch?.workDirectory.appendingPathComponent("edits", isDirectory: true)
            ?? support.appendingPathComponent("PURENeg/Review Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("edits-\(UUID().uuidString).json")
        let json = try JSONSerialization.data(withJSONObject: [
            "excludedRegions": excludedRegions.sorted(),
            "strokes": strokes.map(\.json)
        ], options: [.sortedKeys])
        try json.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private func confirmedRasters(from event: [String: Any], session: ReviewSession) -> ReviewRasters? {
        guard let paths = event["reviewPreview"] as? [String: String],
              let cleaned = paths["cleanedPath"], let mask = paths["maskPath"],
              let directory = previewDirectory(cleaned: cleaned, mask: mask, review: session.path, prefix: "confirmed-")
        else { return nil }
        return ReviewRasters(cleaned: directory.appendingPathComponent("cleaned.tiff"),
                             mask: directory.appendingPathComponent("dust-mask.tiff"))
    }

    private func previewDirectory(cleaned: String, mask: String, review: String, prefix: String = "preview-") -> URL? {
        let cleaned = URL(fileURLWithPath: cleaned).resolvingSymlinksInPath().standardizedFileURL
        let mask = URL(fileURLWithPath: mask).resolvingSymlinksInPath().standardizedFileURL
        let review = URL(fileURLWithPath: review).resolvingSymlinksInPath().standardizedFileURL
        let directory = cleaned.deletingLastPathComponent()
        guard cleaned.lastPathComponent == "cleaned.tiff", mask.lastPathComponent == "dust-mask.tiff",
              review.lastPathComponent == "review.json", mask.deletingLastPathComponent().path == directory.path,
              directory.deletingLastPathComponent().path == review.deletingLastPathComponent().path,
              directory.lastPathComponent.hasPrefix(prefix) else { return nil }
        return directory
    }

    private func removeTemporary(_ url: URL) {
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
    }

    private func removeCurrentPreview() {
        guard let directory = currentPreviewDirectory else { return }
        currentPreviewDirectory = nil
        removeTemporary(directory)
    }

    private func schedulePreview() {
        guard let review = reviewController else { return }
        if batch != nil { noteBatchActivity() }
        previewGeneration += 1
        previewNeedsRefresh = true
        review.setPreviewPending(true)
        previewDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewDebounce = nil
            self.startPreviewIfReady()
        }
        previewDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func startPreviewIfReady() {
        guard let review = reviewController, let session = review.session else { previewNeedsRefresh = false; return }
        guard previewNeedsRefresh else { return }
        if let worker = process {
            if let batch, batch.job?.isBackground == true {
                cancelBackgroundDetection(batch)
                return
            }
            if taskKind == "preview", activePreviewGeneration != previewGeneration,
               !stoppingObsoletePreview, worker.isRunning {
                stoppingObsoletePreview = true
                worker.terminate()
            }
            return
        }
        defer {
            if batch != nil {
                if process == nil && !previewNeedsRefresh { startNextBatchJob() }
                refreshBatch()
            }
        }
        review.setPreviewPending(true)
        do {
            let edits = try editsFile(review)
            previewNeedsRefresh = false
            previewWasApplied = false
            activePreviewGeneration = previewGeneration
            activePreviewReviewPath = session.path
            activeEditsFile = edits
            let revision = session.context == "file" ? ["--revise-export"] : []
            launch(command: "preview", arguments: ["--review", session.path, "--edits", edits.path] + revision)
            if process == nil {
                activePreviewReviewPath = nil
                activeEditsFile = nil
                removeTemporary(edits)
                review.setPreviewPending(true, error: L10n.text("无法启动预览引擎"))
            }
        } catch {
            previewNeedsRefresh = false
            review.setPreviewPending(true, error: error.localizedDescription)
        }
    }

    private func confirmReview(folder: URL?, includeMask: Bool) {
        guard process == nil, let review = reviewController, let session = review.session, !previewNeedsRefresh else { return }
        do {
            let edits = try editsFile(review)
            previewDebounce?.cancel()
            previewDebounce = nil
            review.setWorking(true)
            activeEditsFile = edits
            var arguments = ["--review", session.path, "--edits", edits.path] + review.confirmationFormatArguments
            if let folder { arguments += ["--output", folder.path, "--mask", includeMask ? "yes" : "no"] }
            launch(command: "confirm", arguments: arguments)
            if process == nil {
                activeEditsFile = nil
                removeTemporary(edits)
                review.setWorking(false)
                review.setPreviewPending(false, error: L10n.text("无法启动应用引擎"))
            }
        } catch {
            review.setPreviewPending(false, error: error.localizedDescription)
        }
    }

    private func finishReview() {
        reviewController = nil
        removeCurrentPreview()
        selectedInputs = []
        modeChanged()
        inputPath.stringValue = Self.chooseInputHint
        inputPath.toolTip = nil
        inputPath.textColor = StudioStyle.secondaryText
        status.stringValue = L10n.text("准备就绪")
        detail.stringValue = Self.waitingDetail
        progress.doubleValue = 0
        setBusy(process != nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func resetReviewPreview() {
        previewDebounce?.cancel()
        previewDebounce = nil
        previewGeneration += 1
        previewNeedsRefresh = false
        removeCurrentPreview()
        if taskKind == "preview", !stoppingObsoletePreview, let worker = process, worker.isRunning {
            wasCancelled = true
            worker.terminate()
        }
    }

    private func discardReview() {
        resetReviewPreview()
        reviewController = nil
        status.stringValue = L10n.text("审核已取消 · 未保存最终结果")
        detail.stringValue = L10n.text("原图和 PhotoCraft 文档未因本次审核被修改。工作缓存仍保留在本机。")
        setBusy(process != nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func fail(_ message: String) {
        status.stringValue = message
        status.textColor = .labelColor
        detail.stringValue = L10n.text("原始文件会保留。请检查文件格式、可用内存及 PhotoCraft 连接后重试。")
    }

    @objc private func cancel() {
        guard let worker = process, worker.isRunning else { return }
        wasCancelled = true
        cancelButton.isEnabled = false
        status.stringValue = L10n.text("正在停止…")
        worker.terminate()
    }

    @objc private func reveal() {
        guard let directory = resultDirectory else { return }
        NSWorkspace.shared.open(directory)
    }
}

@main
private struct PURENegMain {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--make-icon" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for size in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let pixels = size * scale
                    let image = makeIcon(CGFloat(pixels))
                    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { continue }
                    try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
                }
            }
        } else {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
        }
    }
}
