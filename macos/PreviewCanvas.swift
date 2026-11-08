import AppKit
import CoreImage
import ImageIO
import Metal

struct DustRegion {
    let id: Int
    /// Image pixels, measured from the top-left, matching the TIFF mask.
    let rect: NSRect
    let pixels: Int
    let kinds: [DetectionKind]

    init(id: Int, rect: NSRect, pixels: Int, kinds: [DetectionKind] = []) {
        self.id = id
        self.rect = rect
        self.pixels = pixels
        self.kinds = kinds
    }

    var categoryLabel: String {
        kinds.isEmpty ? L10n.text("类别未知") : kinds.map(\.label).joined(separator: " · ")
    }
}

/// The signed review's sparse mask runs are ordered by row and starting column.
private struct ReviewSpotIndex {
    private let data: Data
    private let count: Int

    init?(url: URL, width: Int, height: Int, regionCount: Int) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 24, data.prefix(8).elementsEqual("FDRUNS01".utf8) else { return nil }
        let count = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            let count = Self.word(bytes, at: 8)
            guard count <= 2_000_000, data.count == 24 + count * 16,
                  Self.word(bytes, at: 12) == width, Self.word(bytes, at: 16) == height,
                  Self.word(bytes, at: 20) == regionCount else { return nil }
            return count
        }
        guard let count else { return nil }
        self.data = data
        self.count = count
    }

    private static func word(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int {
        Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    }

    func nearest(to point: NSPoint, radius: CGFloat, excluding: Set<Int>) -> Int? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var closestID: Int?
            var closestDistance = radius * radius
            var y = Int(floor(point.y - radius)), start = 0
            let lastRow = Int(floor(point.y + radius))
            while y <= lastRow {
                // Both row and run end are monotonic within the row. Jump
                // over unrelated columns instead of traversing full rows.
                var lo = start, hi = count
                while lo < hi {
                    let mid = (lo + hi) / 2, offset = 24 + mid * 16
                    let row = Self.word(bytes, at: offset + 4)
                    if row < y || (row == y && CGFloat(Self.word(bytes, at: offset + 12)) < point.x - radius) { lo = mid + 1 }
                    else { hi = mid }
                }
                guard lo < count else { break }
                let row = Self.word(bytes, at: 28 + lo * 16)
                if row > y { y = row; start = lo; continue }
                let dy = max(CGFloat(y) - point.y, point.y - CGFloat(y + 1), 0)
                while lo < count {
                    let offset = 24 + lo * 16
                    if Self.word(bytes, at: offset + 4) != y { break }
                    let x0 = CGFloat(Self.word(bytes, at: offset + 8))
                    if x0 > point.x + radius { break }
                    let x1 = CGFloat(Self.word(bytes, at: offset + 12))
                    let dx = max(x0 - point.x, point.x - x1, 0)
                    let distance = dx * dx + dy * dy
                    let id = Self.word(bytes, at: offset)
                    if distance <= closestDistance && !excluding.contains(id) {
                        if distance == 0 { return id }
                        closestID = id
                        closestDistance = distance
                    }
                    lo += 1
                }
                y += 1
                start = lo
            }
            return closestID
        }
    }
}

enum PreviewMode: Int {
    case original = 0
    case repaired = 1
    case split = 2
}

enum ReviewTool: Int {
    case inspect
    case add
    case erase
}

struct ReviewMaskColor {
    static let fluorescentRed = ReviewMaskColor(rgb: 0xFF254D)
    private static let preferenceKey = "reviewMaskColorSRGB"
    private let rgb: UInt32

    private init(rgb: UInt32) { self.rgb = rgb }

    init?(color: NSColor) {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        let bytes = components.map { UInt32((min(1, max(0, $0)) * 255).rounded()) }
        rgb = (bytes[0] << 16) | (bytes[1] << 8) | bytes[2]
    }

    private var hex: String { String(format: "%06X", rgb) }

    var color: NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255,
                alpha: 1)
    }

    var eraserColor: NSColor {
        let color = self.color
        let cyan = NSColor(srgbRed: 0.21, green: 0.85, blue: 1, alpha: 1)
        let red = color.redComponent - cyan.redComponent
        let green = color.greenComponent - cyan.greenComponent
        let blue = color.blueComponent - cyan.blueComponent
        if red * red + green * green + blue * blue < 0.16 {
            return NSColor(srgbRed: 1, green: 0.85, blue: 0.34, alpha: 1)
        }
        return cyan
    }

    static func load(from preferences: UserDefaults = .standard) -> ReviewMaskColor {
        guard let saved = preferences.string(forKey: preferenceKey), saved.utf8.count == 6,
              let rgb = UInt32(saved, radix: 16) else { return .fluorescentRed }
        let value = ReviewMaskColor(rgb: rgb)
        return value.hex == saved.uppercased() ? value : .fluorescentRed
    }

    func save(to preferences: UserDefaults = .standard) {
        preferences.set(hex, forKey: Self.preferenceKey)
    }
}

struct ReviewStroke {
    let tool: ReviewTool
    let radius: Int
    var points: [NSPoint]

    var json: [String: Any] {
        ["kind": tool == .add ? "add" : "erase", "radius": radius,
         "points": points.map { [Int($0.x), Int($0.y)] }]
    }
}

private struct PreviewRasterFrame {
    let pixels: NSRect
    let scale: CGFloat
    let image: CGImage

    static func render(_ image: CGImage, pixels: NSRect, scale: CGFloat, isMask: Bool,
                       metal: PreviewMetalRenderer? = nil, conserveMemory: Bool = false) -> PreviewRasterFrame? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let crop = pixels == full ? image : image.cropping(to: pixels) else { return nil }
        let width = max(1, Int((pixels.width * scale).rounded(.up)))
        let height = max(1, Int((pixels.height * scale).rounded(.up)))
        let colorSpace: CGColorSpace
        if isMask {
            colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceGray()
        } else if let space = image.colorSpace, space.model == .rgb {
            colorSpace = space
        } else {
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            colorSpace = srgb
        }
        if !isMask, crop.colorSpace?.model == .rgb,
           let rendered = metal?.render(crop, width: width, height: height, colorSpace: colorSpace,
                                        conserveMemory: conserveMemory) {
            return PreviewRasterFrame(pixels: pixels, scale: scale, image: rendered)
        }
        let bitmapInfo = isMask ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // Native-size regions keep the original spatial samples. The buffer is
        // for display, so the screen no longer converts a 16-bit TIFF every frame.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        context.interpolationQuality = scale >= 1 ? .none : .medium
        context.setBlendMode(.copy)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { return nil }
        return PreviewRasterFrame(pixels: pixels, scale: scale, image: rendered)
    }
}

