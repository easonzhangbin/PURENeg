import AppKit
import ImageIO
import QuartzCore

struct BatchLightTableItem {
    let id: UUID
    let url: URL
    let status: String
    let selected: Bool
    let artworkURL: URL
    let displayName: String

    init(id: UUID, url: URL, status: String, selected: Bool, artworkURL: URL? = nil, displayName: String? = nil) {
        self.id = id
        self.url = url
        self.status = status
        self.selected = selected
        self.artworkURL = artworkURL ?? url
        self.displayName = displayName ?? url.lastPathComponent
    }
}

private func neutral(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
}

private func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

private func fill(_ path: NSBezierPath, _ color: NSColor) {
    color.setFill()
    path.fill()
}

private func shade(_ path: NSBezierPath, from top: NSColor, to bottom: NSColor) {
    NSGradient(starting: bottom, ending: top)?.draw(in: path, angle: 90)
}

private func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat = 1) {
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

private func frostedStroke(_ path: NSBezierPath, white: CGFloat, opacity: CGFloat, width: CGFloat) {
    // Attenuate the lamp around the ink as well as through it, so antialiased
    // edge pixels do not have to span the entire HDR brightness range.
    stroke(path, neutral(0.56, 0.12), width: width + 3)
    stroke(path, neutral(0.53, 0.16), width: width + 1.4)
    stroke(path, neutral(white, opacity), width: width)
}

private func castShadow(_ path: NSBezierPath, blur: CGFloat, depth: CGFloat, opacity: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -depth)
    shadow.shadowColor = neutral(0, opacity)
    shadow.set()
    fill(path, .black)
    NSGraphicsContext.restoreGraphicsState()
}

private func engraved(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 9,
                      color: NSColor, weight: NSFont.Weight = .medium) {
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ])
}

