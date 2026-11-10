import AppKit
import ImageIO
import QuartzCore

/// A loupe on the repaired film, with one cached display raster of its own.
final class FilmLoupe: NSView {
    private static let rasterQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PURE Neg film loupe"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private static let dockGlyph: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "loupe", accessibilityDescription: nil),
              let amber = symbol.withSymbolConfiguration(configuration.applying(.init(paletteColors: [StudioStyle.amber]))),
              let outline = symbol.withSymbolConfiguration(configuration.applying(.init(paletteColors: [StudioStyle.charcoal])))
        else { return NSImage() }
        let size = NSSize(width: amber.size.width + 2, height: amber.size.height + 2)
        return NSImage(size: size, flipped: false) { _ in
            // The light table can reach HDR white. A graphite edge separates the amber from the glass.
            for offset in [NSPoint(x: 0.25, y: 1), NSPoint(x: 1.75, y: 1),
                           NSPoint(x: 1, y: 0.25), NSPoint(x: 1, y: 1.75)] {
                outline.draw(at: offset, from: .zero, operation: .sourceOver, fraction: 1)
            }
            amber.draw(at: NSPoint(x: 1, y: 1), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }()

    // The transform maps normalized source coordinates (top-left origin) into the board.
    var sourceToBoard: (() -> CGAffineTransform?)?
    var thumbnail: (() -> CGImage?)?

    private struct Raster {
        let image: CGImage
        let extent: CGRect
    }

    private static let fullExtent = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let aperture = CALayer()
    private let rasterLayer = CALayer()
    private let chrome = LoupeChromeView()
    private var toneRenderer: (@Sendable (CGImage) -> CGImage?)?
    private var isHDR = false
    private var toned: Raster?
    private var toneTask: BlockOperation?
    private var unavailableToneExtent: CGRect?

    private let dockHitDiameter: CGFloat = 40
    private let dockButtonDiameter: CGFloat = 26
    private let minimumDiameter: CGFloat = 120
    private var viewingDiameter: CGFloat = 248
    private var magnification: CGFloat = 3
    private var adjustment: (handle: Handle, start: CGFloat, value: CGFloat)?
    private let dockButton = NSButton(image: dockGlyph, target: nil, action: nil)
    private var artwork: URL?
    private var detail: CGImage?
    private var loadTask: BlockOperation?
    private var attemptedLoad = false
    private var parked = true
    private var dock = NSPoint.zero
    private var bed = NSRect.zero
    private var sourceFocus: CGPoint?
    private var drag: (start: NSPoint, offset: NSPoint, startedParked: Bool, moved: Bool)?

    private enum Handle: CaseIterable {
        case size, zoom

        var direction: CGPoint {
            let diagonal = sqrt(0.5 as CGFloat)
            return CGPoint(x: diagonal, y: self == .size ? -diagonal : diagonal)
        }

        var color: NSColor { self == .size ? .systemBlue : .systemGreen }

        var cursor: NSCursor {
            #if compiler(>=6.0)
            if self == .size, #available(macOS 15.0, *) {
                return .frameResize(position: .bottomRight, directions: .all)
            }
            #endif
            return .crosshair
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        aperture.backgroundColor = NSColor.black.cgColor
        aperture.masksToBounds = true
        aperture.isHidden = true
        rasterLayer.anchorPoint = .zero
        aperture.addSublayer(rasterLayer)
        layer?.addSublayer(aperture)
        chrome.wantsLayer = true
        chrome.layer?.zPosition = 1
        chrome.render = { [weak self] in self?.drawChrome() }
        chrome.isHidden = true
        addSubview(chrome)
        dockButton.bezelStyle = .circular
        dockButton.controlSize = .small
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            dockButton.bezelStyle = .glass
            dockButton.borderShape = .circle
            dockButton.bezelColor = StudioStyle.charcoal
            dockButton.tintProminence = .secondary
        }
        #endif
        dockButton.setAccessibilityElement(false)
        addSubview(dockButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.surface("观片放大镜"))
        updateHelp()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        toneTask?.cancel()
    }