/// Called only on the canvas's serial raster queue. Oversized or unsupported
/// inputs stay on Quartz rather than allocating another large Metal texture.
private final class PreviewMetalRenderer {
    private lazy var context: CIContext? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        // The input and output share the same RGB profile. Resample these
        // channel values directly and let the tagged output drive display ICC.
        return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    }()

    func render(_ image: CGImage, width: Int, height: Int, colorSpace: CGColorSpace,
                conserveMemory: Bool) -> CGImage? {
        let maxPixels = conserveMemory ? 4_000_000 : 16_000_000
        let maxSide = 8192
        guard width < image.width || height < image.height,
              image.width <= maxSide, image.height <= maxSide,
              image.width <= maxPixels / image.height, let context else { return nil }
        let input = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        let scaleX = CGFloat(width) / CGFloat(image.width)
        let scaleY = CGFloat(height) / CGFloat(image.height)
        let scaled = input.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY
        ])
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        guard let rendered = context.createCGImage(scaled, from: extent, format: .BGRA8,
                                                   colorSpace: colorSpace, deferred: false),
              rendered.width == width, rendered.height == height, rendered.colorSpace == colorSpace else { return nil }
        return rendered
    }
}

private final class PreviewRaster {
    let image: CGImage
    let isMask: Bool
    var overview: PreviewRasterFrame?
    var viewport: PreviewRasterFrame?
    var fallback: PreviewRasterFrame?
    var failed = false

    init(_ image: CGImage, isMask: Bool = false) {
        self.image = image
        self.isMask = isMask
    }

    func frame(covering pixels: NSRect, scale: CGFloat) -> PreviewRasterFrame? {
        if let frame = viewport, frame.scale >= scale, frame.pixels.contains(pixels) { return frame }
        if let frame = overview, frame.scale >= scale, frame.pixels.contains(pixels) { return frame }
        return nil
    }

    func discardFrames() {
        overview = nil
        viewport = nil
        fallback = nil
    }
}

final class PreviewCanvasView: NSView {
    var mode: PreviewMode = .repaired { didSet { clearHover(); needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var showRegions = false { didSet { clearHover(); needsDisplay = true } }
    var showMask = true { didSet { clearHover(); needsDisplay = true } }
    var maskOpacity: CGFloat = 0.7 { didSet { clearHover(); needsDisplay = true } }
    var maskColor: ReviewMaskColor = .fluorescentRed { didSet { needsDisplay = true } }
    var tool: ReviewTool = .inspect {
        didSet {
            if tool != oldValue { clearHover() }
            if tool != .inspect { inspectionAnchor = nil }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var brushRadius = 8 { didSet { needsDisplay = true } }
    var pendingStrokes: [ReviewStroke] = [] { didSet { needsDisplay = true } }
    var excludedRegions = Set<Int>() {
        didSet {
            guard excludedRegions != oldValue else { return }
            clearHover()
            needsDisplay = true
            if let id = selectedRegionID, inspectionAnchor != nil, excludedRegions.contains(id) != oldValue.contains(id) {
                updateInspectionAccessibility()
                updateInspectionOverlay()
            }
        }
    }
    var selectedRegionID: Int? {
        didSet {
            if selectedRegionID != oldValue { inspectionAnchor = nil }
            needsDisplay = true
        }
    }
    var splitFraction: Double = 0.5 {
        didSet {
            if !splitFraction.isFinite { splitFraction = 0.5 }
            splitFraction = max(0, min(1, splitFraction))
            clearHover()
            needsDisplay = true
        }
    }
    var onSelectRegion: ((Int) -> Void)?
    var onToggleInspectedRegion: ((Int) -> Void)? { didSet { updateInspectionOverlay() } }
    var onStroke: ((ReviewStroke) -> Void)?
    var onUndoEdit: (() -> Void)?
    var onRedoEdit: (() -> Void)?
    var onToolChange: ((ReviewTool) -> Void)?
    var onBrushRadiusChange: ((Int) -> Void)?
    var onDisplayReadyChange: (() -> Void)?
    /// A percentage: 100 means one source pixel per physical display pixel.
    var onZoomChange: ((Double) -> Void)?
    var isUserInteractionEnabled = true {
        didSet {
            guard isUserInteractionEnabled != oldValue else { return }
            if !isUserInteractionEnabled { clearHover() }
            updateInspectionOverlay()
        }
    }

    private(set) var zoomScale: CGFloat = 1
    private(set) var regions: [DustRegion] = []
    private var regionsByID: [Int: DustRegion] = [:]
    private(set) var imageSize = NSSize.zero
    private var sourceImage: PreviewRaster?
    private var cleanedImage: PreviewRaster?
    private var maskImage: PreviewRaster?
    private var spotIndex: ReviewSpotIndex?
    private var inspectionAnchor: NSPoint? {
        didSet {
            guard inspectionAnchor != oldValue else { return }
            updateInspectionAccessibility()
            updateInspectionOverlay()
        }
    }
    private lazy var inspectionActionButton = NSButton(title: "", target: self, action: #selector(toggleInspectedRegion))
    private var inspectionBubble: SpotCaption?
    private var hoverBubble: SpotCaption?
    private let renderQueue = DispatchQueue(label: "PURENeg.previewRaster", qos: .userInitiated)
    private var rasterizing = false
    private var metalRenderer: PreviewMetalRenderer?
    private var conserveMemory = false
    private(set) var isDisplayReady = false {
        didSet {
            if isDisplayReady != oldValue {
                DispatchQueue.main.async { [weak self] in self?.onDisplayReadyChange?() }
            }
        }
    }
    private var usesDisplayCache: Bool { imageSize.width * imageSize.height > 12_000_000 }
    private var activeStroke: ReviewStroke?
    private var brushLocation: NSPoint?
    private var mouseTracking: NSTrackingArea?
    private var spaceDown = false
    private var draggingPan = false
    private var draggingDivider = false
    private var panStartWindow = NSPoint.zero
    private var panStartOrigin = NSPoint.zero
    private var fitted = true
    private var resizeObserver: NSObjectProtocol?
    private var viewportObserver: NSObjectProtocol?
    private let margin: CGFloat = 20

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.surface("胶片除尘审核预览"))
        setAccessibilityHelp(L10n.surface("修复蒙版显示实际修复像素。滚动缩放，按住空格拖动平移。使用画笔补修漏点，使用橡皮擦恢复原始像素。"))
        postsFrameChangedNotifications = true
        inspectionActionButton.bezelStyle = .rounded
        inspectionActionButton.controlSize = .small
        inspectionActionButton.isHidden = true
        addSubview(inspectionActionButton)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let observer = resizeObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = viewportObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observer = resizeObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = viewportObserver { NotificationCenter.default.removeObserver(observer) }
        resizeObserver = nil
        viewportObserver = nil
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            resizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                if self.fitted { self.fitToWindow() } else { self.updateDocumentFrame() }
            }
            viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.clearHover()
                self?.updateInspectionOverlay()
            }
        }
    }