// [Claude 2026-11-08] Frosted polypropylene (see claude/CHANGES.md). A sleeve or tray on
// the lamp passes most of the light, but not evenly: the matte surface has a fine grain and
// the sheet never lies quite flat on the glass. Both are drawn as darkening only (black with
// a varying alpha), so they look the same over the SDR diffuser and in the HDR mask.
private enum Frost {
    private static func noise(width: Int, height: Int, seed: UInt32, smoothing: Int) -> CGImage? {
        var state = seed &* 2_654_435_761 &+ 1
        func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / 16_777_216
        }
        var values = (0..<(width * height)).map { _ in next() }
        // Wrap-around box blur, so tiled copies join without a seam.
        for _ in 0..<smoothing {
            var blurred = values
            for y in 0..<height {
                for x in 0..<width {
                    var sum: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            sum += values[((y + dy + height) % height) * width + (x + dx + width) % width]
                        }
                    }
                    blurred[y * width + x] = sum / 9
                }
            }
            values = blurred
        }
        let count = Float(values.count)
        let mean = values.reduce(0, +) / count
        let spread = max(1e-6, (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count).squareRoot())
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in values.indices {
            // Mean one half, three standard deviations to either end.
            let level = 0.5 + (values[i] - mean) / spread / 6
            bytes[4 * i + 3] = UInt8((min(1, max(0, level)) * 255).rounded())
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The matte surface: grain about a point across, tiled.
    private static let grain = noise(width: 128, height: 128, seed: 7, smoothing: 1)

    /// Darkens the inside of `path` by up to `grainDepth` in fine grain and up to
    /// `mottleDepth` in a few broad swells across it (the same swells for the same seed).
    static func texture(_ path: NSBezierPath, seed: Int, grainDepth: CGFloat, mottleDepth: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let grain {
            context.setAlpha(grainDepth)
            context.draw(grain, in: CGRect(x: 0, y: 0, width: 128, height: 128), byTiling: true)
        }
        if let mottle = noise(width: 10, height: 6, seed: UInt32(truncatingIfNeeded: seed &+ 1000), smoothing: 0) {
            context.setAlpha(mottleDepth)
            context.interpolationQuality = .high
            context.draw(mottle, in: path.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A heat-sealed seam: the sleeve's two layers fused into one clearer band, the sealing
/// bar's fine ribs pressed across it and its two edges just visible.
private func weldedSeam(_ band: NSRect, vertical: Bool) {
    guard band.width > 0, band.height > 0 else { return }
    fill(NSBezierPath(rect: band), neutral(1, 0.42))
    let ribs = NSBezierPath()
    let edges = NSBezierPath()
    if vertical {
        var y = band.minY + 0.8
        while y < band.maxY {
            ribs.move(to: NSPoint(x: band.minX, y: y))
            ribs.line(to: NSPoint(x: band.maxX, y: y))
            y += 1.6
        }
        for x in [band.minX, band.maxX] {
            edges.move(to: NSPoint(x: x, y: band.minY))
            edges.line(to: NSPoint(x: x, y: band.maxY))
        }
    } else {
        var x = band.minX + 0.8
        while x < band.maxX {
            ribs.move(to: NSPoint(x: x, y: band.minY))
            ribs.line(to: NSPoint(x: x, y: band.maxY))
            x += 1.6
        }
        for y in [band.minY, band.maxY] {
            edges.move(to: NSPoint(x: band.minX, y: y))
            edges.line(to: NSPoint(x: band.maxX, y: y))
        }
    }
    stroke(ribs, neutral(0.30, 0.07), width: 0.45)
    stroke(edges, neutral(0.30, 0.20), width: 0.5)
}

// [Claude 2026-11-07] HDR light-table surfaces (see claude/CHANGES.md).
// Over the EDR lamp, Core Animation blends in linear light against a backdrop many
// times brighter than SDR white, so antialiased text, hairlines and the edges of the
// tilted strips lose their intermediate shades and look jagged. These surfaces instead
// render their standard lit look over white in gamma space, as without HDR, and hand
// Core Animation only a transmission mask: black with alpha 1 - T. Compositing that
// over the lamp multiplies it by T, so every edge keeps the gradation it was drawn with.
private enum LampTransmission {
    private static let linear: [Float] = (0..<256).map { value in
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    static func mask(bounds: NSRect, flipped: Bool, scale: CGFloat, diffusion: Bool, density: Float = 1,
                     draw: (NSRect) -> Void) -> CGImage? {
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0, width * height <= 16_777_216,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldSmoothFonts(false)
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        if flipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        draw(bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }

        let count = width * height
        let rgba = data.bindMemory(to: UInt8.self, capacity: count * 4)
        var opacity = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let o = 4 * i
            var transmitted = min(1, max(0, 0.2126 * linear[Int(rgba[o])] + 0.7152 * linear[Int(rgba[o + 1])]
                + 0.0722 * linear[Int(rgba[o + 2])]))
            if density < 1 {
                // [Claude 2026-11-08] Darken whatever lies on the lamp, but leave the bare lamp
                // (around the surface, through the sleeve's holes) at full brightness: the
                // factor climbs from density to 1 only over the last few percent.
                let t2 = transmitted * transmitted, t4 = t2 * t2, t8 = t4 * t4, t32 = t8 * t8 * t8 * t8
                transmitted *= density + (1 - density) * t32 * t8
            }
            opacity[i] = 1 - transmitted
        }
        // Print on a frosted sleeve sits in the diffusing plastic: soften it by
        // about a third of a point, as light scattered by the frosting does.
        if diffusion, width > 2, height > 2 {
            var row = [Float](repeating: 0, count: count)
            for y in 0..<height {
                let r = y * width
                for x in 0..<width {
                    let left = opacity[r + max(0, x - 1)], right = opacity[r + min(width - 1, x + 1)]
                    row[r + x] = 0.25 * left + 0.5 * opacity[r + x] + 0.25 * right
                }
            }
            for y in 0..<height {
                let up = max(0, y - 1) * width, down = min(height - 1, y + 1) * width, r = y * width
                for x in 0..<width {
                    opacity[r + x] = 0.25 * row[up + x] + 0.5 * row[r + x] + 0.25 * row[down + x]
                }
            }
        }
        var pixels = [Float16](repeating: 0, count: count * 4)
        for i in 0..<count { pixels[4 * i + 3] = Float16(opacity[i]) }
        let bytes = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let format = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union([.floatComponents, .byteOrder16Little])
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                       bytesPerRow: width * 8, space: linearSpace, bitmapInfo: format,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A surface lying on the diffuser. Under the HDR lamp it is shown as a transmission
/// mask of its standard lit drawing; otherwise AppKit draws it as usual.
private class LampLitSurface: NSView {
    private var maskFailed = false
    var backlight = DiffuserEmission.Mode.off {
        didSet {
            guard oldValue != backlight else { return }
            maskFailed = false
            if !transmitsLamp { layer?.contents = nil }
            backlightDidChange()
            needsDisplay = true
        }
    }

    /// Print and outlines diffused by frosted plastic (sleeves, tray); film is sharp.
    var diffusesPrint: Bool { false }

    /// [Claude 2026-11-08] Under the HDR lamp, the share of its standard-lit transmission this
    /// surface passes. The bare lamp stays at the screen's peak, so a sleeve or the tray reads
    /// as a sheet lying on a far brighter light, as on a real light box.
    var lampDensity: Float { 1 }

    var transmitsLamp: Bool {
        if case .high = backlight { return !maskFailed }
        return false
    }

    override var wantsUpdateLayer: Bool { transmitsLamp }

    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? max(1, layer.contentsScale)
        guard let mask = LampTransmission.mask(bounds: bounds, flipped: isFlipped, scale: scale,
                                               diffusion: diffusesPrint, density: lampDensity, draw: { rect in
            self.drawSurface(rect, lit: .standard)
        }) else {
            // Fall back to drawing the HDR style directly.
            maskFailed = true
            layer.contents = nil
            backlightDidChange()
            needsDisplay = true
            return
        }
        layer.contentsScale = scale
        layer.contents = mask
    }

    override func draw(_ dirtyRect: NSRect) { drawSurface(dirtyRect, lit: backlight) }

    func drawSurface(_ dirtyRect: NSRect, lit mode: DiffuserEmission.Mode) {}
    func backlightDidChange() {}
}

/// Polls the lamp's screen for its potential EDR headroom. Holds the lamp weakly and stops once
/// the lamp is gone, so the timer cannot keep it alive.
@MainActor private final class HeadroomWatch: NSObject {
    private weak var lamp: DiffuserEmission?

    init(lamp: DiffuserEmission) {
        self.lamp = lamp
        super.init()
    }

    @objc func tick(_ timer: Timer) {
        guard let lamp else {
            timer.invalidate()
            return
        }
        lamp.headroomMayHaveChanged()
    }
}

private final class DiffuserEmission: NSView {
    enum Mode: Equatable, Sendable { case off, standard, high(CGFloat) }

    static var switchOffDuration: CFTimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.35
    }

    private static let offImage = standardImage(lit: false)
    private static let litImage = standardImage(lit: true)
    private let emitter = CALayer()
    private let aperture = CAShapeLayer()
    private var renderedMode: Mode?
    private var renderedFilmMode: Mode?
    private var headroomTimer: Timer?
    var modeChanged: ((Mode) -> Void)?
    var filmModeChanged: ((Mode) -> Void)?
    var isEnabled = false {
        didSet {
            if oldValue != isEnabled { switchFeedback(on: isEnabled) }
            updateForDisplay()
        }
    }
    init() {
        super.init(frame: .zero)
        aperture.fillColor = NSColor.white.cgColor
        emitter.mask = aperture
        layer = emitter
        wantsLayer = true
        updateForDisplay()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setApertureFrame(_ frame: NSRect) {
        guard self.frame != frame else { return }
        self.frame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aperture.frame = bounds
        aperture.path = CGPath(roundedRect: aperture.bounds, cornerWidth: 5, cornerHeight: 5, transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        aperture.contentsScale = window?.backingScaleFactor ?? 1
        // [Claude 2026-11-08] The potential headroom changes with screen brightness and posts
        // no notification, so it is polled while the lamp is in a window.
        headroomTimer?.invalidate()
        headroomTimer = nil
        if window != nil {
            let timer = Timer(timeInterval: 0.5, target: HeadroomWatch(lamp: self),
                              selector: #selector(HeadroomWatch.tick(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            headroomTimer = timer
        }
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let window {
            center.addObserver(self, selector: #selector(displayChanged(_:)),
                               name: NSWindow.didChangeScreenNotification, object: window)
            center.addObserver(self, selector: #selector(displayChanged(_:)),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(displayChanged(_:)),
                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        updateForDisplay()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        aperture.contentsScale = window?.backingScaleFactor ?? 1
    }

    @objc private func displayChanged(_ notification: Notification) {
        updateForDisplay()
    }

    func headroomMayHaveChanged() {
        if window?.isVisible == true { updateForDisplay() }
    }

    private func switchFeedback(on: Bool) {
        SwitchClick.play()
        emitter.removeAnimation(forKey: "switch")
        guard !on else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Self.switchOffDuration
        emitter.add(fade, forKey: "switch")
    }

    private func updateForDisplay() {
        var mode: Mode = isEnabled ? .standard : .off
        if #available(macOS 26.0, *), isEnabled, let screen = window?.screen,
           let peak = Self.peak(potential: screen.maximumPotentialExtendedDynamicRangeColorComponentValue) {
            mode = .high(peak)
        }
        if mode == renderedMode {
            updateFilmMode(for: mode)
            return
        }
        var image = isEnabled ? Self.litImage : Self.offImage
        if #available(macOS 26.0, *), case .high(let peak) = mode {
            if let highImage = Self.image(peak: peak) {
                image = highImage
            } else {
                mode = .standard
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.contents = image
        emitter.backgroundColor = neutral(isEnabled ? 0.98 : 0.66).cgColor
        if #available(macOS 26.0, *) {
            if case .high = mode {
                emitter.preferredDynamicRange = .high
            } else {
                emitter.preferredDynamicRange = .standard
            }
        }
        renderedMode = mode
        modeChanged?(mode)
        updateFilmMode(for: mode)
        CATransaction.commit()
    }

    private func updateFilmMode(for lamp: Mode) {
        let film: Mode
        if case .high = lamp, let screen = window?.screen {
            film = Self.filmMode(available: screen.maximumExtendedDynamicRangeColorComponentValue)
        } else {
            film = lamp
        }
        guard film != renderedFilmMode else { return }
        renderedFilmMode = film
        filmModeChanged?(film)
    }

    static func filmMode(available: CGFloat) -> Mode {
        // The light table has its own sustained brightness. Photo highlights can use
        // the full current display headroom, rounded down to avoid exceeding it.
        guard available.isFinite, available > 1 else { return .standard }
        let rounded = (available * 100).rounded(.down) / 100
        return rounded > 1 ? .high(rounded) : .standard
    }

    /// [Claude 2026-11-08] The lamp runs at the brightest the panel holds over a large area.
    /// On Apple's XDR panels the potential headroom is the 1600-nit peak over SDR white, but a
    /// window-sized area is held to about 1000 nits. Asking for the full potential clipped the
    /// lamp, the sleeve and the film base to the same white; following the headroom currently
    /// granted locked the lamp near SDR white, because the screen grants only what is asked
    /// for. So the lamp asks for 1000/1600 of the potential, and screens with little headroom
    /// give all of theirs.
    private static let sustainedShare: CGFloat = 0.625

    static func peak(potential: CGFloat) -> CGFloat? {
        guard potential.isFinite, potential > 1 else { return nil }
        if potential <= 2.5 { return potential }
        let lamp = max(2.5, potential * sustainedShare)
        // In eighths of a stop, rounded down, so brightness drift doesn't re-render every surface.
        return pow(2, (log2(lamp) * 8).rounded(.down) / 8)
    }

    private static let width = 96
    private static let height = 48

    private static func falloff(x: Int, y: Int) -> Double {
        let dx = Double(x) / Double(width - 1) * 2 - 0.91
        let dy = Double(y) / Double(height - 1) * 2 - 0.84
        return min(1, (dx * dx + dy * dy) / 2)
    }

    private static func standardImage(lit: Bool) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let level = lit ? 1 - 0.055 * falloff(x: x, y: y) : 0.72 - 0.15 * falloff(x: x, y: y)
                let value = UInt8((255 * level).rounded())
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let format = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace, bitmapInfo: format,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    @available(macOS 26.0, *)
    static func image(peak: CGFloat) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let level = Float16(peak * (1 - 0.055 * falloff(x: x, y: y)))
                let offset = (y * width + x) * 4
                pixels[offset] = level
                pixels[offset + 1] = level
                pixels[offset + 2] = level
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let alpha = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let format = alpha.union([.floatComponents, .byteOrder16Little])
        return CGImage(headroom: Float(peak), width: width, height: height, bitsPerComponent: 16,
                       bitsPerPixel: 64, bytesPerRow: width * 8, space: colorSpace, bitmapInfo: format,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// One shutter above the lamp and every film surface keeps their ignition pulses in phase.
private final class LampIgnitionShade: NSView {
    private let veil = CALayer()

    init() {
        super.init(frame: .zero)
        veil.backgroundColor = NSColor.black.cgColor
        veil.cornerRadius = 5
        veil.opacity = 0
        layer = veil
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPowered(_ powered: Bool) {
        let opacity = veil.presentation()?.opacity ?? veil.opacity
        veil.removeAnimation(forKey: "switch")
        if powered {
            let flicker = CAKeyframeAnimation(keyPath: "opacity")
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                flicker.values = [0.9, 0.0]
                flicker.duration = 0.35
            } else {
                flicker.values = [0.9, 0.9, 0.35, 0.9, 0.9, 0.15, 0.85, 0.85, 0.4, 0.5, 0.25, 0.32, 0.0]
                flicker.keyTimes = [0, 0.10, 0.14, 0.20, 0.33, 0.38, 0.44, 0.52, 0.58, 0.66, 0.74, 0.82, 1]
                flicker.duration = 1.0
            }
            veil.add(flicker, forKey: "switch")
        } else if opacity > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            fade.duration = DiffuserEmission.switchOffDuration
            veil.add(fade, forKey: "switch")
        }
    }
}

private final class DiffuserSwitch: NSButton {
    var changed: ((Bool) -> Void)?

    init(enabled: Bool) {
        super.init(frame: .zero)
        setAccessibilityLabel(L10n.surface("观片器电源"))
        setAccessibilityRole(.checkBox)
        setButtonType(.pushOnPushOff)
        state = enabled ? .on : .off
        isBordered = false
        focusRingType = .exterior
        target = self
        action = #selector(toggleEmission)
    }

    required init?(coder: NSCoder) { nil }

    override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    @objc private func toggleEmission() {
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
        changed?(state == .on)
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = state == .on
        let caseShape = rounded(bounds.insetBy(dx: 1, dy: 1), 6)
        shade(caseShape, from: neutral(0.12), to: neutral(0.03))
        stroke(caseShape, neutral(0.40), width: 0.65)
        let buttonFace = rounded(bounds.insetBy(dx: 3.5, dy: 3.5), 4.5)
        shade(buttonFace, from: neutral(active ? 0.27 : 0.21), to: neutral(active ? 0.19 : 0.10))
        stroke(buttonFace, neutral(1, active ? 0.22 : 0.13), width: 0.65)
        let indicator = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 18, y: bounds.midY - 3.25,
                                                    width: 6.5, height: 6.5))
        let indicatorColor = active
            ? NSColor(srgbRed: 0.26, green: 0.88, blue: 0.43, alpha: 1)
            : NSColor(srgbRed: 0.94, green: 0.23, blue: 0.24, alpha: 1)
        fill(indicator, indicatorColor)
        let symbolStyle = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(.init(paletteColors: [neutral(active ? 0.97 : 0.74)]))
        if let symbol = NSImage(systemSymbolName: "power", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolStyle) {
            let position = NSRect(x: bounds.midX - 1, y: bounds.midY - symbol.size.height / 2,
                                  width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: position, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
        }
    }
}

private final class LightTableDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class FilmFlightOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FrameSlot: NSView {
    private let isArchiveSlot: Bool
    private let tilt: CGFloat
    private weak var card: FrameButton?

    init(isArchiveSlot: Bool = false) {
        self.isArchiveSlot = isArchiveSlot
        tilt = isArchiveSlot ? .random(in: -1.35...1.35) : 0
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    func mount(_ card: FrameButton) {
        let oldSlot = card.superview as? FrameSlot
        card.removeFromSuperview()
        addSubview(card)
        self.card = card
        oldSlot?.needsDisplay = true
        needsDisplay = true
        positionCard()
    }

    override func layout() {
        super.layout()
        positionCard()
    }

    private var cardFrame: NSRect {
        let sine = abs(sin(tilt * .pi / 180))
        return bounds.insetBy(dx: ceil(bounds.height * sine / 2), dy: ceil(bounds.width * sine / 2))
    }

    var cardSize: NSSize { cardFrame.size }

    private func positionCard() {
        guard let card, card.superview === self else { return }
        card.frameRotation = 0
        card.frame = cardFrame
        card.frameCenterRotation = tilt
        card.needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isArchiveSlot, card?.superview !== self, bounds.width > 6, bounds.height > 6 else { return }
        let outline = rounded(bounds.insetBy(dx: 3, dy: 3), 3)
        outline.setLineDash([4, 3], count: 2, phase: 0)
        stroke(outline, neutral(0.7, 0.42), width: 0.75)
    }
}

private final class CandidateTray: LampLitSurface {
    private let title = NSTextField(labelWithString: L10n.surface("候选区 · 点击下方底片移入"))
    private let inset: CGFloat = 12
    private let gap: CGFloat = 10
    private let headerHeight: CGFloat = 27
    private var slots: [UUID: FrameSlot] = [:]
    private(set) var ids: [UUID] = []

    override var diffusesPrint: Bool { true }
    // About three quarters of the lamp passes the tray (0.9 x its standard-lit 0.83).
    override var lampDensity: Float { 0.9 }

    override func backlightDidChange() {
        // Under the HDR lamp the title is printed into the tray's transmission mask.
        title.isHidden = transmitsLamp
        if case .high = backlight {
            title.textColor = neutral(0.35, 0.76)
        } else {
            title.textColor = neutral(0.22)
        }
    }

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = neutral(0.22)
        addSubview(title)
    }

    required init?(coder: NSCoder) { nil }

    func update(_ ids: [UUID]) {
        self.ids = ids
        let keep = Set(ids)
        for (id, slot) in slots where !keep.contains(id) { slot.removeFromSuperview() }
        slots = slots.filter { keep.contains($0.key) }
        for id in ids where slots[id] == nil {
            let slot = FrameSlot()
            slots[id] = slot
            addSubview(slot)
        }
        title.stringValue = ids.isEmpty
            ? L10n.surface("候选区 · 点击下方底片移入")
            : L10n.surface("候选区 · \(ids.count) 帧 · 点击可放回")
        needsDisplay = true
    }

    func slot(for id: UUID) -> FrameSlot? { slots[id] }

    func visibleIDs(in rect: NSRect) -> [UUID] {
        let area = convert(rect, from: superview)
        return ids.filter { slots[$0]?.frame.intersects(area) == true }
    }

    func arrange(at origin: NSPoint, width: CGFloat, cardSize: (UUID) -> NSSize?) {
        let availableWidth = max(0, width - 2 * inset)
        var rows: [[(id: UUID, size: NSSize)]] = []
        var row: [(id: UUID, size: NSSize)] = []
        var rowWidth: CGFloat = 0
        for id in ids {
            guard let size = cardSize(id), size.width > 0, size.height > 0 else { continue }
            if !row.isEmpty, rowWidth + gap + size.width > availableWidth {
                rows.append(row)
                row = []
                rowWidth = 0
            }
            rowWidth += size.width + (row.isEmpty ? 0 : gap)
            row.append((id, size))
        }
        if !row.isEmpty { rows.append(row) }

        let rowHeights = rows.map { $0.map { $0.size.height }.max() ?? 0 }
        let contentHeight = rowHeights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * gap
        let height = headerHeight + contentHeight + (rows.isEmpty ? 0 : inset)
        frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        title.frame = NSRect(x: inset, y: bounds.maxY - 21, width: max(0, bounds.width - 2 * inset), height: 15)
        var rowTop = bounds.maxY - headerHeight
        for (cards, rowHeight) in zip(rows, rowHeights) {
            let occupiedWidth = cards.reduce(0) { $0 + $1.size.width } + CGFloat(cards.count - 1) * gap
            var x = (width - occupiedWidth) / 2
            for (id, size) in cards {
                let y = rowTop - (rowHeight + size.height) / 2
                slots[id]?.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
                x += size.width + gap
            }
            rowTop -= rowHeight + gap
        }
        if transmitsLamp { needsDisplay = true }
    }

    override func drawSurface(_ dirtyRect: NSRect, lit mode: DiffuserEmission.Mode) {
        let outline = rounded(bounds.insetBy(dx: 1, dy: 1), 6)
        defer {
            if transmitsLamp, !title.stringValue.isEmpty, let font = title.font {
                (title.stringValue as NSString).draw(in: title.frame.insetBy(dx: 2, dy: 0), withAttributes: [
                    .font: font, .foregroundColor: neutral(0.22)
                ])
            }
        }
        if case .high = mode {
            // Reduce transmitted light so the tray stays visible against the HDR diffuser.
            shade(outline, from: neutral(0.32, 0.54), to: neutral(0.28, 0.61))
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            let header = NSBezierPath(rect: NSRect(x: 0, y: bounds.maxY - 30, width: bounds.width, height: 30))
            shade(header, from: neutral(0.47, 0.36), to: neutral(0.47, 0))
            NSGraphicsContext.restoreGraphicsState()
            frostedStroke(rounded(bounds.insetBy(dx: 3.5, dy: 3.5), 4),
                          white: 0.48, opacity: 0.48, width: 0.7)
        } else if mode != .off {
            // [Claude 2026-11-08] Frosted like the sleeve, a little clearer, with a seal under
            // the header. This is also the HDR look, through LampTransmission.
            fill(outline, neutral(0.31, 0.11))
            Frost.texture(outline, seed: 97, grainDepth: 0.06, mottleDepth: 0.07)
            if bounds.height > headerHeight + 8 {
                NSGraphicsContext.saveGraphicsState()
                outline.addClip()
                weldedSeam(NSRect(x: 8, y: bounds.maxY - headerHeight - 1.2,
                                  width: max(0, bounds.width - 16), height: 2.4), vertical: false)
                NSGraphicsContext.restoreGraphicsState()
            }
            stroke(rounded(bounds.insetBy(dx: 2.2, dy: 2.2), 5), neutral(1, 0.36), width: 1.1)
            stroke(outline, neutral(0.26, 0.36), width: 0.7)
        } else {
            fill(outline, neutral(0.31, 0.10))
            stroke(outline, neutral(0.24, 0.34), width: 0.8)
        }
    }
}

private enum FilmOrientationAction: Int {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    var turn: Int {
        switch self {
        case .rotateLeft: return -1
        case .rotateRight: return 1
        default: return 0
        }
    }
}

private struct FilmOrientation {
    private(set) var quarterTurns = 0
    private(set) var scaleX: CGFloat = 1
    private(set) var scaleY: CGFloat = 1
    var swapsAxes: Bool { quarterTurns % 2 != 0 }

    mutating func apply(_ action: FilmOrientationAction) {
        switch action {
        case .rotateLeft, .rotateRight:
            quarterTurns = (quarterTurns + action.turn + 4) % 4
        case .flipHorizontal:
            if swapsAxes { scaleY *= -1 } else { scaleX *= -1 }
        case .flipVertical:
            if swapsAxes { scaleX *= -1 } else { scaleY *= -1 }
        }
    }

    var sourceToDisplay: CGAffineTransform {
        CGAffineTransform(translationX: -0.5, y: -0.5)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2))
            .concatenating(CGAffineTransform(translationX: 0.5, y: 0.5))
    }
}

private final class LightTable: NSView {
    private let singleFrame: Bool
    private let viewingRepair: Bool
    private let lowerRailHeight: CGFloat = 50
    private let emission = DiffuserEmission()
    private let ignitionShade = LampIgnitionShade()
    private let power = DiffuserSwitch(enabled: false)
    private let loupe: FilmLoupe?
    private let scroll = NSScrollView()
    private let document = LightTableDocument()
    private let tray = CandidateTray()
    private let flightOverlay = FilmFlightOverlay()
    private let empty = NSTextField(labelWithString: L10n.surface("尚未载入照片"))
    private var singleCard: FrameButton?
    private var pages: [ArchivalSleeve] = []
    private var orderedIDs: [UUID] = []
    private var cells: [UUID: FrameButton] = [:]
    private var archiveSlots: [UUID: FrameSlot] = [:]
    private var flights: [UUID: FrameButton] = [:]
    private var visibleCells: [FrameButton] = []
    private var backlight = DiffuserEmission.Mode.off
    private var filmBacklight = DiffuserEmission.Mode.off
    private var filmLightAdjustment = FilmLightAdjustment.defaultValue
    private var placingPages = false
    private var updatingFrames = false
    private let thumbnails = NSCache<NSURL, NSImage>()
    private let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PURE Neg thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var pending: Set<URL> = []
    private var unreadable: Set<URL> = []
    private var repairAnimationID: UUID?
    private var pendingRepairOrientations: [FilmOrientationAction] = []
    var onSelect: ((UUID) -> Void)?
    var onRepairedGeometryChange: (() -> Void)?
    var onLampPowerChange: ((Bool) -> Void)?
    var onFilmHeadroomChange: (() -> Void)?

    var filmHeadroom: Float {
        if case .high(let peak) = filmBacklight { return Float(peak) }
        return 1
    }

    init(singleFrame: Bool, viewingRepair: Bool = false) {
        self.singleFrame = singleFrame
        self.viewingRepair = viewingRepair
        loupe = viewingRepair ? FilmLoupe() : nil
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(emission)
        addSubview(scroll)
        addSubview(flightOverlay)
        addSubview(ignitionShade)
        addSubview(power)
        if let loupe {
            addSubview(loupe, positioned: .below, relativeTo: ignitionShade)
            loupe.sourceToBoard = { [weak self] in
                guard let self,
                      let topLeft = repairedDisplayPoint(for: .zero, in: self),
                      let topRight = repairedDisplayPoint(for: CGPoint(x: 1, y: 0), in: self),
                      let bottomLeft = repairedDisplayPoint(for: CGPoint(x: 0, y: 1), in: self) else { return nil }
                return CGAffineTransform(a: topRight.x - topLeft.x, b: topRight.y - topLeft.y,
                                         c: bottomLeft.x - topLeft.x, d: bottomLeft.y - topLeft.y,
                                         tx: topLeft.x, ty: topLeft.y)
            }
            loupe.thumbnail = { [weak self] in
                self?.singleCard?.loupeRaster
            }
            onRepairedGeometryChange = { [weak loupe] in loupe?.geometryChanged() }
        }
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        empty.textColor = neutral(0.30)
        empty.font = .systemFont(ofSize: 14, weight: .medium)
        empty.alignment = .center
        tray.isHidden = true
        document.addSubview(tray)
        document.addSubview(empty)
        flightOverlay.wantsLayer = true
        flightOverlay.layer?.cornerRadius = 5
        flightOverlay.layer?.masksToBounds = true
        thumbnails.totalCostLimit = 32 * 1024 * 1024

        emission.modeChanged = { [weak self] mode in
            guard let self else { return }
            backlight = mode
            tray.backlight = mode
            for page in pages { page.backlight = mode }
        }
        emission.filmModeChanged = { [weak self] mode in
            guard let self else { return }
            filmBacklight = mode
            for cell in visibleCells { cell.setBacklight(mode) }
            for flight in flights.values { flight.setBacklight(mode) }
            updateLoupeLighting()
            onFilmHeadroomChange?()
        }
        power.changed = { [weak self] enabled in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            emission.isEnabled = enabled
            ignitionShade.setPowered(enabled)
            CATransaction.commit()
            onLampPowerChange?(enabled)
        }
    }

    required init?(coder: NSCoder) { nil }

    func clearHover() {
        for cell in visibleCells { cell.setHovered(false, animated: false) }
    }

    func setFilmLightAdjustment(_ adjustment: FilmLightAdjustment) {
        guard filmLightAdjustment != adjustment else { return }
        filmLightAdjustment = adjustment
        for cell in visibleCells { cell.setFilmLightAdjustment(adjustment) }
        for flight in flights.values { flight.setFilmLightAdjustment(adjustment) }
        updateLoupeLighting()
    }

    private func updateLoupeLighting() {
        guard let loupe else { return }
        let mode = filmBacklight
        let adjustment = filmLightAdjustment
        let isHDR: Bool
        if case .high = mode { isHDR = true } else { isHDR = false }
        if mode == .off {
            loupe.setLighting(isHDR: false, renderer: nil)
        } else {
            loupe.setLighting(isHDR: isHDR) { source in
                IlluminatedThumbnail.image(source, mode: mode, adjustment: adjustment, maximumDimension: 1280)
            }
        }
    }

    func update(_ items: [BatchLightTableItem], isEnabled: Bool) {
        if singleFrame {
            updateSingleFrame(items.first)
            return
        }
        let ids = items.map(\.id)
        let rearranged = ids != orderedIDs
        let candidates = items.filter(\.selected).map(\.id)
        let previousCandidates = Set(tray.ids)
        let nextCandidates = Set(candidates)
        let selectionChanged = candidates != tray.ids
        let moved = items.enumerated().filter { _, item in
            previousCandidates.contains(item.id) != nextCandidates.contains(item.id)
        }
        updatingFrames = true
        defer {
            updatingFrames = false
            requestVisibleThumbnails()
        }
        if rearranged || selectionChanged { finishFlights() }
        var origins: [UUID: NSPoint] = [:]
        if !rearranged, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (_, item) in moved {
                guard let card = cells[item.id], !card.visibleRect.isEmpty else { continue }
                origins[item.id] = card.center(in: flightOverlay)
            }
        }
        for (index, item) in items.enumerated() {
            if let cell = cells[item.id] {
                cell.update(item, number: index + 1)
                cell.isEnabled = isEnabled
            } else {
                let cell = FrameButton(item: item, number: index + 1) { [weak self] in
                    self?.onSelect?(item.id)
                }
                cell.isEnabled = isEnabled
                cells[item.id] = cell
            }
        }
        if selectionChanged { tray.update(candidates) }
        if rearranged {
            for cell in cells.values { cell.removeFromSuperview() }
            for page in pages { page.removeFromSuperview() }
            let currentIDs = Set(ids)
            cells = cells.filter { currentIDs.contains($0.key) }
            orderedIDs = ids
            archiveSlots = [:]
            pages = stride(from: 0, to: ids.count, by: 8).map { start in
                let end = min(start + 8, ids.count)
                let frames = ids[start..<end].compactMap { cells[$0] }
                let slots = frames.map { frame in
                    let slot = FrameSlot(isArchiveSlot: true)
                    archiveSlots[frame.id] = slot
                    return slot
                }
                let page = ArchivalSleeve(number: start / 8 + 1, first: start + 1, last: end, frames: frames, frameSlots: slots)
                page.backlight = backlight
                document.addSubview(page)
                return page
            }
            for id in ids {
                if let card = cells[id] { (tray.slot(for: id) ?? archiveSlots[id])?.mount(card) }
            }
            empty.isHidden = !pages.isEmpty
            tray.isHidden = pages.isEmpty
        } else if selectionChanged {
            for (_, item) in moved {
                if let card = cells[item.id] { (tray.slot(for: item.id) ?? archiveSlots[item.id])?.mount(card) }
            }
        }
        if rearranged || selectionChanged {
            needsLayout = true
            if !origins.isEmpty { layoutSubtreeIfNeeded() }
        }
        for (index, item) in moved {
            if let origin = origins[item.id], let card = cells[item.id] {
                animate(card, from: origin, item: item, number: index + 1)
            }
        }
    }

    private func updateSingleFrame(_ item: BatchLightTableItem?) {
        loupe?.setArtwork(item?.artworkURL)
        if let item, let card = singleCard, card.id == item.id {
            card.update(item, number: 1)
        } else {
            repairAnimationID = nil
            pendingRepairOrientations.removeAll()
            singleCard?.removeFromSuperview()
            singleCard = item.map { item in
                let card = FrameButton(item: item, number: 1, selectable: false, viewingRepair: viewingRepair) {}
                card.setFilmLightAdjustment(filmLightAdjustment)
                card.setBacklight(filmBacklight)
                document.addSubview(card)
                return card
            }
        }
        empty.isHidden = singleCard != nil
        needsLayout = true
        requestVisibleThumbnails()
    }

    private var settledRepairCard: FrameButton? {
        guard viewingRepair, repairAnimationID == nil, let card = singleCard, !card.photoRect.isEmpty else { return nil }
        return card
    }

    func repairedDisplayPoint(for sourcePoint: CGPoint, in view: NSView) -> CGPoint? {
        guard let card = settledRepairCard, (0...1).contains(sourcePoint.x), (0...1).contains(sourcePoint.y) else { return nil }
        let rect = card.photoRect
        let display = sourcePoint.applying(card.orientation.sourceToDisplay)
        return card.convert(CGPoint(x: rect.minX + rect.width * display.x,
                                    y: card.isFlipped ? rect.minY + rect.height * display.y : rect.maxY - rect.height * display.y), to: view)
    }

    func changeRepairOrientation(_ action: FilmOrientationAction) {
        if repairAnimationID != nil {
            pendingRepairOrientations.append(action)
            return
        }
        layoutSubtreeIfNeeded()
        guard let card = settledRepairCard else { return }
        let previous = card.orientation
        let previousRect = card.convert(card.photoRect, to: self)
        let animated = window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let id = UUID()
        if animated {
            repairAnimationID = id
            onRepairedGeometryChange?()
        }
        card.orientation.apply(action)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if animated {
            card.animateOrientation(from: previous, previousRect: previousRect, in: self, turn: action.turn) { [weak self] in
                guard let self, repairAnimationID == id else { return }
                repairAnimationID = nil
                if pendingRepairOrientations.isEmpty { onRepairedGeometryChange?() }
                else { changeRepairOrientation(pendingRepairOrientations.removeFirst()) }
            }
        } else {
            onRepairedGeometryChange?()
        }
    }

    private func animate(_ card: FrameButton, from origin: NSPoint, item: BatchLightTableItem, number: Int) {
        let destination = card.center(in: flightOverlay)
        guard let size = archiveSlots[card.id]?.cardSize, size.width > 0, size.height > 0,
              card.frame.width > 0, card.frame.height > 0, origin != destination else { return }
        let start = NSPoint(x: origin.x - size.width / 2, y: origin.y - size.height / 2)
        let end = NSPoint(x: destination.x - size.width / 2, y: destination.y - size.height / 2)
        let movingCard = FrameButton(item: item, number: number) {}
        movingCard.isEnabled = false
        movingCard.setAccessibilityElement(false)
        movingCard.copyArtwork(from: card)
        movingCard.frame = NSRect(origin: start, size: size)
        flightOverlay.addSubview(movingCard)
        flights[card.id] = movingCard
        card.isHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.21
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            movingCard.animator().setFrameOrigin(end)
        } completionHandler: { [weak self, weak movingCard] in
            guard let self, let movingCard, flights[card.id] === movingCard else { return }
            movingCard.removeFromSuperview()
            flights[card.id] = nil
            card.isHidden = false
            requestVisibleThumbnails()
        }
    }

    private func finishFlights() {
        for (id, movingCard) in flights {
            movingCard.removeFromSuperview()
            cells[id]?.isHidden = false
        }
        flights.removeAll()
    }

    @objc private func visibleAreaChanged(_ notification: Notification) {
        requestVisibleThumbnails()
    }

    func cachedThumbnail(for url: URL) -> CGImage? {
        thumbnails.object(forKey: url as NSURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func requestVisibleThumbnails() {
        guard !placingPages, !updatingFrames else { return }
        let newCells: [FrameButton]
        if singleFrame {
            newCells = [singleCard].compactMap { $0 }
        } else {
            let viewport = scroll.contentView.bounds
            let preload = viewport.insetBy(dx: 0, dy: -min(110, viewport.height * 0.25))
            let visiblePages = pages.filter { $0.frame.intersects(preload) }
            let sleeveCells = visiblePages.flatMap(\.frames).filter { tray.slot(for: $0.id) == nil }
            let candidateCells = tray.visibleIDs(in: preload).compactMap { cells[$0] }
            newCells = sleeveCells + candidateCells
        }
        let ids = Set(newCells.map(\.id))
        for cell in visibleCells where !ids.contains(cell.id) { cell.setThumbnail(nil) }
        visibleCells = newCells
        for cell in visibleCells {
            cell.setFilmLightAdjustment(filmLightAdjustment)
            cell.setBacklight(filmBacklight)
        }
        for cell in visibleCells where cell.thumbnail == nil {
            let url = cell.artworkURL
            if let image = thumbnails.object(forKey: url as NSURL) {
                cell.setThumbnail(image)
                if singleFrame {
                    needsLayout = true
                    loupe?.refreshRaster()
                }
            } else if unreadable.contains(url) {
                cell.setUnavailable()
            } else if pending.count < 2, pending.insert(url).inserted {
                let maxPixelSize = singleFrame ? 1600 : 360
                thumbnailQueue.addOperation { [weak self] in
                    let thumbnail = autoreleasepool { Self.thumbnail(at: url, maxPixelSize: maxPixelSize) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        pending.remove(url)
                        if let thumbnail {
                            let image = NSImage(cgImage: thumbnail,
                                                size: NSSize(width: thumbnail.width, height: thumbnail.height))
                            thumbnails.setObject(image, forKey: url as NSURL,
                                                 cost: thumbnail.bytesPerRow * thumbnail.height)
                        } else {
                            unreadable.insert(url)
                        }
                        requestVisibleThumbnails()
                    }
                }
            }
        }
    }

    private static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private var bed: NSRect {
        let caseRect = bounds.insetBy(dx: 8, dy: 9)
        return NSRect(x: caseRect.minX + 25, y: caseRect.minY + lowerRailHeight,
                      width: caseRect.width - 50, height: caseRect.height - lowerRailHeight - 24)
    }

    override func layout() {
        super.layout()
        placingPages = true
        defer {
            placingPages = false
            requestVisibleThumbnails()
            if viewingRepair { onRepairedGeometryChange?() }
        }
        let aperture = bed.insetBy(dx: 2, dy: 2)
        emission.setApertureFrame(aperture)
        flightOverlay.frame = aperture
        ignitionShade.frame = aperture
        scroll.frame = aperture
        let viewport = scroll.contentSize
        if singleFrame {
            document.frame = NSRect(origin: .zero, size: viewport)
            if let card = singleCard {
                card.frame = card.singleFrameRect(in: viewport)
                card.needsLayout = true
            }
        } else {
            arrangeArchive(in: viewport)
        }
        empty.frame = NSRect(x: 0, y: (viewport.height - 20) / 2, width: viewport.width, height: 20)
        let switchSize = NSSize(width: 78, height: 35)
        power.frame = NSRect(x: bed.maxX - switchSize.width,
                             y: bed.minY - (lowerRailHeight + switchSize.height) / 2,
                             width: switchSize.width, height: switchSize.height)
        loupe?.placeDock(in: aperture)
    }

    private func arrangeArchive(in viewport: NSSize) {
        var previousOffset = scroll.contentView.bounds.origin
        let pageWidth = viewport.width * 0.78
        let side = (viewport.width - pageWidth) / 2
        let stripHeight = max(74, (viewport.height * 0.76 - 57) / 2)
        let candidates = Set(tray.ids)
        for page in pages {
            let size = NSSize(width: pageWidth, height: page.height(forStripHeight: stripHeight))
            if page.frame.size != size { page.setFrameSize(size) }
            if page.frames.contains(where: { candidates.contains($0.id) }) { page.layoutSubtreeIfNeeded() }
        }
        let oldTrayEnd = tray.frame.maxY
        let trayTop: CGFloat = 14
        tray.arrange(at: NSPoint(x: side, y: trayTop), width: pageWidth) { archiveSlots[$0]?.cardSize }
        if oldTrayEnd > 0, previousOffset.y >= oldTrayEnd {
            previousOffset.y += tray.frame.maxY - oldTrayEnd
        }
        let margin = min(30, viewport.height * 0.075)
        let archiveTop = tray.frame.maxY + margin
        var y = archiveTop
        for page in pages {
            page.setFrameOrigin(NSPoint(x: side, y: y))
            y += page.frame.height + 24
        }
        let contentHeight = max(viewport.height, y - 24 + margin)
        document.frame = NSRect(x: 0, y: 0, width: viewport.width, height: contentHeight)
        if pages.count == 1, let page = pages.first {
            page.frame.origin.y = max(archiveTop, (contentHeight - page.frame.height + tray.frame.maxY) / 2)
        }
        let restored = NSPoint(x: 0, y: min(max(0, previousOffset.y), max(0, contentHeight - viewport.height)))
        if scroll.contentView.bounds.origin != restored {
            scroll.contentView.scroll(to: restored)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let caseRect = bounds.insetBy(dx: 8, dy: 9)
        let shell = rounded(caseRect, 16)
        castShadow(shell, blur: 13, depth: 5, opacity: 0.52)
        shade(shell, from: neutral(0.25), to: neutral(0.075))
        stroke(shell, neutral(0.01, 0.78))

        let chamfer = rounded(caseRect.insetBy(dx: 3, dy: 3), 13)
        shade(chamfer, from: neutral(0.185), to: neutral(0.105))
        drawBezelFinish(chamfer)
        stroke(chamfer, neutral(1, 0.12), width: 0.8)

        fill(rounded(bed.insetBy(dx: -2, dy: -2), 9), neutral(0.045))
        let gasket = rounded(bed, 7)
        shade(gasket, from: neutral(0.31), to: neutral(0.62))
        stroke(rounded(bed.insetBy(dx: 2, dy: 2), 5), neutral(1, 0.44), width: 0.7)

        drawRulers(along: bed)
        engraved("LIGHT TABLE  /  LED 5500K", x: bed.minX, y: bed.minY - lowerRailHeight / 2 - 5.5,
                 color: neutral(0.72))
    }

    private func drawBezelFinish(_ shell: NSBezierPath) {
        let bezel = NSBezierPath()
        bezel.append(shell)
        bezel.append(rounded(bed.insetBy(dx: -2, dy: -2), 9))
        bezel.windingRule = .evenOdd
        Frost.texture(bezel, seed: 137, grainDepth: 0.23, mottleDepth: 0.025)
    }

    private func drawRulers(along bed: NSRect) {
        let marks = NSBezierPath()
        let horizontal = 50
        for index in 0...horizontal {
            let x = bed.minX + bed.width * CGFloat(index) / CGFloat(horizontal)
            let major = index.isMultiple(of: 10)
            let height: CGFloat = major ? 6 : index.isMultiple(of: 5) ? 4 : 2.5
            marks.move(to: NSPoint(x: x, y: bed.maxY + 4))
            marks.line(to: NSPoint(x: x, y: bed.maxY + 4 + height))
            if major {
                engraved("\(index / 2)", x: x + 3, y: bed.maxY + 9, size: 7, color: neutral(0.68))
            }
        }
        let vertical = 20
        for index in 0...vertical {
            let y = bed.minY + bed.height * CGFloat(index) / CGFloat(vertical)
            let width: CGFloat = index.isMultiple(of: 5) ? 5.5 : 2.5
            marks.move(to: NSPoint(x: bed.minX - 4, y: y))
            marks.line(to: NSPoint(x: bed.minX - 4 - width, y: y))
        }
        stroke(marks, neutral(0.66), width: 0.65)
    }
}

private final class ArchivalSleeve: LampLitSurface {
    let frames: [FrameButton]
    private let number: Int
    private let first: Int
    private let last: Int
    private var slots: [FilmStripSlot] = []

    override var diffusesPrint: Bool { true }
    // About 60 % of the lamp passes the sleeve's pockets (0.85 x their standard-lit 0.7);
    // the sealed seams pass a little more and the punched holes all of it.
    override var lampDensity: Float { 0.85 }

    override func backlightDidChange() {
        for slot in slots { slot.setBacklight(backlight) }
    }

    init(number: Int, first: Int, last: Int, frames: [FrameButton], frameSlots: [FrameSlot]) {
        self.frames = frames
        self.number = number
        self.first = first
        self.last = last
        super.init(frame: .zero)
        for start in stride(from: 0, to: frameSlots.count, by: 4) {
            let stripFrames = Array(frameSlots[start..<min(start + 4, frameSlots.count)])
            let placeholders = (stripFrames.count..<4).map { _ in NSView() }
            let frameRow = NSStackView(views: stripFrames.map { $0 as NSView } + placeholders)
            frameRow.distribution = .fillEqually
            frameRow.alignment = .centerY
            frameRow.spacing = 14
            for frame in stripFrames { frame.heightAnchor.constraint(equalTo: frameRow.heightAnchor).isActive = true }
            let slot = FilmStripSlot(strip: FilmStrip(frameRow: frameRow),
                                     angle: start == 0 ? 0.9 : -0.8, offset: start == 0 ? -2 : 2)
            slots.append(slot)
            addSubview(slot)
        }
    }

    required init?(coder: NSCoder) { nil }

    func height(forStripHeight height: CGFloat) -> CGFloat {
        43 + CGFloat(slots.count) * height + CGFloat(max(0, slots.count - 1)) * 14
    }

    override func layout() {
        super.layout()
        guard !slots.isEmpty else { return }
        let height = (bounds.height - 43 - CGFloat(slots.count - 1) * 14) / CGFloat(slots.count)
        for (index, slot) in slots.enumerated() {
            let y = bounds.maxY - 29 - height - CGFloat(index) * (height + 14)
            slot.frame = NSRect(x: 34, y: y, width: max(0, bounds.width - 45), height: max(0, height))
        }
    }

    override func drawSurface(_ dirtyRect: NSRect, lit mode: DiffuserEmission.Mode) {
        let lit = mode != .off
        let hdr = if case .high = mode { true } else { false }
        let sheet = rounded(bounds.insetBy(dx: 2, dy: 2), 6)
        let holes = [0.22, 0.45, 0.55, 0.78].map { fraction in
            NSBezierPath(ovalIn: NSRect(x: 10, y: bounds.height * fraction - 3.5, width: 7, height: 7))
        }
        // The standard lit look is also what the HDR lamp shows, through LampTransmission;
        // the code below it is the lamp-off look and the HDR fallback.
        if lit && !hdr {
            drawFrosted(sheet: sheet, holes: holes)
            return
        }
        if lit {
            // Neutral density lets the EDR light through while keeping the plastic visible.
            let plastic = NSBezierPath()
            plastic.append(sheet)
            for hole in holes { plastic.append(hole) }
            plastic.windingRule = .evenOdd
            fill(plastic, neutral(0.35, 0.20))

            NSGraphicsContext.saveGraphicsState()
            plastic.addClip()
            fill(rounded(NSRect(x: 3.5, y: 3.5, width: 21.5, height: max(0, bounds.height - 7)), 4),
                 hdr ? neutral(0.47, 0.32) : neutral(0.32, 0.035))
            if hdr {
                let header = NSBezierPath(rect: NSRect(x: 0, y: bounds.maxY - 38, width: bounds.width, height: 38))
                shade(header, from: neutral(0.47, 0.58), to: neutral(0.47, 0))
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            castShadow(sheet, blur: 4, depth: 2, opacity: 0.27)
            shade(sheet, from: neutral(0.82), to: neutral(0.71))
        }
        if hdr {
            frostedStroke(rounded(bounds.insetBy(dx: 4, dy: 4), 4.4),
                          white: 0.47, opacity: 0.49, width: 0.75)
        } else {
            stroke(sheet, lit ? neutral(0.35, 0.92) : neutral(0.58, 0.75), width: lit ? 1.0 : 0.65)
            stroke(rounded(bounds.insetBy(dx: 3.4, dy: 3.4), 4.6),
                   neutral(1, lit ? 0.58 : 0.85), width: 0.65)
        }

        let binding = NSBezierPath()
        binding.move(to: NSPoint(x: 25, y: 5))
        binding.line(to: NSPoint(x: 25, y: bounds.maxY - 5))
        let seam = bounds.midY - 7
        for y in [bounds.maxY - 25, 12] + (slots.count > 1 ? [seam - 1, seam + 1] : []) {
            binding.move(to: NSPoint(x: 26, y: y))
            binding.line(to: NSPoint(x: bounds.maxX - 6, y: y))
        }
        if hdr {
            frostedStroke(binding, white: 0.45, opacity: 0.52, width: 0.65)
        } else {
            stroke(binding, lit ? neutral(0.39, 0.86) : neutral(0.58, 0.62), width: lit ? 0.85 : 0.65)
        }
        for hole in holes {
            if !lit { fill(hole, neutral(0.68)) }
            if hdr {
                frostedStroke(hole, white: 0.46, opacity: 0.48, width: 0.65)
            } else {
                stroke(hole, lit ? neutral(0.37, 0.91) : neutral(0.57, 0.84), width: 0.8)
            }
        }

        engraved(String(format: "ARCHIVAL SLEEVE  /  ROLL %03d", number),
                 x: 34, y: bounds.maxY - 20, color: hdr ? neutral(0.36, 0.76) : neutral(0.28))
        let range = String(format: "FRAMES %02d—%02d", first, last)
        let rangeWidth = (range as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
        ]).width
        engraved(range, x: bounds.maxX - rangeWidth - 19, y: bounds.maxY - 20, size: 8,
                 color: hdr ? neutral(0.43, 0.74) : neutral(0.37))
    }

    /// [Claude 2026-11-08] The sleeve as frosted plastic rather than an outline: a body that
    /// passes about three quarters of the lamp, with grain and broad swells; a binding margin
    /// and seams sealed through, so clearer than the pockets; holes punched to the bare lamp;
    /// a soft cut edge. The printing sits in the plastic and is softened by LampTransmission.
    private func drawFrosted(sheet: NSBezierPath, holes: [NSBezierPath]) {
        let plastic = NSBezierPath()
        plastic.append(sheet)
        for hole in holes { plastic.append(hole) }
        plastic.windingRule = .evenOdd
        fill(plastic, neutral(0.35, 0.19))
        Frost.texture(plastic, seed: number, grainDepth: 0.07, mottleDepth: 0.09)

        NSGraphicsContext.saveGraphicsState()
        plastic.addClip()
        fill(NSBezierPath(rect: NSRect(x: 0, y: 0, width: 25, height: bounds.height)), neutral(1, 0.32))
        weldedSeam(NSRect(x: 25, y: 5, width: 2.6, height: max(0, bounds.height - 10)), vertical: true)
        var seams = [bounds.maxY - 25, 12]
        if slots.count > 1 { seams.append(bounds.midY - 7) }
        for y in seams {
            weldedSeam(NSRect(x: 27.6, y: y - 1.5, width: max(0, bounds.maxX - 6 - 27.6), height: 3), vertical: false)
        }
        // Plastic stressed by the punch: a faint ring around each hole.
        for hole in holes { stroke(hole, neutral(0.32, 0.10), width: 2.4) }
        NSGraphicsContext.restoreGraphicsState()
        for hole in holes { stroke(hole, neutral(0.32, 0.42), width: 0.6) }

        // The perimeter seal just inside the edge is clear; the cut edge scatters a little.
        stroke(rounded(bounds.insetBy(dx: 3.3, dy: 3.3), 4.8), neutral(1, 0.40), width: 1.3)
        stroke(sheet, neutral(0.30, 0.42), width: 0.75)

        engraved(String(format: "ARCHIVAL SLEEVE  /  ROLL %03d", number),
                 x: 34, y: bounds.maxY - 20, color: neutral(0.28))
        let range = String(format: "FRAMES %02d—%02d", first, last)
        let rangeWidth = (range as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
        ]).width
        engraved(range, x: bounds.maxX - rangeWidth - 19, y: bounds.maxY - 20, size: 8, color: neutral(0.37))
    }
}

private final class FilmStrip: LampLitSurface {
    private let frameRow: NSStackView

    init(frameRow: NSStackView) {
        self.frameRow = frameRow
        super.init(frame: .zero)
        StudioStyle.embed(frameRow, in: self, horizontal: 8, vertical: 4)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let gap = min(16, max(12, (bounds.width * 0.02).rounded()))
        if frameRow.spacing != gap { frameRow.spacing = gap }
    }

    override func drawSurface(_ dirtyRect: NSRect, lit mode: DiffuserEmission.Mode) {
        // The backing is inset from the bounds, so the tilted layer's own edge
        // falls on transparent pixels and the visible edge keeps its gradation.
        let film = bounds.insetBy(dx: 1, dy: 1)
        let backing = rounded(film, 3)
        castShadow(backing, blur: 3.5, depth: 1.5, opacity: 0.38)
        shade(backing, from: neutral(0.18), to: neutral(0.09))
        stroke(backing, neutral(0.08), width: 0.7)
    }
}

private final class FilmStripSlot: NSView {
    private let strip: FilmStrip
    private let angle: CGFloat
    private let offset: CGFloat

    init(strip: FilmStrip, angle: CGFloat, offset: CGFloat) {
        self.strip = strip
        self.angle = angle
        self.offset = offset
        super.init(frame: .zero)
        addSubview(strip)
    }

    required init?(coder: NSCoder) { nil }

    func setBacklight(_ mode: DiffuserEmission.Mode) { strip.backlight = mode }

    override func layout() {
        super.layout()
        let verticalClearance = ceil(bounds.width * abs(sin(angle * .pi / 180)) / 2)
        var area = bounds.insetBy(dx: 5, dy: verticalClearance)
        area.origin.x += offset
        guard !area.isEmpty else { return }
        // AppKit rotates the whole strip, including its button hit regions and photo layers.
        strip.frameRotation = 0
        strip.frame = area
        strip.frameCenterRotation = angle
    }
}

struct FilmLightAdjustment: Equatable, Sendable {
    // Approved on the light table at 3 EV of display headroom.
    static let defaultValue = FilmLightAdjustment(brightness: 47, shadows: -50, gamma: -31, exposure: 221)
    static let exposureLimit = 800

    let brightness: Int
    let shadows: Int
    let gamma: Int
    let exposure: Int

    init(brightness: Int, shadows: Int, gamma: Int = 0, exposure: Int = 0) {
        self.brightness = max(0, min(100, brightness))
        self.shadows = max(-50, min(50, shadows))
        self.gamma = max(-100, min(100, gamma))
        self.exposure = max(-Self.exposureLimit, min(Self.exposureLimit, exposure))
    }

    fileprivate var gammaValue: Float { pow(2, Float(gamma) / 100) }
    fileprivate var exposureEV: Float { Float(exposure) / 100 }

    fileprivate func highlightHeadroom(available: Float) -> Float {
        pow(available, Float(brightness) / 100)
    }
}

private final class IlluminatedThumbnail: NSView {
    private let surface = CALayer()
    private let poseLayer: CALayer?
    private let originalLayer: CALayer?
    private var cache: (mode: DiffuserEmission.Mode, adjustment: FilmLightAdjustment, image: CGImage)?
    private var offFade: UUID?

    init(viewingRepair: Bool = false) {
        poseLayer = viewingRepair ? CALayer() : nil
        originalLayer = viewingRepair ? CALayer() : nil
        super.init(frame: .zero)
        if let poseLayer, let originalLayer {
            let host = CALayer()
            host.addSublayer(poseLayer)
            poseLayer.addSublayer(originalLayer)
            poseLayer.addSublayer(surface)
            surface.isHidden = true
            layer = host
        } else {
            layer = surface
            isHidden = true
        }
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var presentedImage: CGImage? {
        guard !surface.isHidden, surface.opacity > 0, surface.contents != nil else { return nil }
        return cache?.image
    }

    func clearCache() { cache = nil }

    func setOriginal(_ thumbnail: NSImage?) {
        guard let originalLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        originalLayer.contents = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.commit()
    }

    func position(_ orientation: FilmOrientation, in rect: NSRect) {
        guard let poseLayer, let originalLayer else { return }
        let size = orientation.swapsAxes ? CGSize(width: rect.height, height: rect.width) : rect.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        poseLayer.bounds = CGRect(origin: .zero, size: size)
        poseLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        poseLayer.transform = Self.transform(angle: -CGFloat(orientation.quarterTurns) * .pi / 2,
                                              x: orientation.scaleX, y: orientation.scaleY)
        originalLayer.frame = poseLayer.bounds
        surface.frame = poseLayer.bounds
        CATransaction.commit()
    }

    func animateOrientation(from previous: FilmOrientation, to orientation: FilmOrientation,
                            previousRect: NSRect, turn: Int, completion: @escaping () -> Void) {
        guard let poseLayer, poseLayer.bounds.width > 0 else { completion(); return }
        let startAngle = -CGFloat(previous.quarterTurns) * .pi / 2
        let angleChange = -CGFloat(turn) * .pi / 2
        let previousWidth = previous.swapsAxes ? previousRect.height : previousRect.width
        let startScale = previousWidth / poseLayer.bounds.width
        let duration = turn == 0 ? 0.23 : 0.26
        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.duration = duration
        transform.values = (0...16).map { step in
            let t = CGFloat(step) / 16
            let sizeScale = startScale + (1 - startScale) * t
            let flipScale = cos(.pi * t)
            let x = previous.scaleX == orientation.scaleX ? previous.scaleX : previous.scaleX * flipScale
            let y = previous.scaleY == orientation.scaleY ? previous.scaleY : previous.scaleY * flipScale
            return NSValue(caTransform3D: Self.transform(angle: startAngle + angleChange * t,
                                                        x: x * sizeScale, y: y * sizeScale))
        }
        let move = CABasicAnimation(keyPath: "position")
        move.duration = duration
        move.fromValue = NSValue(point: NSPoint(x: previousRect.midX, y: previousRect.midY))
        move.toValue = NSValue(point: poseLayer.position)
        let animation = CAAnimationGroup()
        animation.animations = [transform, move]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        poseLayer.add(animation, forKey: "film-orientation")
        CATransaction.commit()
    }

    private static func transform(angle: CGFloat, x: CGFloat, y: CGFloat) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeRotation(angle, 0, 0, 1), x, y, 1)
    }

    func copyPresentation(from source: IlluminatedThumbnail) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.contents = source.surface.contents
        surface.opacity = source.surface.opacity
        if #available(macOS 26.0, *) { surface.preferredDynamicRange = source.surface.preferredDynamicRange }
        isHidden = source.isHidden || source.surface.opacity == 0
        CATransaction.commit()
    }

    func present(_ mode: DiffuserEmission.Mode, thumbnail: NSImage?, adjustment: FilmLightAdjustment = .defaultValue) {
        if mode == .off, thumbnail != nil, !isHidden, !surface.isHidden, surface.opacity > 0, window?.isVisible == true {
            fadeToUnlit()
            return
        }
        var image: CGImage?
        if mode != .off {
            if cache?.mode == mode, cache?.adjustment == adjustment {
                image = cache?.image
            } else if let thumbnail, let illuminated = Self.image(thumbnail, mode: mode, adjustment: adjustment) {
                cache = (mode, adjustment, illuminated)
                image = illuminated
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        offFade = nil
        surface.removeAnimation(forKey: "lamp-off")
        surface.opacity = 1
        surface.contents = image
        if #available(macOS 26.0, *) {
            if image != nil, case .high = mode {
                surface.preferredDynamicRange = .high
            } else {
                surface.preferredDynamicRange = .standard
            }
        }
        if poseLayer == nil { isHidden = image == nil }
        else { surface.isHidden = image == nil }
        CATransaction.commit()
    }

    private func fadeToUnlit() {
        let id = UUID()
        offFade = id
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = surface.presentation()?.opacity ?? surface.opacity
        fade.toValue = 0
        fade.duration = DiffuserEmission.switchOffDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, offFade == id else { return }
            present(.off, thumbnail: nil)
        }
        surface.opacity = 0
        surface.add(fade, forKey: "lamp-off")
        CATransaction.commit()
    }

    private nonisolated static func representableHeadroom(_ value: Float) -> Float {
        let half = Float16(value)
        return Float(Float(half) > value ? half.nextDown : half)
    }

    static func image(_ thumbnail: NSImage, mode: DiffuserEmission.Mode, adjustment: FilmLightAdjustment) -> CGImage? {
        guard let source = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return image(source, mode: mode, adjustment: adjustment)
    }

    nonisolated static func image(_ source: CGImage, mode: DiffuserEmission.Mode, adjustment: FilmLightAdjustment,
                                  maximumDimension: Int? = nil) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        let largest = max(source.width, source.height)
        let ratio = maximumDimension.map { Double(min(largest, max(1, $0))) / Double(largest) } ?? 1
        let width = max(1, Int((Double(source.width) * ratio).rounded()))
        let height = max(1, Int((Double(source.height) * ratio).rounded()))
        var linear = [Float](repeating: 0, count: width * height * 4)
        let floatFormat = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.floatComponents)
        let didDraw = linear.withUnsafeMutableBytes { pixels in
            let format = floatFormat.union(.byteOrder32Little)
            guard let context = CGContext(data: pixels.baseAddress, width: width, height: height,
                                          bitsPerComponent: 32, bytesPerRow: width * 16,
                                          space: colorSpace, bitmapInfo: format.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        // Keep a narrow shoulder above SDR white for channels outside the display gamut.
        let available: Float
        if case .high(let peak) = mode { available = Float(peak) }
        else { available = 1 }
        let headroom = representableHeadroom(adjustment.highlightHeadroom(available: available))
        let shadowEnd: Float = 0.20
        let highlightStart: Float = 0.60
        let midrange = highlightStart - shadowEnd
        let upperRange = 1 - highlightStart
        let white = headroom - 0.02
        let whiteGain = white - 1
        let whiteSlope = 1 + 2 * whiteGain / upperRange
        let shoulder = headroom - white
        let shadowGain = 0.78 * Float(adjustment.shadows) / 50
        let gammaExponent = 1 / adjustment.gammaValue
        let exposureGain = pow(2, adjustment.exposureEV)
        let exposureShoulder = max(0, exposureGain - 1) / representableHeadroom(available)
        var pixels = [Float16](repeating: 0, count: linear.count)
        var imagePeak: Float = 1
        for offset in stride(from: 0, to: linear.count, by: 4) {
            let alpha = linear[offset + 3]
            guard alpha > 0 else { continue }
            let highest = max(0, linear[offset], linear[offset + 1], linear[offset + 2])
            let signal = highest / alpha
            // One scale keeps the three linear channels in proportion.
            let scale: Float
            if signal <= shadowEnd {
                let weight = 1 - signal / shadowEnd
                scale = 1 + shadowGain * weight * weight
            } else if signal < highlightStart {
                if adjustment.gamma == 0 {
                    scale = 1
                } else {
                    let t = (signal - shadowEnd) / midrange
                    // Fade the gamma correction into both boundaries with matching slopes.
                    let weight = 4 * t * (1 - t)
                    scale = 1 + midrange * weight * (pow(t, gammaExponent) - t) / signal
                }
            } else if signal <= 1 {
                let t = (signal - highlightStart) / upperRange
                scale = 1 + whiteGain * t * t / signal
            } else {
                // Match the slope at reference white, then approach the cap without a hard clip.
                let delta = (signal - 1) * whiteSlope
                scale = (white + shoulder * (delta / (shoulder + delta))) / signal
            }
            // Apply global gain after the local adjustments. Positive gain rolls into display white.
            let exposedScale = scale * exposureGain / (1 + exposureShoulder * signal * scale)
            pixels[offset] = Float16(linear[offset] * exposedScale)
            pixels[offset + 1] = Float16(linear[offset + 1] * exposedScale)
            pixels[offset + 2] = Float16(linear[offset + 2] * exposedScale)
            pixels[offset + 3] = Float16(alpha)
            imagePeak = max(imagePeak, Float(pixels[offset]), Float(pixels[offset + 1]), Float(pixels[offset + 2]))
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let format = floatFormat.union(.byteOrder16Little)
        if #available(macOS 26.0, *), case .high = mode {
            return CGImage(headroom: imagePeak, width: width, height: height, bitsPerComponent: 16,
                           bitsPerPixel: 64, bytesPerRow: width * 8, space: colorSpace, bitmapInfo: format,
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                       bytesPerRow: width * 8, space: colorSpace, bitmapInfo: format,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private final class FrameButton: NSButton {
    private let illuminated: IlluminatedThumbnail
    private let viewingRepair: Bool
    var orientation = FilmOrientation()
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    private var hoverLayoutSize = NSSize.zero
    let id: UUID
    private(set) var artworkURL: URL
    private(set) var thumbnail: NSImage?
    var loupeRaster: CGImage? {
        if backlight != .off, let litImage = illuminated.presentedImage { return litImage }
        return thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    private var displayName = ""
    private var number = ""
    private var status = ""
    private var selected = false
    private var unavailable = false
    private var backlight = DiffuserEmission.Mode.off
    private var filmLightAdjustment = FilmLightAdjustment.defaultValue
    private let selectable: Bool
    private let handler: () -> Void

    init(item: BatchLightTableItem, number: Int, selectable: Bool = true, viewingRepair: Bool = false,
         action: @escaping () -> Void) {
        id = item.id
        artworkURL = item.artworkURL
        self.selectable = selectable
        self.viewingRepair = viewingRepair
        illuminated = IlluminatedThumbnail(viewingRepair: viewingRepair)
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(run)
        isBordered = false
        focusRingType = .exterior
        setAccessibilityRole(selectable ? .checkBox : .image)
        wantsLayer = true
        addSubview(illuminated)
        if selectable {
            let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                          owner: self, userInfo: nil)
            addTrackingArea(tracking)
            hoverArea = tracking
        }
        update(item, number: number)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func run() { handler() }

    override var acceptsFirstResponder: Bool { selectable && super.acceptsFirstResponder }

    override func hitTest(_ point: NSPoint) -> NSView? { selectable ? super.hitTest(point) : nil }

    override func accessibilityPerformPress() -> Bool {
        guard selectable, isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func accessibilityValue() -> Any? { selectable ? (selected ? 1 : 0) : nil }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea, isEnabled { setHovered(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { setHovered(false) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if selectable, isEnabled, !visibleRect.isEmpty { addCursorRect(visibleRect, cursor: .pointingHand) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false, animated: false) }
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
        updateCardScale(animated: animated)
    }

    private func updateCardScale(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let card = cardCanvas
        let shrink = min(0.045, 10 / max(1, card.width, card.height))
        let scale = 1 - shrink * (isHovered && !reduceMotion ? 0.5 : 1)
        // The drawing and HDR view share the same logical coordinates while
        // the fixed frame stays responsible for layout and pointer hit-testing.
        let target = card.insetBy(dx: (card.width - card.width / scale) / 2,
                                  dy: (card.height - card.height / scale) / 2)
        guard bounds != target else { return }
        if animated, !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().bounds = target
            }
        } else {
            bounds = target
        }
    }

    func update(_ item: BatchLightTableItem, number: Int) {
        let position = String(format: "%02d", number)
        let picked = selectable && item.selected
        guard artworkURL != item.artworkURL || displayName != item.displayName ||
              self.number != position || status != item.status || selected != picked else { return }
        if artworkURL != item.artworkURL {
            artworkURL = item.artworkURL
            unavailable = false
            setThumbnail(nil)
        }
        displayName = item.displayName
        self.number = position
        status = item.status
        let selectionChanged = selected != picked
        selected = picked
        let filename = item.displayName
        if selectable {
            setAccessibilityLabel(L10n.surface("第 \(position) 帧，\(filename)，\(item.status)"))
            let action = selected ? L10n.surface("点击放回原位") : L10n.surface("点击移入候选区")
            toolTip = "\(action) · \(filename)"
        } else {
            setAccessibilityLabel(filename)
        }
        needsDisplay = true
        if selectionChanged, window != nil {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    func setThumbnail(_ image: NSImage?) {
        guard thumbnail !== image else { return }
        thumbnail = image
        unavailable = false
        illuminated.clearCache()
        illuminated.setOriginal(image)
        updatePhoto()
        needsDisplay = true
    }

    func copyArtwork(from source: FrameButton) {
        thumbnail = source.thumbnail
        unavailable = source.unavailable
        backlight = source.backlight
        filmLightAdjustment = source.filmLightAdjustment
        illuminated.copyPresentation(from: source.illuminated)
        needsDisplay = true
    }

    func setUnavailable() {
        guard !unavailable else { return }
        unavailable = true
        needsDisplay = true
    }

    func setBacklight(_ mode: DiffuserEmission.Mode) {
        guard backlight != mode else { return }
        backlight = mode
        if thumbnail != nil { updatePhoto() }
    }

    func setFilmLightAdjustment(_ adjustment: FilmLightAdjustment) {
        guard adjustment != filmLightAdjustment else { return }
        filmLightAdjustment = adjustment
        if backlight != .off, thumbnail != nil {
            illuminated.present(backlight, thumbnail: thumbnail, adjustment: adjustment)
        }
    }

    private func updatePhoto() {
        positionPhoto()
        illuminated.present(backlight, thumbnail: thumbnail, adjustment: filmLightAdjustment)
    }

    private func positionPhoto() {
        if viewingRepair {
            illuminated.frame = cardCanvas
            illuminated.position(orientation, in: illuminated.convert(photoRect, from: self))
        } else {
            illuminated.frame = photoRect
        }
    }

    func animateOrientation(from previous: FilmOrientation, previousRect: NSRect, in view: NSView,
                            turn: Int, completion: @escaping () -> Void) {
        illuminated.animateOrientation(from: previous, to: orientation,
                                       previousRect: illuminated.convert(previousRect, from: view),
                                       turn: turn, completion: completion)
    }

    override func layout() {
        super.layout()
        if selectable, hoverLayoutSize != frame.size {
            hoverLayoutSize = frame.size
            updateCardScale(animated: false)
        }
        positionPhoto()
    }

    private var cardCanvas: NSRect { NSRect(origin: .zero, size: frame.size) }

    func center(in view: NSView) -> NSPoint {
        convert(NSPoint(x: bounds.midX, y: bounds.midY), to: view)
    }

    func singleFrameRect(in viewport: NSSize) -> NSRect {
        let margin = NSSize(width: 8, height: 19)
        let available = NSSize(width: viewport.width * 0.80 - margin.width,
                               height: viewport.height * 0.88 - margin.height)
        guard available.width > 0, available.height > 0 else { return .zero }
        let imageSize = displaySize(thumbnail?.size ?? NSSize(width: 3, height: 2))
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale + margin.width, height: imageSize.height * scale + margin.height)
        return NSRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func displaySize(_ size: NSSize) -> NSSize {
        orientation.swapsAxes ? NSSize(width: size.height, height: size.width) : size
    }

    var photoRect: NSRect {
        let card = cardCanvas.insetBy(dx: 1, dy: 0.5)
        let available = card.insetBy(dx: 3, dy: 0)
        let maxHeight = available.height - 18
        guard let image = thumbnail, image.size.width > 0, image.size.height > 0,
              available.width > 0, maxHeight > 0 else { return .zero }
        let imageSize = displaySize(image.size)
        let scale = min(available.width / imageSize.width, maxHeight / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: card.midX - size.width / 2, y: card.minY + 1 + (maxHeight - size.height) / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = cardCanvas.insetBy(dx: 1, dy: 0.5)
        let area = photoRect
        let drawsBacking = !viewingRepair || area.isEmpty
        let shape = rounded(card, 2)
        if drawsBacking { fill(shape, neutral(0.065)) }
        if let image = thumbnail, !area.isEmpty {
            if !viewingRepair {
                image.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high])
            }
        } else {
            let placeholder = unavailable ? L10n.surface("无法预览") : L10n.surface("载入缩略图…")
            let style: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: StudioStyle.secondaryText
            ]
            let text = placeholder as NSString
            let size = text.size(withAttributes: style)
            text.draw(at: NSPoint(x: card.midX - size.width / 2, y: card.midY - size.height),
                      withAttributes: style)
        }
        let captionColor = drawsBacking ? StudioStyle.secondaryText : neutral(0.22)
        let numberStyle: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                                                          .foregroundColor: selected ? StudioStyle.amber : captionColor]
        let statusParagraph = NSMutableParagraphStyle()
        statusParagraph.alignment = .right
        statusParagraph.lineBreakMode = .byTruncatingTail
        let statusStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: captionColor,
            .paragraphStyle: statusParagraph
        ]
        let labelY = card.maxY - 13
        (number as NSString).draw(at: NSPoint(x: card.minX + 6, y: labelY), withAttributes: numberStyle)
        let numberWidth = (number as NSString).size(withAttributes: numberStyle).width
        let statusX = card.minX + numberWidth + 13
        let statusRect = NSRect(x: statusX, y: labelY, width: max(0, card.maxX - statusX - 6), height: 12)
        (status as NSString).draw(in: statusRect, withAttributes: statusStyle)
        if drawsBacking {
            let border = selected ? StudioStyle.amber : neutral(1, isHovered ? 0.48 : 0.12)
            stroke(shape, border, width: selected || isHovered ? 1.5 : 0.5)
        }
    }
}

#if PURENEG_TONE_CALIBRATION
private final class ExposureSlider: NSSlider {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard isEnabled, modifiers == .option, event.specialKey == .leftArrow || event.specialKey == .rightArrow else {
            super.keyDown(with: event)
            return
        }
        let delta = event.specialKey == .leftArrow ? -1 : 1
        integerValue = max(Int(minValue), min(Int(maxValue), integerValue + delta))
        _ = sendAction(action, to: target)
    }
}
#endif

final class BatchLightTableController: NSWindowController, NSWindowDelegate {
    var onSelect: ((UUID) -> Void)?
    var onNext: (() -> Void)?
    var onReturn: (() -> Void)?

    private let singleFrame: Bool
    private let viewingRepair: Bool
    private let board: LightTable
    #if PURENEG_TONE_CALIBRATION
    private static let filmLightPreference = "settings.lightTableCalibration"
    private let filmExposure = ExposureSlider(value: 0, minValue: -Double(FilmLightAdjustment.exposureLimit),
                                              maxValue: Double(FilmLightAdjustment.exposureLimit), target: nil, action: nil)
    private let filmBrightness = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let filmShadows = NSSlider(value: 0, minValue: -50, maxValue: 50, target: nil, action: nil)
    private let filmGamma = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let filmExposureValue = NSTextField(labelWithString: "")
    private let filmBrightnessValue = NSTextField(labelWithString: "")
    private let filmShadowsValue = NSTextField(labelWithString: "")
    private let filmGammaValue = NSTextField(labelWithString: "")
    private lazy var confirmFilmLight = NSButton(title: L10n.surface("确认"), target: self, action: #selector(saveFilmLightAdjustment))
    private var filmLightPreviewQueued = false
    #endif
    private let count = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var next = PrimaryActionButton(title: singleFrame ? L10n.text("检测并预览") : L10n.surface("下一步"),
                                                target: self, action: #selector(advance))

    init(singleFrame: Bool = false, viewingRepair: Bool = false) {
        self.singleFrame = singleFrame || viewingRepair
        self.viewingRepair = viewingRepair
        board = LightTable(singleFrame: singleFrame || viewingRepair, viewingRepair: viewingRepair)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1110, height: 718),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "PURE Neg · " + headingTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        build(window)
        window.center()
        board.onSelect = { [weak self] id in self?.onSelect?(id) }
        #if PURENEG_TONE_CALIBRATION
        board.onLampPowerChange = { [weak self] powered in self?.setFilmLightControlsEnabled(powered) }
        board.onFilmHeadroomChange = { [weak self] in
            guard let self else { return }
            setFilmLightControlsEnabled(filmShadows.isEnabled)
        }
        restoreFilmLightAdjustment()
        #endif
        update(items: [], status: "", busy: false)
    }

    required init?(coder: NSCoder) { nil }

    func cachedThumbnail(for url: URL) -> CGImage? { board.cachedThumbnail(for: url) }

    func update(items: [BatchLightTableItem], status: String, busy: Bool, canAdvance: Bool = true) {
        board.update(items, isEnabled: !busy)
        let pickedCount = items.filter(\.selected).count
        let scope: String
        if singleFrame {
            count.stringValue = ""
            scope = items.first?.displayName ?? ""
        } else {
            count.stringValue = pickedCount > 0
                ? L10n.surface("已选 \(pickedCount) / \(items.count) 帧")
                : L10n.surface("共 \(items.count) 帧")
            scope = pickedCount > 0
                ? L10n.surface("下一步处理所选 \(pickedCount) 帧。")
                : L10n.surface("下一步处理全部 \(items.count) 帧。")
        }
        statusLabel.stringValue = status.isEmpty ? scope : status
        statusLabel.toolTip = statusLabel.stringValue
        next.isEnabled = canAdvance && !busy && !items.isEmpty
    }

    func present(from source: NSWindow? = nil) {
        guard let window else { return }
        #if PURENEG_TONE_CALIBRATION
        restoreFilmLightAdjustment()
        #endif
        if let source { StudioStyle.expandWorkspaceWindow(window, from: source) }
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) { board.clearHover() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let onReturn else { return true }
        onReturn()
        return false
    }

    @objc private func advance() { onNext?() }
    @objc private func returnToSource() { onReturn?() }

    #if PURENEG_TONE_CALIBRATION
    private var filmLightDraft: FilmLightAdjustment {
        FilmLightAdjustment(brightness: filmBrightness.integerValue, shadows: filmShadows.integerValue,
                            gamma: filmGamma.integerValue, exposure: filmExposure.integerValue)
    }

    private func restoreFilmLightAdjustment() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.filmLightPreference)
        let fallback = FilmLightAdjustment.defaultValue
        let adjustment = saved.map {
            FilmLightAdjustment(brightness: $0["brightness"] as? Int ?? fallback.brightness,
                                shadows: $0["shadows"] as? Int ?? fallback.shadows,
                                gamma: $0["gamma"] as? Int ?? 0,
                                exposure: $0["exposure"] as? Int ?? 0)
        } ?? fallback
        filmExposure.integerValue = adjustment.exposure
        filmBrightness.integerValue = adjustment.brightness
        filmShadows.integerValue = adjustment.shadows
        filmGamma.integerValue = adjustment.gamma
        showFilmLightValues()
        confirmFilmLight.title = L10n.surface("确认")
        board.setFilmLightAdjustment(adjustment)
    }

    private func setFilmLightControlsEnabled(_ enabled: Bool) {
        filmExposure.isEnabled = enabled
        filmBrightness.isEnabled = enabled && board.filmHeadroom > 1
        filmShadows.isEnabled = enabled
        filmGamma.isEnabled = enabled
        confirmFilmLight.isEnabled = enabled
        showFilmLightValues()
    }

    private func showFilmLightValues() {
        let adjustment = filmLightDraft
        let available = board.filmHeadroom
        let selected = adjustment.highlightHeadroom(available: available)
        filmExposureValue.stringValue = String(format: "%+.2f EV", adjustment.exposureEV)
        filmBrightnessValue.stringValue = filmShadows.isEnabled
            ? String(format: "%+.2f / %+.2f EV", log2(selected), log2(available)) : "—"
        let shadows = filmShadows.integerValue
        filmShadowsValue.stringValue = shadows > 0 ? "+\(shadows)" : String(shadows)
        filmGammaValue.stringValue = String(format: "%.2f", adjustment.gammaValue)
    }

    @objc private func changeFilmLightAdjustment() {
        showFilmLightValues()
        confirmFilmLight.title = L10n.surface("确认")
        guard !filmLightPreviewQueued else { return }
        filmLightPreviewQueued = true
        // Coalesce dense trackpad events while keeping the latest adjustment visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            filmLightPreviewQueued = false
            board.setFilmLightAdjustment(filmLightDraft)
        }
    }

    @objc private func saveFilmLightAdjustment() {
        let adjustment = filmLightDraft
        board.setFilmLightAdjustment(adjustment)
        var record: [String: Any] = ["brightness": adjustment.brightness, "shadows": adjustment.shadows,
                                     "gamma": adjustment.gamma, "gammaValue": Double(adjustment.gammaValue),
                                     "exposure": adjustment.exposure, "exposureEV": Double(adjustment.exposure) / 100,
                                     "selectedHeadroom": Double(adjustment.highlightHeadroom(available: board.filmHeadroom)),
                                     "availableHeadroom": Double(board.filmHeadroom),
                                     "confirmedAt": Date()]
        if let screen = window?.screen {
            record["display"] = screen.localizedName
            record["currentHeadroom"] = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            record["potentialHeadroom"] = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        }
        UserDefaults.standard.set(record, forKey: Self.filmLightPreference)
        confirmFilmLight.title = L10n.surface("已记录")
    }

    private func filmLightControl(_ slider: NSSlider, value: NSTextField, title: String, hint: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.textColor = StudioStyle.secondaryText
        label.font = .systemFont(ofSize: 12, weight: .medium)
        slider.target = self
        slider.action = #selector(changeFilmLightAdjustment)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.toolTip = hint
        slider.setAccessibilityLabel(title)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.textColor = StudioStyle.amber
        value.alignment = .right
        value.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = horizontal([label, value])
        row.spacing = 6
        let group = NSStackView(views: [row, slider])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 3
        row.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        slider.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }
    #endif

    @objc private func changeOrientation(_ button: NSButton) {
        if let action = FilmOrientationAction(rawValue: button.tag) { board.changeRepairOrientation(action) }
    }

    private func orientationControl(_ action: FilmOrientationAction, symbol: String, label: String) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(changeOrientation(_:)))
        button.tag = action.rawValue
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return StudioStyle.actionControl(button, horizontal: 10)
    }

    private var headingTitle: String {
        if viewingRepair { return L10n.surface("修复后观片") }
        return singleFrame ? L10n.surface("单张观片") : L10n.surface("全卷处理")
    }

    private func build(_ window: NSWindow) {
        let root = NSView()
        window.contentView = root
        StudioStyle.installBackdrop(in: window, root: root)

        let name = NSTextField(labelWithString: headingTitle)
        name.textColor = StudioStyle.secondaryText
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let back = NSButton(title: viewingRepair ? L10n.surface("返回审核") : L10n.surface("返回来源"),
                            target: self, action: #selector(returnToSource))
        back.keyEquivalent = "\u{1b}"
        var toolbarViews = [StudioStyle.backControl(back),
                            StudioStyle.wordmark(width: 114, maxHeight: 29, fallbackSize: 19),
                            name, NSView()]
        if viewingRepair {
            let orientationTools = horizontal([
                orientationControl(.rotateLeft, symbol: "rotate.left", label: L10n.surface("向左旋转 90°")),
                orientationControl(.rotateRight, symbol: "rotate.right", label: L10n.surface("向右旋转 90°")),
                orientationControl(.flipHorizontal, symbol: "arrow.left.and.right", label: L10n.surface("水平翻转")),
                orientationControl(.flipVertical, symbol: "arrow.up.and.down", label: L10n.surface("垂直翻转"))
            ])
            orientationTools.spacing = 5
            toolbarViews.append(orientationTools)
        }
        toolbarViews.append(SupportWindows.supportControl())
        let toolbar = bar(toolbarViews, height: 45)
        let instructions: String
        if viewingRepair {
            instructions = L10n.surface("用右下角电源点亮观片器，拖动放大镜检查胶片细节。")
        } else if singleFrame {
            instructions = L10n.surface("按右下角电源按钮点亮观片器。")
        } else {
            instructions = L10n.surface("点击底片移入候选区。未单独选片时，默认处理全部。")
        }
        let detail = NSTextField(labelWithString: instructions)
        detail.textColor = StudioStyle.secondaryText
        detail.font = .systemFont(ofSize: 13)
        count.textColor = StudioStyle.amber
        count.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        let heading = horizontal([detail, NSView(), count])
        heading.heightAnchor.constraint(equalToConstant: 22).isActive = true

        statusLabel.textColor = StudioStyle.secondaryText
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var footerViews = [statusLabel as NSView, NSView()]
        #if PURENEG_TONE_CALIBRATION
        let exposureControl = filmLightControl(filmExposure, value: filmExposureValue, title: L10n.surface("曝光"),
                                               hint: L10n.surface("整体提亮或压暗照片。范围 −8 至 +8 EV，按住 Option 再按方向键可微调 0.01 EV。"))
        let brightnessControl = filmLightControl(filmBrightness, value: filmBrightnessValue,
                                                 title: L10n.surface("亮部"),
                                                 hint: L10n.surface("从 0 EV 调到屏幕当前可用的 HDR 上限。数字为当前值和上限。"))
        let shadowsControl = filmLightControl(filmShadows, value: filmShadowsValue,
                                              title: L10n.surface("暗部"), hint: L10n.surface("向左加深暗部，向右提亮暗部。"))
        let gammaControl = filmLightControl(filmGamma, value: filmGammaValue,
                                            title: L10n.surface("伽马"), hint: L10n.surface("向左压暗中间调，向右提亮中间调。1.00 为原始中间调。"))
        confirmFilmLight.toolTip = L10n.surface("记录曝光、亮部、暗部、伽马和屏幕 HDR 余量。")
        confirmFilmLight.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        footerViews.append(StudioStyle.actionControl(confirmFilmLight, horizontal: 8))
        #endif
        if !viewingRepair { footerViews.append(StudioStyle.actionControl(next)) }
        #if PURENEG_TONE_CALIBRATION
        setFilmLightControlsEnabled(false)
        let toneControls = horizontal([exposureControl, brightnessControl, shadowsControl, gammaControl])
        toneControls.distribution = .fillEqually
        toneControls.spacing = 18
        let footerActions = horizontal(footerViews)
        let footerContent = NSStackView(views: [toneControls, footerActions])
        footerContent.orientation = .vertical
        footerContent.alignment = .leading
        footerContent.spacing = 6
        toneControls.widthAnchor.constraint(equalTo: footerContent.widthAnchor).isActive = true
        footerActions.widthAnchor.constraint(equalTo: footerContent.widthAnchor).isActive = true
        let footer = bar(footerContent, height: 87)
        #else
        let footer = bar(footerViews, height: 51)
        #endif
        let layout = NSStackView(views: [toolbar, heading, board, footer])
        layout.orientation = .vertical
        layout.distribution = .fill
        layout.alignment = .notAnAttribute
        layout.spacing = 13
        layout.setCustomSpacing(16, after: toolbar)
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -19)
        ] + layout.arrangedSubviews.flatMap {
            [$0.leadingAnchor.constraint(equalTo: layout.leadingAnchor),
             $0.trailingAnchor.constraint(equalTo: layout.trailingAnchor)]
        })
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func bar(_ views: [NSView], height: CGFloat) -> NSView {
        bar(horizontal(views), height: height)
    }

    private func bar(_ content: NSView, height: CGFloat) -> NSView {
        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .followsWindowActiveState
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        StudioStyle.embed(content, in: panel, horizontal: 14, vertical: 6)
        panel.heightAnchor.constraint(equalToConstant: height).isActive = true
        return panel
    }
}


/// [Claude 2026-11-08] The light table's power switch sound: a short two-part mechanical
/// click (the rocker and its catch), made in code so the app needs no sound file.
@MainActor private enum SwitchClick {
    private static let sound: NSSound? = {
        let rate = 44_100, length = Int(0.09 * Double(rate))
        var samples = [Int16](repeating: 0, count: length)
        var seed: UInt32 = 12345
        func noise() -> Double { seed = seed &* 1_664_525 &+ 1_013_904_223; return Double(seed) / Double(UInt32.max) * 2 - 1 }
        // Two transients 28 ms apart: a sharp snap, then a softer, lower catch.
        for (start, gain, decay, tone) in [(0.0, 0.85, 0.0016, 3_400.0), (0.028, 0.45, 0.0025, 1_900.0)] {
            let s0 = Int(start * Double(rate))
            for i in 0..<Int(0.02 * Double(rate)) where s0 + i < length {
                let t = Double(i) / Double(rate)
                let v = gain * exp(-t / decay) * (0.55 * noise() + 0.45 * sin(2 * .pi * tone * t))
                samples[s0 + i] = Int16(clamping: Int(Double(samples[s0 + i]) + v * 26_000))
            }
        }
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + length * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(length * 2))
        for v in samples { put(v) }
        let sound = NSSound(data: data)
        sound?.volume = 0.6
        return sound
    }()

    static func play() {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }
}