    override var acceptsFirstResponder: Bool { true }

    func setArtwork(_ url: URL?) {
        guard artwork != url else { return }
        artwork = url
        clearDetail()
        park(animated: false)
    }

    func setLighting(isHDR: Bool, renderer: (@Sendable (CGImage) -> CGImage?)?) {
        self.isHDR = isHDR
        toneRenderer = renderer
        clearTone()
        refreshRaster()
    }

    func placeDock(in bed: NSRect) {
        let inset = dockHitDiameter / 2 + 2
        dock = NSPoint(x: bed.maxX - inset, y: bed.minY + inset)
        self.bed = bed
        if viewingDiameter > maximumDiameter {
            viewingDiameter = maximumDiameter
            updateAccessibilityValue()
        }
        geometryChanged()
    }

    func geometryChanged() {
        let transform = parked ? nil : sourceToBoard?()
        isHidden = !parked && transform == nil
        if parked {
            place(center: dock)
        } else if drag == nil, let focus = sourceFocus, let transform {
            place(center: focus.applying(transform))
        }
        refreshRaster()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            clearDetail()
            park(animated: false)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return handle(at: local) != nil || NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).contains(local) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: parked ? .pointingHand : .openHand)
        if !parked {
            for handle in Handle.allCases {
                addCursorRect(handleRect(handle), cursor: handle.cursor)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard sourceToBoard?() != nil else { return }
        let point = pointer(event)
        window?.makeFirstResponder(self)
        if let handle = handle(at: convert(point, from: superview)) {
            let value = handle == .size ? viewingDiameter : magnification
            adjustment = (handle, distance(of: point, along: handle), value)
            return
        }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let offset = parked ? .zero : NSPoint(x: center.x - point.x, y: center.y - point.y)
        drag = (point, offset, parked, false)
        if parked {
            dockButton.highlight(true)
            LoupeSound.play(.lift)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = pointer(event)
        if let adjustment {
            let delta = distance(of: point, along: adjustment.handle) - adjustment.start
            switch adjustment.handle {
            case .size: resize(to: adjustment.value + delta * 2)
            case .zoom: zoom(to: adjustment.value * exp(delta / 90))
            }
            return
        }
        guard var gesture = drag else { return }
        guard gesture.moved || hypot(point.x - gesture.start.x, point.y - gesture.start.y) >= 3 else { return }
        if !gesture.moved {
            gesture.moved = true
            drag = gesture
            if parked { lift(at: point, animated: true) }
            else { LoupeSound.play(.lift) }
        }
        move(to: NSPoint(x: point.x + gesture.offset.x, y: point.y + gesture.offset.y))
    }

    override func mouseUp(with event: NSEvent) {
        if adjustment != nil {
            adjustment = nil
            return
        }
        guard let gesture = drag else { return }
        drag = nil
        if gesture.moved {
            let drop = pointer(event)
            if !bed.contains(drop) || hypot(drop.x - dock.x, drop.y - dock.y) <= dockHitDiameter / 2 { park() }
            LoupeSound.play(.settle)
        } else if gesture.startedParked {
            if liftAtPhotoCenter() { LoupeSound.play(.settle) }
        } else if event.clickCount == 2 {
            park()
            LoupeSound.play(.settle)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        if parked {
            guard liftAtPhotoCenter() else { return false }
            LoupeSound.play(.lift)
            return true
        }
        park()
        LoupeSound.play(.settle)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers
        if key == " " || key == "\r" {
            _ = accessibilityPerformPress()
        } else if !parked, let key, ["+", "=", "-", "−"].contains(key) {
            let increase = key == "+" || key == "="
            if event.modifierFlags.contains(.option) {
                resize(to: viewingDiameter + (increase ? 24 : -24))
            } else {
                zoom(to: magnification * (increase ? 1.2 : 1 / 1.2))
            }
        } else if !parked, let delta = [123: (-12, 0), 124: (12, 0), 125: (0, -12), 126: (0, 12)][Int(event.keyCode)] {
            move(to: NSPoint(x: frame.midX + CGFloat(delta.0), y: frame.midY + CGFloat(delta.1)))
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !parked, event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        guard adjustment == nil, event.momentumPhase.isEmpty else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.012 : 0.16
        zoom(to: magnification * exp(event.scrollingDeltaY * scale))
    }

    override func magnify(with event: NSEvent) {
        guard !parked, adjustment == nil else {
            super.magnify(with: event)
            return
        }
        zoom(to: magnification * exp(event.magnification))
    }

    private var maximumDiameter: CGFloat {
        bed.isEmpty ? 480 : min(480, max(minimumDiameter, min(bed.width, bed.height) - 12))
    }

    private func resize(to value: CGFloat) {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let host = superview?.bounds ?? .zero
        let distanceToEdge = min(center.x - host.minX, host.maxX - center.x,
                                 center.y - host.minY, host.maxY - center.y)
        let limit = min(maximumDiameter, max(minimumDiameter, distanceToEdge * 2))
        let diameter = min(max(value, minimumDiameter), limit)
        guard diameter != viewingDiameter else { return }
        viewingDiameter = diameter
        place(center: center)
        needsDisplay = true
        refreshRaster()
        updateAccessibilityValue()
    }

    private func zoom(to value: CGFloat) {
        let factor = min(max(value, 1.5), 8)
        guard factor != magnification else { return }
        magnification = factor
        chrome.needsDisplay = true
        refreshRaster()
        updateAccessibilityValue()
    }

    private func distance(of point: NSPoint, along handle: Handle) -> CGFloat {
        let direction = handle.direction
        return (point.x - frame.midX) * direction.x + (point.y - frame.midY) * direction.y
    }

    private func handleCenter(_ handle: Handle) -> NSPoint {
        let radius = bounds.width / 2 - 7
        let direction = handle.direction
        return NSPoint(x: bounds.midX + direction.x * radius, y: bounds.midY + direction.y * radius)
    }

    private func handleRect(_ handle: Handle) -> NSRect {
        let center = handleCenter(handle)
        return NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
    }

    private func handle(at point: NSPoint) -> Handle? {
        guard !parked else { return nil }
        return Handle.allCases.first { handleRect($0).contains(point) }
    }

    private var zoomLabel: String {
        Double(magnification).formatted(.number.locale(L10n.locale).precision(.fractionLength(0...1))) + "×"
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(parked ? nil : L10n.surface("放大 \(zoomLabel)，镜面 \(Int(viewingDiameter)) 点"))
    }

    private func pointer(_ event: NSEvent) -> NSPoint {
        superview?.convert(event.locationInWindow, from: nil) ?? .zero
    }

    @discardableResult
    private func liftAtPhotoCenter() -> Bool {
        guard let transform = sourceToBoard?() else { return false }
        lift(at: NSPoint(x: 0.5, y: 0.5).applying(transform), animated: true)
        return true
    }

    private func lift(at point: NSPoint, animated: Bool) {
        parked = false
        chrome.isHidden = false
        dockButton.highlight(false)
        dockButton.isHidden = true
        updateHelp()
        move(to: point)
        requestDetail()
        if animated { animateLift() }
    }

    private func park(animated: Bool = true) {
        let wasLifted = !parked
        parked = true
        chrome.isHidden = true
        isHidden = false
        dockButton.highlight(false)
        dockButton.isHidden = false
        sourceFocus = nil
        drag = nil
        adjustment = nil
        updateHelp()
        place(center: dock)
        needsDisplay = true
        refreshRaster()
        if animated && wasLifted { animateLift() }
    }

    private func move(to point: NSPoint) {
        guard let host = superview else { return }
        let allowed = host.bounds.insetBy(dx: viewingDiameter / 2, dy: viewingDiameter / 2)
        let center = allowed.isEmpty ? point : NSPoint(x: min(max(point.x, allowed.minX), allowed.maxX),
                                                     y: min(max(point.y, allowed.minY), allowed.maxY))
        place(center: center)
        if let transform = sourceToBoard?() { sourceFocus = center.applying(transform.inverted()) }
        needsDisplay = true
        refreshRaster()
    }

    private func place(center: NSPoint) {
        let diameter = parked ? dockHitDiameter : viewingDiameter
        let newFrame = NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        if frame != newFrame {
            frame = newFrame
            chrome.frame = bounds
            window?.invalidateCursorRects(for: self)
        }
        if parked {
            let margin = (dockHitDiameter - dockButtonDiameter) / 2
            dockButton.frame = bounds.insetBy(dx: margin, dy: margin)
        }
    }

    private func updateHelp() {
        let help = parked ? L10n.surface("点击取用放大镜，或直接拖到胶片上。")
            : L10n.surface("蓝点调整镜面大小，绿点调整放大倍率。双击或拖回右下角归位。")
        toolTip = help
        setAccessibilityHelp(help)
        updateAccessibilityValue()
        window?.invalidateCursorRects(for: self)
    }

    private func animateLift() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.91
        animation.toValue = 1
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(animation, forKey: "loupe-lift")
    }

    private func clearDetail() {
        clearTone()
        loadTask?.cancel()
        loadTask = nil
        detail = nil
        attemptedLoad = false
    }

    private func requestDetail() {
        guard let artwork, !attemptedLoad else { return }
        attemptedLoad = true
        let maxSize = AppPreferences.conserveMemory ? 3072 : 4096
        let task = BlockOperation()
        loadTask = task
        task.addExecutionBlock { [weak self, weak task] in
            guard task?.isCancelled == false else { return }
            let image = autoreleasepool { Self.readDetail(at: artwork, maxSize: maxSize) }
            DispatchQueue.main.async { [weak self, weak task] in
                guard let self, let task, self.loadTask === task, !task.isCancelled else { return }
                self.loadTask = nil
                guard self.window?.isVisible == true else {
                    self.attemptedLoad = false
                    return
                }
                self.detail = image
                self.refreshRaster()
            }
        }
        Self.rasterQueue.addOperation(task)
    }

    private static func readDetail(at url: URL, maxSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              image.width <= maxSize, image.height <= maxSize,
              image.bytesPerRow <= (128 * 1024 * 1024) / max(1, image.height) else { return nil }
        return image
    }

    private func clearTone() {
        toneTask?.cancel()
        toneTask = nil
        toned = nil
        unavailableToneExtent = nil
    }

    func refreshRaster() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !parked, let source = sourceToBoard?() else {
            aperture.isHidden = true
            rasterLayer.contents = nil
            return
        }
        let lens = bounds.insetBy(dx: 5, dy: 5)
        aperture.frame = lens
        aperture.cornerRadius = lens.width / 2
        aperture.isHidden = false

        // Convert source normalized bottom-left coordinates into the clipped aperture.
        let bottom = CGPoint(x: 0, y: 1).applying(source)
        let transform = CGAffineTransform(a: source.a * magnification, b: source.b * magnification,
                                          c: -source.c * magnification, d: -source.d * magnification,
                                          tx: lens.width / 2 + (bottom.x - frame.midX) * magnification,
                                          ty: lens.height / 2 + (bottom.y - frame.midY) * magnification)
        let visible = CGRect(origin: .zero, size: lens.size).applying(transform.inverted()).intersection(Self.fullExtent)
        let raster = raster(for: visible)
        if #available(macOS 26.0, *) { rasterLayer.preferredDynamicRange = isHDR ? .high : .standard }
        rasterLayer.contents = raster?.image
        if let extent = raster?.extent {
            rasterLayer.bounds = CGRect(origin: .zero, size: extent.size)
            rasterLayer.position = extent.origin.applying(transform)
            rasterLayer.setAffineTransform(CGAffineTransform(a: transform.a, b: transform.b,
                                                             c: transform.c, d: transform.d, tx: 0, ty: 0))
        }
    }

    private func raster(for visible: CGRect) -> Raster? {
        guard !visible.isNull, !visible.isEmpty else { return nil }
        if let detail {
            if let toneRenderer {
                if let toned, toned.extent.insetBy(dx: -1e-6, dy: -1e-6).contains(visible) { return toned }
                if unavailableToneExtent?.contains(visible) != true {
                    requestTone(of: detail, around: visible, renderer: toneRenderer)
                }
            } else {
                return Raster(image: detail, extent: Self.fullExtent)
            }
        }
        return thumbnail?().map { Raster(image: $0, extent: Self.fullExtent) }
    }

    private func requestTone(of detail: CGImage, around visible: CGRect, renderer: @escaping @Sendable (CGImage) -> CGImage?) {
        guard toneTask == nil else { return }
        let width = CGFloat(detail.width), height = CGFloat(detail.height)
        // Reuse a little surrounding area as the loupe moves. The worker caps the output raster.
        let area = visible.insetBy(dx: -max(visible.width * 0.25, 128 / width),
                                  dy: -max(visible.height * 0.25, 128 / height)).intersection(Self.fullExtent)
        let pixels = CGRect(x: area.minX * width, y: (1 - area.maxY) * height,
                            width: area.width * width, height: area.height * height).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let extent = CGRect(x: pixels.minX / width, y: 1 - pixels.maxY / height,
                            width: pixels.width / width, height: pixels.height / height)
        let task = BlockOperation()
        toneTask = task
        task.addExecutionBlock { [weak self, weak task] in
            guard task?.isCancelled == false else { return }
            let image = autoreleasepool { detail.cropping(to: pixels).flatMap(renderer) }
            DispatchQueue.main.async { [weak self, weak task] in
                guard let self, let task, self.toneTask === task, !task.isCancelled else { return }
                self.toneTask = nil
                guard self.window?.isVisible == true else { return }
                self.toned = image.map { Raster(image: $0, extent: extent) }
                self.unavailableToneExtent = image == nil ? extent.insetBy(dx: -1e-6, dy: -1e-6) : nil
                self.refreshRaster()
            }
        }
        Self.rasterQueue.addOperation(task)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !parked, let context = NSGraphicsContext.current?.cgContext else { return }
        let lens = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 4,
                          color: NSColor.black.withAlphaComponent(0.46).cgColor)
        NSColor.black.setFill()
        lens.fill()
        context.restoreGState()
    }

    private func drawChrome() {
        let lens = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        NSColor.black.withAlphaComponent(0.70).setStroke()
        lens.lineWidth = 3
        lens.stroke()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        lens.lineWidth = 1.5
        lens.stroke()

        for handle in Handle.allCases {
            let center = handleCenter(handle)
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            handle.color.setFill()
            dot.fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }

        let label = zoomLabel as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attributes)
        let zoom = handleCenter(.zoom)
        let badge = NSRect(x: zoom.x - 12 - size.width - 10, y: zoom.y - (size.height + 4) / 2,
                           width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        label.draw(at: NSPoint(x: badge.minX + 5, y: badge.minY + 2), withAttributes: attributes)
    }
}

private final class LoupeChromeView: NSView {
    var render: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) { render?() }
}

@MainActor private enum LoupeSound {
    enum Motion { case lift, settle }

    private static let lift = make(frequency: 1_740, duration: 0.048, decay: 0.005)
    private static let settle = make(frequency: 580, duration: 0.08, decay: 0.011)

    static func play(_ motion: Motion) {
        let sound = motion == .lift ? lift : settle
        sound?.stop()
        sound?.play()
    }

    private static func make(frequency: Double, duration: Double, decay: Double) -> NSSound? {
        let rate = 44_100, count = Int(duration * Double(rate))
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(UInt32(count * 2))
        var seed: UInt32 = 1949
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let attack = min(1, time * 3_000)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            let body = sin(time * frequency * 2 * .pi) * exp(-time / decay)
            let contact = noise * exp(-time / 0.0025)
            put(Int16(clamping: Int(9_800 * attack * (0.72 * body + 0.28 * contact))))
        }
        let sound = NSSound(data: data)
        sound?.volume = 0.42
        return sound
    }
}