    override func updateTrackingAreas() {
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        mouseTracking = tracking
        super.updateTrackingAreas()
    }

    func load(sourceURL: URL, cleanedURL: URL, maskURL: URL, width: Int, height: Int, regions: [DustRegion],
              runsURL: URL? = nil, preserveViewport: Bool = false) throws {
        guard width > 0, height > 0, width <= 300_000_000 / height else { throw previewError(L10n.surface("无效的预览图像尺寸。")) }
        let source = try readImage(sourceURL, width: width, height: height)
        let cleaned = try readImage(cleanedURL, width: width, height: height)
        let mask = try readMask(maskURL, width: width, height: height)
        guard regions.count <= 100_000, Set(regions.map(\.id)).count == regions.count,
              regions.allSatisfy({ $0.id >= 0 && $0.pixels > 0 && validRegion($0.rect, width: width, height: height) }) else {
            throw previewError(L10n.surface("灰尘区域的坐标无效。"))
        }
        let newConserveMemory = AppPreferences.conserveMemory
        if newConserveMemory != conserveMemory { metalRenderer = nil }
        conserveMemory = newConserveMemory
        metalRenderer = AppPreferences.gpuPreview ? metalRenderer ?? PreviewMetalRenderer() : nil
        self.sourceImage = PreviewRaster(source)
        self.cleanedImage = PreviewRaster(cleaned)
        self.maskImage = PreviewRaster(mask, isMask: true)
        let newImageSize = NSSize(width: width, height: height)
        let keepViewport = preserveViewport && newImageSize == imageSize
        let previousSplit = splitFraction
        self.imageSize = newImageSize
        self.regions = regions
        regionsByID = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
        spotIndex = runsURL.flatMap { ReviewSpotIndex(url: $0, width: width, height: height, regionCount: regions.count) }
        self.excludedRegions = []
        self.selectedRegionID = nil
        resetImageInteraction()
        isDisplayReady = !usesDisplayCache
        if keepViewport { splitFraction = previousSplit }
        else { fitToWindow() }
        needsDisplay = true
    }

    func updateCleanedImage(url: URL, maskURL: URL) throws {
        guard imageSize.width > 0, imageSize.height > 0 else { throw previewError(L10n.surface("请先载入待审核的照片。")) }
        let image = try readImage(url, width: Int(imageSize.width), height: Int(imageSize.height))
        let mask = try readMask(maskURL, width: Int(imageSize.width), height: Int(imageSize.height))
        let nextCleaned = PreviewRaster(image)
        let nextMask = PreviewRaster(mask, isMask: true)
        if !conserveMemory {
            nextCleaned.fallback = cleanedImage?.viewport ?? cleanedImage?.overview
            nextMask.fallback = maskImage?.viewport ?? maskImage?.overview
        }
        cleanedImage = nextCleaned
        maskImage = nextMask
        if usesDisplayCache && mode != .original { isDisplayReady = false }
        needsDisplay = true
    }

    func clearImages() {
        sourceImage = nil; cleanedImage = nil; maskImage = nil; spotIndex = nil
        if conserveMemory { metalRenderer = nil }
        imageSize = .zero; regions = []
        regionsByID = [:]
        selectedRegionID = nil; excludedRegions = []
        resetImageInteraction()
        fitted = true
        zoomScale = 1
        updateDocumentFrame()
        isDisplayReady = false
    }

    private func resetImageInteraction() {
        activeStroke = nil
        clearHover()
        inspectionAnchor = nil
        pendingStrokes = []
        brushLocation = nil
        spaceDown = false
        draggingPan = false
        draggingDivider = false
        splitFraction = 0.5
    }

    /// Physical display pixels per image pixel, independent of Retina scale.
    var zoomPercent: Double { Double(zoomScale * displayScale * 100) }
    private var displayScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1 }
    private var viewportSize: NSSize { enclosingScrollView?.contentView.bounds.size ?? bounds.size }

    /// The image's full extent in document-view points, centered when smaller
    /// than the scroll viewport. All mask coordinates pass through this rect.
    var imageRect: NSRect {
        let size = NSSize(width: imageSize.width * zoomScale, height: imageSize.height * zoomScale)
        return NSRect(x: max(margin, (bounds.width - size.width) / 2),
                      y: max(margin, (bounds.height - size.height) / 2), width: size.width, height: size.height)
    }

    func imagePoint(from point: NSPoint) -> NSPoint {
        let image = imageRect
        return NSPoint(x: (point.x - image.minX) / zoomScale, y: (point.y - image.minY) / zoomScale)
    }

    func viewRect(for imagePixelRect: NSRect) -> NSRect {
        let image = imageRect
        return NSRect(x: image.minX + imagePixelRect.minX * zoomScale,
                      y: image.minY + imagePixelRect.minY * zoomScale,
                      width: imagePixelRect.width * zoomScale, height: imagePixelRect.height * zoomScale)
    }

    func fitToWindow() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        fitted = true
        let viewport = viewportSize
        guard viewport.width > 2 * margin, viewport.height > 2 * margin else { return }
        zoomScale = max(0.00001, min((viewport.width - 2 * margin) / imageSize.width, (viewport.height - 2 * margin) / imageSize.height))
        updateDocumentFrame()
        if let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        onZoomChange?(zoomPercent)
        needsDisplay = true
    }

    func zoom100() { setZoom(1 / displayScale, anchor: viewportCenterImagePoint()) }

    func zoom(by multiplier: Double) {
        guard multiplier.isFinite, multiplier > 0 else { return }
        setZoom(zoomScale * CGFloat(multiplier), anchor: viewportCenterImagePoint())
    }

    func focusRegion(id: Int) {
        guard let region = regionsByID[id] else { return }
        selectedRegionID = id
        let center = NSPoint(x: region.rect.midX, y: region.rect.midY)
        if zoomScale * displayScale < 1 { setZoom(1 / displayScale, anchor: center) }
        else { positionImagePoint(center) }
        needsDisplay = true
    }

    private func updateDocumentFrame() {
        let viewport = viewportSize
        setFrameSize(NSSize(width: max(viewport.width, imageSize.width * zoomScale + 2 * margin),
                            height: max(viewport.height, imageSize.height * zoomScale + 2 * margin)))
        clearHover()
        updateInspectionOverlay()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func viewportCenterImagePoint() -> NSPoint {
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        return imagePoint(from: NSPoint(x: visible.midX, y: visible.midY))
    }

    private func setZoom(_ value: CGFloat, anchor: NSPoint, viewportOffset: NSPoint? = nil) {
        guard imageSize.width > 0, value.isFinite else { return }
        let next = max(0.00001, min(16 / displayScale, value))
        guard next != zoomScale else { return }
        fitted = false
        zoomScale = next
        updateDocumentFrame()
        positionImagePoint(anchor, at: viewportOffset)
        onZoomChange?(zoomPercent)
    }

    private func positionImagePoint(_ imagePoint: NSPoint, at viewportOffset: NSPoint? = nil) {
        guard let scroll = enclosingScrollView else { return }
        let view = viewRect(for: NSRect(x: imagePoint.x, y: imagePoint.y, width: 0, height: 0))
        let clip = scroll.contentView
        let offset = viewportOffset ?? NSPoint(x: clip.bounds.width / 2, y: clip.bounds.height / 2)
        let origin = NSPoint(x: view.minX - offset.x, y: view.minY - offset.y)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func zoomAtPointer(by multiplier: CGFloat, event: NSEvent) {
        guard activeStroke == nil, !draggingPan, !draggingDivider else { return }
        let point = convert(event.locationInWindow, from: nil)
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let offset = NSPoint(x: point.x - visible.minX, y: point.y - visible.minY)
        setZoom(zoomScale * multiplier, anchor: imagePoint(from: point), viewportOffset: offset)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.069, green: 0.074, blue: 0.079, alpha: 1).setFill()
        dirtyRect.fill()
        guard let source = sourceImage, let cleaned = cleanedImage, imageSize.width > 0 else { return }
        let rect = imageRect
        let visible = enclosingScrollView?.documentVisibleRect ?? dirtyRect
        let cropped = visible.intersection(rect)
        let splitX = rect.minX + rect.width * CGFloat(splitFraction)
        let repairClip = mode == .split
            ? dirtyRect.intersection(NSRect(x: splitX, y: rect.minY, width: rect.maxX - splitX, height: rect.height))
            : dirtyRect
        let frames = displayFrames(in: cropped)
        switch mode {
        case .original:
            drawRaster(source, cached: frames.source, clip: dirtyRect)
        case .repaired:
            drawRaster(cleaned, cached: frames.cleaned, clip: dirtyRect)
        case .split:
            let sourceClip = dirtyRect.intersection(NSRect(x: rect.minX, y: rect.minY, width: splitX - rect.minX, height: rect.height))
            drawRaster(source, cached: frames.source, clip: sourceClip)
            drawRaster(cleaned, cached: frames.cleaned, clip: repairClip)
        }
        if showMask && maskOpacity > 0 && mode != .original, let maskImage {
            drawRaster(maskImage, cached: frames.mask, clip: repairClip)
        }
        if showRegions { drawRegions(in: dirtyRect) }
        drawBrushFeedback(in: dirtyRect)
        if mode == .split {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: splitX, y: rect.minY))
            line.line(to: NSPoint(x: splitX, y: rect.maxY))
            NSColor.black.withAlphaComponent(0.35).setStroke()
            line.lineWidth = 4
            line.stroke()
            StudioStyle.laser.setStroke()
            line.lineWidth = 2
            line.stroke()
            let visible = enclosingScrollView?.documentVisibleRect ?? bounds
            let grip = NSRect(x: splitX - 10, y: max(rect.minY + 12, visible.minY + 22), width: 20, height: 32)
            NSColor(calibratedWhite: 0.12, alpha: 0.9).setFill(); NSBezierPath(roundedRect: grip, xRadius: 8, yRadius: 8).fill()
            drawCaption("◀ ▶", at: NSPoint(x: grip.minX - 1, y: grip.minY + 7), fontSize: 10)
        }
        drawModeCaptions()
        drawInspectionCaption()
        if !isDisplayReady && !cropped.isEmpty {
            let loading = zoomPercent >= 100 ? L10n.surface("正在载入原始像素…") : L10n.surface("正在载入预览…")
            drawCaption(loading, at: NSPoint(x: cropped.minX + 16, y: cropped.maxY - 30))
        }
    }

    private func pixelRect(for visible: NSRect) -> NSRect {
        let start = imagePoint(from: visible.origin)
        return NSRect(x: start.x, y: start.y, width: visible.width / zoomScale, height: visible.height / zoomScale)
            .integral.intersection(NSRect(origin: .zero, size: imageSize))
    }

    private func displayFrames(in visible: NSRect) -> (source: PreviewRasterFrame?, cleaned: PreviewRasterFrame?, mask: PreviewRasterFrame?) {
        guard usesDisplayCache, !visible.isEmpty else { return (nil, nil, nil) }
        let full = NSRect(origin: .zero, size: imageSize)
        let deviceScale = min(1, zoomScale * displayScale)
        let longSide = max(imageSize.width, imageSize.height)
        let standardOverviewScale = min(1, 2560 / longSide)
        let overviewScale = conserveMemory ? min(1, 1600 / longSide) : standardOverviewScale
        let overview = deviceScale <= standardOverviewScale || (conserveMemory && fitted && deviceScale < 1)
        let needed = overview ? full : pixelRect(for: visible)
        let prefetch: CGFloat = conserveMemory ? 24 : 96
        let extent = overview ? full : needed.insetBy(dx: -prefetch, dy: -prefetch).intersection(full)
        let scaleSteps: CGFloat = conserveMemory ? 8 : 4
        let scale = overview ? overviewScale : min(1, (deviceScale * scaleSteps).rounded(.up) / scaleSteps)

        var missing: [PreviewRaster] = []
        func frame(for asset: PreviewRaster?) -> PreviewRasterFrame? {
            guard let asset, !asset.failed else { return nil }
            if let cached = asset.frame(covering: needed, scale: scale) { return cached }
            missing.append(asset)
            if let viewport = asset.viewport, viewport.pixels.contains(needed) { return viewport }
            return asset.overview ?? asset.fallback ?? asset.viewport
        }
        let needsMask = mode != .original && showMask && maskOpacity > 0
        if conserveMemory {
            if mode == .repaired { sourceImage?.discardFrames() }
            if mode == .original { cleanedImage?.discardFrames() }
            if !needsMask { maskImage?.discardFrames() }
        }
        let source = mode == .repaired ? nil : frame(for: sourceImage)
        let cleaned = mode == .original ? nil : frame(for: cleanedImage)
        let mask = needsMask ? frame(for: maskImage) : nil
        isDisplayReady = missing.isEmpty
        if !missing.isEmpty { renderFrames(missing, pixels: extent, scale: scale, overview: overview) }
        return (source, cleaned, mask)
    }

    private func renderFrames(_ assets: [PreviewRaster], pixels: NSRect, scale: CGFloat, overview: Bool) {
        // Only the current viewport is requested after the active render completes.
        // Scroll, zoom and brush events cannot queue an unbounded set of TIFF decodes.
        guard !rasterizing else { return }
        rasterizing = true
        renderQueue.async { [weak self, metalRenderer, conserveMemory] in
            let frames = assets.map { asset in
                autoreleasepool {
                    PreviewRasterFrame.render(asset.image, pixels: pixels, scale: scale, isMask: asset.isMask,
                                              metal: metalRenderer, conserveMemory: conserveMemory)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (asset, frame) in zip(assets, frames) {
                    guard asset === self.sourceImage || asset === self.cleanedImage || asset === self.maskImage else { continue }
                    if overview {
                        asset.overview = frame
                        if conserveMemory { asset.viewport = nil }
                    } else {
                        asset.viewport = frame
                        if conserveMemory { asset.overview = nil }
                    }
                    asset.fallback = nil
                    asset.failed = frame == nil
                }
                self.rasterizing = false
                self.setNeedsDisplay(self.visibleRect)
            }
        }
    }

    private func drawRaster(_ asset: PreviewRaster, cached: PreviewRasterFrame?, clip: NSRect) {
        let visible = clip.intersection(imageRect)
        guard !visible.isEmpty else { return }
        if let cached {
            drawRasterImage(cached.image, pixels: cached.pixels, clip: visible, isMask: asset.isMask)
            return
        }
        guard !usesDisplayCache || asset.failed else { return }
        let full = NSRect(origin: .zero, size: imageSize)
        if asset.isMask {
            let pixels = pixelRect(for: visible)
            if let crop = asset.image.cropping(to: pixels) {
                drawRasterImage(crop, pixels: pixels, clip: visible, isMask: true)
            }
        } else {
            drawRasterImage(asset.image, pixels: full, clip: visible, isMask: false)
        }
    }

    private func drawRasterImage(_ image: CGImage, pixels: NSRect, clip: NSRect, isMask: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let target = viewRect(for: pixels)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: clip)
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = zoomPercent >= 100 ? .none : (isMask ? .medium : .high)
        let local = NSRect(origin: .zero, size: target.size)
        if isMask {
            context.clip(to: local, mask: image)
            context.setFillColor(maskColor.color.withAlphaComponent(maskOpacity).cgColor)
            context.fill(local)
        } else {
            context.draw(image, in: local)
        }
    }

    private func drawBrushFeedback(in dirtyRect: NSRect) {
        let target = imageRect.intersection(dirtyRect)
        guard !target.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: target).addClip()
        for stroke in pendingStrokes { drawStroke(stroke) }
        if let activeStroke { drawStroke(activeStroke) }
        guard tool != .inspect, !spaceDown, let point = brushLocation, imageRect.contains(point) else { return }
        let radius = max(2, CGFloat(brushRadius) * zoomScale)
        let ring = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
        NSColor.black.withAlphaComponent(0.8).setStroke()
        ring.lineWidth = 2.5
        ring.stroke()
        (tool == .add ? maskColor.color : maskColor.eraserColor).setStroke()
        ring.lineWidth = 1.1
        ring.stroke()
    }

    private func drawStroke(_ stroke: ReviewStroke) {
        guard let first = stroke.points.first else { return }
        let diameter = max(3, CGFloat(2 * stroke.radius) * zoomScale)
        let color = (stroke.tool == .add ? maskColor.color : maskColor.eraserColor).withAlphaComponent(0.4)
        let start = viewRect(for: NSRect(x: first.x + 0.5, y: first.y + 0.5, width: 0, height: 0)).origin
        if stroke.points.count == 1 {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: start.x - diameter / 2, y: start.y - diameter / 2, width: diameter, height: diameter)).fill()
            return
        }
        let line = NSBezierPath()
        line.move(to: start)
        for point in stroke.points.dropFirst() {
            line.line(to: viewRect(for: NSRect(x: point.x + 0.5, y: point.y + 0.5, width: 0, height: 0)).origin)
        }
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.lineWidth = diameter
        color.setStroke()
        line.stroke()
    }

    private func drawRegions(in dirtyRect: NSRect) {
        let markerColor = maskColor.color.withAlphaComponent(0.95)
        for region in regions {
            let box = ringRect(region)
            guard box.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { continue }
            let excluded = excludedRegions.contains(region.id)
            let selected = selectedRegionID == region.id
            let path = NSBezierPath(ovalIn: box)
            path.lineWidth = selected ? 2.5 : 1.5
            (excluded ? NSColor.systemGray : markerColor).setStroke()
            if excluded { var dash: [CGFloat] = [4, 3]; path.setLineDash(&dash, count: dash.count, phase: 0) }
            path.stroke()
            if selected {
                NSColor.white.withAlphaComponent(0.95).setStroke()
                let outer = NSBezierPath(ovalIn: box.insetBy(dx: -3, dy: -3)); outer.lineWidth = 1; outer.stroke()
            }
        }
    }

    private func ringRect(_ region: DustRegion) -> NSRect {
        let rect = viewRect(for: region.rect)
        let size = NSSize(width: max(12, rect.width + 6), height: max(12, rect.height + 6))
        return NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func drawModeCaptions() {
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let image = imageRect
        let left = max(image.minX + 10, visible.minX + 10), top = max(image.minY + 10, visible.minY + 10)
        switch mode {
        case .original: drawCaption(L10n.text("原图"), at: NSPoint(x: left, y: top))
        case .repaired: drawCaption(L10n.text("修复后"), at: NSPoint(x: left, y: top))
        case .split:
            let divider = image.minX + image.width * CGFloat(splitFraction)
            if divider > visible.minX + 70 { drawCaption(L10n.text("原图"), at: NSPoint(x: left, y: top)) }
            if divider < visible.maxX - 70 { drawCaption(L10n.text("修复后"), at: NSPoint(x: max(divider + 14, visible.minX + 10), y: top)) }
        }
    }

    private func drawCaption(_ text: String, at point: NSPoint, fontSize: CGFloat = 12) {
        let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.white])
        let size = label.size()
        let box = NSRect(origin: NSPoint(x: point.x - 5, y: point.y - 3), size: NSSize(width: size.width + 10, height: size.height + 6))
        NSColor(calibratedWhite: 0.06, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: point)
    }

    private var inspectionCaption: String? {
        guard inspectionAnchor != nil, let id = selectedRegionID, let region = regionsByID[id] else { return nil }
        let status = excludedRegions.contains(region.id) ? L10n.surface("已排除") : L10n.surface("待修复")
        return "\(L10n.text("第 \(region.id) 处")) · \(region.categoryLabel) · \(status)"
    }

    private struct SpotCaption {
        let label: NSAttributedString
        let frame: NSRect

        func draw() {
            NSColor(calibratedWhite: 0.06, alpha: 0.88).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5).fill()
            // [Claude 2026-11-08] Without .usesLineFragmentOrigin the rect's origin is taken as the
            // baseline, so in this flipped view the glyphs rose above the bubble. Only the bubble
            // is invalidated when it moves, so those glyphs were left behind on the image.
            label.draw(with: frame.insetBy(dx: 5, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private var inspectionViewport: NSRect { (enclosingScrollView?.documentVisibleRect ?? bounds).intersection(bounds) }

    private func spotLabel(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                           .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    }

    private func overlayOrigin(near anchor: NSPoint, size: NSSize, inside viewport: NSRect) -> NSPoint {
        let x = anchor.x + 12 + size.width <= viewport.maxX ? anchor.x + 12 : anchor.x - 12 - size.width
        let y = anchor.y + 12 + size.height <= viewport.maxY ? anchor.y + 12 : anchor.y - 12 - size.height
        return NSPoint(x: max(viewport.minX, min(x, viewport.maxX - size.width)),
                       y: max(viewport.minY, min(y, viewport.maxY - size.height)))
    }

    private func updateInspectionAccessibility() {
        setAccessibilityValue(inspectionCaption)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func drawInspectionCaption() {
        drawHoverGlow()
        inspectionBubble?.draw()
        hoverBubble?.draw()
    }

    // [Claude 2026-11-08] The repair under the pointer pulses with a soft glowing ring, so it
    // is clear which spot the caption and a click refer to.
    private var hoverGlowRegionID: Int?
    private var hoverGlowTimer: Timer?
    private var hoverGlowStart = Date()

    private func hoverGlowRect() -> NSRect? {
        guard let id = hoverGlowRegionID, let region = regionsByID[id] else { return nil }
        return ringRect(region).insetBy(dx: -4, dy: -4)
    }

    private func setHoverGlow(_ id: Int?) {
        guard id != hoverGlowRegionID else { return }
        if let old = hoverGlowRect() { setNeedsDisplay(old.insetBy(dx: -14, dy: -14)) }
        hoverGlowRegionID = id
        hoverGlowTimer?.invalidate()
        hoverGlowTimer = nil
        guard id != nil else { return }
        hoverGlowStart = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let rect = self.hoverGlowRect() else { return }
            self.setNeedsDisplay(rect.insetBy(dx: -14, dy: -14))
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverGlowTimer = timer
    }

    private func drawHoverGlow() {
        guard let rect = hoverGlowRect() else { return }
        let phase = 0.5 + 0.5 * sin(Date().timeIntervalSince(hoverGlowStart) * 2 * .pi / 1.1)
        let alpha = 0.45 + 0.55 * phase
        let color = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.35, alpha: 1)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.9 * alpha)
        shadow.shadowBlurRadius = 6 + 6 * phase
        shadow.shadowOffset = .zero
        shadow.set()
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = 1.5 + phase
        color.withAlphaComponent(alpha).setStroke()
        ring.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func updateInspectionOverlay() {
        if let old = inspectionBubble { setNeedsDisplay(old.frame.insetBy(dx: -1, dy: -1)) }
        inspectionBubble = nil
        let visible = inspectionViewport, viewport = visible.insetBy(dx: 8, dy: 8)
        guard tool == .inspect, !spaceDown, let anchor = inspectionAnchor.map({ viewRect(for: NSRect(origin: $0, size: .zero)).origin }),
              let caption = inspectionCaption, let id = selectedRegionID, visible.contains(anchor),
              viewport.width > 20, viewport.height > 20 else {
            inspectionActionButton.isHidden = true
            return
        }
        let title = excludedRegions.contains(id) ? L10n.text("恢复识别") : L10n.text("撤销识别")
        if inspectionActionButton.title != title {
            inspectionActionButton.title = title
            inspectionActionButton.setAccessibilityLabel(title)
        }
        let label = spotLabel(caption), textSize = label.size()
        let captionSize = NSSize(width: min(viewport.width, ceil(textSize.width) + 10), height: ceil(textSize.height) + 6)
        let buttonFit = inspectionActionButton.intrinsicContentSize
        let buttonSize = NSSize(width: max(76, ceil(buttonFit.width)), height: max(25, ceil(buttonFit.height)))
        let showAction = onToggleInspectedRegion != nil && buttonSize.width <= viewport.width && captionSize.height + 4 + buttonSize.height <= viewport.height
        let groupSize = showAction ? NSSize(width: max(captionSize.width, buttonSize.width), height: captionSize.height + 4 + buttonSize.height) : captionSize
        let origin = overlayOrigin(near: anchor, size: groupSize, inside: viewport)
        let bubble = SpotCaption(label: label, frame: NSRect(origin: origin, size: captionSize))
        inspectionBubble = bubble
        setNeedsDisplay(bubble.frame.insetBy(dx: -1, dy: -1))
        if showAction {
            inspectionActionButton.frame = NSRect(origin: NSPoint(x: origin.x, y: origin.y + captionSize.height + 4), size: buttonSize)
            inspectionActionButton.toolTip = caption
            inspectionActionButton.isEnabled = isUserInteractionEnabled
        }
        inspectionActionButton.isHidden = !showAction
    }

    @objc private func toggleInspectedRegion() {
        guard isUserInteractionEnabled, tool == .inspect, !inspectionActionButton.isHidden,
              inspectionAnchor != nil, let id = selectedRegionID else { return }
        window?.makeFirstResponder(self)
        onToggleInspectedRegion?(id)
    }

    private func clearHover() {
        if let old = hoverBubble { setNeedsDisplay(old.frame.insetBy(dx: -1, dy: -1)) }
        hoverBubble = nil
        setHoverGlow(nil)
    }

    private func updateHover(at point: NSPoint) {
        clearHover()
        guard isUserInteractionEnabled, isDisplayReady, !spaceDown, !draggingPan, !draggingDivider,
              inspectionViewport.contains(point),
              inspectionActionButton.isHidden || !inspectionActionButton.frame.contains(point),
              let region = region(at: point, allowingMarkers: false),
              region.id != selectedRegionID || inspectionAnchor == nil else { return }
        let viewport = inspectionViewport.insetBy(dx: 8, dy: 8)
        guard viewport.width > 20, viewport.height > 20 else { return }
        setHoverGlow(region.id)
        // Say what a click does: until now it was only discoverable by trying.
        let action = tool == .inspect && onToggleInspectedRegion != nil
            ? (excludedRegions.contains(region.id) ? L10n.text("点击后可恢复此处修复") : L10n.text("点击后可撤销此处修复")) : nil
        let label = spotLabel(action.map { "\(region.categoryLabel) · \($0)" } ?? region.categoryLabel), intrinsic = label.size()
        let size = NSSize(width: min(viewport.width, ceil(intrinsic.width) + 10), height: ceil(intrinsic.height) + 6)
        let preferred = overlayOrigin(near: point, size: size, inside: viewport)
        let positions = [preferred, NSPoint(x: preferred.x, y: point.y - 12 - size.height), NSPoint(x: preferred.x, y: point.y + 12),
                         NSPoint(x: point.x - 12 - size.width, y: preferred.y), NSPoint(x: point.x + 12, y: preferred.y)]
        guard let frame = positions.lazy.map({ NSRect(origin: $0, size: size) }).first(where: {
            viewport.contains($0) && inspectionBubble?.frame.intersects($0) != true &&
                (inspectionActionButton.isHidden || !inspectionActionButton.frame.intersects($0))
        }) else { return }
        hoverBubble = SpotCaption(label: label, frame: frame)
        setNeedsDisplay(frame.insetBy(dx: -1, dy: -1))
    }

    private func region(at point: NSPoint, allowingMarkers: Bool = true) -> DustRegion? {
        let image = imageRect
        let divider = image.minX + image.width * CGFloat(splitFraction)
        let maskVisible = showMask && maskOpacity > 0 && mode != .original && (mode != .split || point.x >= divider)
        if image.contains(point), maskVisible || showRegions,
           let id = spotIndex?.nearest(to: imagePoint(from: point), radius: min(128, 5 / zoomScale),
                                       excluding: showRegions ? [] : excludedRegions),
           let region = regionsByID[id] { return region }
        guard showRegions, allowingMarkers else { return nil }
        return regions.filter { ringRect($0).insetBy(dx: -4, dy: -4).contains(point) }.min { a, b in
            let ar = viewRect(for: a.rect), br = viewRect(for: b.rect)
            let da = pow(ar.midX - point.x, 2) + pow(ar.midY - point.y, 2)
            let db = pow(br.midX - point.x, 2) + pow(br.midY - point.y, 2)
            return da < db
        }
    }

    private func strokePoint(_ point: NSPoint) -> NSPoint {
        let image = imagePoint(from: point)
        return NSPoint(x: min(imageSize.width - 1, max(0, floor(image.x))),
                       y: min(imageSize.height - 1, max(0, floor(image.y))))
    }

    private func appendStrokePoint(_ point: NSPoint) {
        guard let stroke = activeStroke, let previous = stroke.points.last else { return }
        let pixel = strokePoint(point)
        guard previous != pixel else { return }
        let start: NSPoint
        if stroke.points.count < 2048 {
            activeStroke?.points.append(pixel)
            start = previous
        } else {
            activeStroke?.points[2047] = pixel
            start = stroke.points[2046]
        }
        let radius = CGFloat(stroke.radius) + 3 / zoomScale
        let x = min(start.x, pixel.x, previous.x), y = min(start.y, pixel.y, previous.y)
        let w = max(start.x, pixel.x, previous.x) - x, h = max(start.y, pixel.y, previous.y) - y
        setNeedsDisplay(viewRect(for: NSRect(x: x, y: y, width: w, height: h).insetBy(dx: -radius, dy: -radius)))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if tool == .inspect { updateHover(at: point) }
        else { moveBrush(to: point) }
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) { clearHover(); moveBrush(to: nil) }

    private func moveBrush(to point: NSPoint?) {
        let diameter = max(6, CGFloat(2 * brushRadius) * zoomScale + 5)
        for center in [brushLocation, point].compactMap({ $0 }) {
            setNeedsDisplay(NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
        }
        brushLocation = point
    }

    override func mouseDown(with event: NSEvent) {
        guard isUserInteractionEnabled else { return }
        clearHover()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if spaceDown || event.buttonNumber == 2 {
            draggingPan = true
            panStartWindow = event.locationInWindow
            panStartOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
            NSCursor.closedHand.push()
            return
        }
        let divider = imageRect.minX + imageRect.width * CGFloat(splitFraction)
        if mode == .split && imageRect.contains(point) && abs(point.x - divider) < 6 {
            draggingDivider = true
            return
        }
        if tool != .inspect && imageRect.contains(point) {
            guard isDisplayReady else { return }
            activeStroke = ReviewStroke(tool: tool, radius: brushRadius, points: [strokePoint(point)])
            moveBrush(to: point)
            return
        }
        if tool == .inspect, let region = region(at: point) {
            selectedRegionID = region.id
            inspectionAnchor = imagePoint(from: point)
            onSelectRegion?(region.id)
        } else {
            inspectionAnchor = nil
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isUserInteractionEnabled else { return }
        if draggingDivider {
            let point = convert(event.locationInWindow, from: nil)
            splitFraction = Double((point.x - imageRect.minX) / max(1, imageRect.width))
        } else if draggingPan, let scroll = enclosingScrollView {
            let delta = NSPoint(x: event.locationInWindow.x - panStartWindow.x, y: event.locationInWindow.y - panStartWindow.y)
            let proposed = NSPoint(x: panStartOrigin.x - delta.x, y: panStartOrigin.y + delta.y)
            let clip = scroll.contentView
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: proposed, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        } else if activeStroke != nil {
            let point = convert(event.locationInWindow, from: nil)
            moveBrush(to: point)
            appendStrokePoint(point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if draggingPan { NSCursor.pop() }
        draggingPan = false; draggingDivider = false
        if activeStroke != nil {
            appendStrokePoint(convert(event.locationInWindow, from: nil))
            if let stroke = activeStroke {
                activeStroke = nil
                onStroke?(stroke)
            }
            setNeedsDisplay(visibleRect)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isUserInteractionEnabled else { return }
        let key = event.charactersIgnoringModifiers?.lowercased()
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if key == "z" {
            if modifiers == .command { onUndoEdit?(); return }
            if modifiers == [.command, .shift] { onRedoEdit?(); return }
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if key == "v" { onToolChange?(.inspect); return }
            if key == "b" { onToolChange?(.add); return }
            if key == "e" { onToolChange?(.erase); return }
            let characters = event.characters
            if key == "[" || key == "【" || characters == "【" { onBrushRadiusChange?(-1); return }
            if key == "]" || key == "】" || characters == "】" { onBrushRadiusChange?(1); return }
        }
        if event.keyCode == 49 { spaceDown = true; clearHover(); updateInspectionOverlay(); window?.invalidateCursorRects(for: self) }
        else if event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" { zoom(by: 1.25) }
        else if event.charactersIgnoringModifiers == "-" { zoom(by: 0.8) }
        else if event.charactersIgnoringModifiers == "0" { fitToWindow() }
        else { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false; updateInspectionOverlay(); window?.invalidateCursorRects(for: self) }
        else { super.keyUp(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isUserInteractionEnabled else { return }
        clearHover()
        let delta = event.scrollingDeltaY
        guard !spaceDown, delta != 0, abs(delta) >= abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        // Two-finger scrolling carries momentum. A finished gesture should
        // stop changing magnification as soon as the fingers leave the pad.
        guard event.momentumPhase.isEmpty else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.015 : 0.12
        let exponent = min(0.4, max(-0.4, delta * sensitivity))
        zoomAtPointer(by: exp(exponent), event: event)
    }

    override func magnify(with event: NSEvent) {
        guard isUserInteractionEnabled else { return }
        clearHover()
        zoomAtPointer(by: 1 + event.magnification, event: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        if spaceDown { addCursorRect(visibleRect, cursor: .openHand) }
        else {
            let imageVisible = imageRect.intersection(visibleRect)
            if !imageVisible.isNull && !imageVisible.isEmpty { addCursorRect(imageVisible, cursor: .crosshair) }
            if mode == .split {
                let x = imageRect.minX + imageRect.width * CGFloat(splitFraction)
                let gripVisible = NSRect(x: x - 6, y: imageRect.minY, width: 12, height: imageRect.height).intersection(visibleRect)
                if !gripVisible.isNull && !gripVisible.isEmpty { addCursorRect(gripVisible, cursor: .resizeLeftRight) }
            }
        }
    }

    private func readImage(_ url: URL, width: Int, height: Int) throws -> CGImage {
        let source = try imageSource(url)
        try verifySize(source, width: width, height: height)
        // Load the full-resolution CGImage, with lazy decoding. A thumbnail is
        // never substituted for 100% review. ImageIO retains the embedded ICC.
        let options = [kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: true] as CFDictionary
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw previewError(L10n.surface("无法读取 TIFF 预览像素。")) }
        return cgImage
    }

    private func readMask(_ url: URL, width: Int, height: Int) throws -> CGImage {
        let source = try imageSource(url)
        try verifySize(source, width: width, height: height)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.colorSpace?.model == .monochrome, image.alphaInfo == .none else {
            throw previewError(L10n.surface("无法读取灰度蒙版。"))
        }
        return image
    }

    private func imageSource(_ url: URL) throws -> CGImageSource {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1 else {
            throw previewError(L10n.surface("无法打开单帧预览图像：\(url.lastPathComponent)"))
        }
        return source
    }

    private func verifySize(_ source: CGImageSource, width: Int, height: Int) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height else { throw previewError(L10n.surface("预览图像与灰尘蒙版尺寸不一致。")) }
        if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber, orientation.intValue != 1 { throw previewError(L10n.surface("预览图像方向必须为标准方向。")) }
    }

    private func validRegion(_ rect: NSRect, width: Int, height: Int) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite && rect.minX >= 0 && rect.minY >= 0 && rect.width > 0 && rect.height > 0 && rect.maxX <= CGFloat(width) && rect.maxY <= CGFloat(height)
    }

    private func previewError(_ message: String) -> NSError {
        NSError(domain: "PURENegPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
