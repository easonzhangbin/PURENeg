import AppKit
import ImageIO
import QuartzCore

struct BatchLightTableItem {
    let id: UUID
    let url: URL
    let status: String
    let selected: Bool
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
    enum Mode: Equatable { case off, standard, high(CGFloat) }

    private static let offImage = standardImage(lit: false)
    private static let litImage = standardImage(lit: true)
    private let emitter = CALayer()
    private let aperture = CAShapeLayer()
    private var renderedMode: Mode?
    private var headroomTimer: Timer?
    var modeChanged: ((Mode) -> Void)?
    var isEnabled = false {
        didSet {
            if oldValue != isEnabled { switchFeedback(on: isEnabled) }
            updateForDisplay()
        }
    }
    /// [Claude 2026-11-08] A dark veil over the lamp, animated when it is switched: a
    /// fluorescent tube's starter flickers a few times before it holds, and switching off
    /// lets the light die away quickly. Clear when the lamp is steady.
    private let veil = CALayer()

    init() {
        super.init(frame: .zero)
        aperture.fillColor = NSColor.white.cgColor
        veil.backgroundColor = NSColor.black.cgColor
        veil.opacity = 0
        emitter.addSublayer(veil)
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
        veil.frame = bounds
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

    func headroomMayHaveChanged() { updateForDisplay() }

    private func switchFeedback(on: Bool) {
        SwitchClick.play()
        veil.removeAllAnimations()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if on && !reduceMotion {
            // Starter flicker: dark, two short flashes, a weak glow that wavers, then full.
            animation.values = [0.9, 0.9, 0.35, 0.9, 0.9, 0.15, 0.85, 0.85, 0.4, 0.5, 0.25, 0.32, 0.0]
            animation.keyTimes = [0, 0.10, 0.14, 0.20, 0.33, 0.38, 0.44, 0.52, 0.58, 0.66, 0.74, 0.82, 1]
            animation.duration = 1.0
        } else if on {
            animation.values = [0.9, 0.0]
            animation.duration = 0.35
        } else {
            // Off: the light dies away over a moment instead of cutting out.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = reduceMotion ? 0.1 : 0.35
            emitter.add(fade, forKey: "switch")
            return
        }
        animation.isRemovedOnCompletion = true
        veil.opacity = 0
        veil.add(animation, forKey: "switch")
    }

    private func updateForDisplay() {
        var mode: Mode = isEnabled ? .standard : .off
        if #available(macOS 26.0, *), isEnabled, let screen = window?.screen,
           let peak = Self.peak(potential: screen.maximumPotentialExtendedDynamicRangeColorComponentValue) {
            mode = .high(peak)
        }
        guard mode != renderedMode else { return }
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
        CATransaction.commit()
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

private final class LightTable: NSView {
    private let lowerRailHeight: CGFloat = 50
    private let emission = DiffuserEmission()
    private let power = DiffuserSwitch(enabled: false)
    private let scroll = NSScrollView()
    private let document = LightTableDocument()
    private let tray = CandidateTray()
    private let flightOverlay = FilmFlightOverlay()
    private let empty = NSTextField(labelWithString: L10n.surface("尚未载入照片"))
    private var pages: [ArchivalSleeve] = []
    private var orderedIDs: [UUID] = []
    private var cells: [UUID: FrameButton] = [:]
    private var archiveSlots: [UUID: FrameSlot] = [:]
    private var flights: [UUID: FrameButton] = [:]
    private var visibleCells: [FrameButton] = []
    private var backlight = DiffuserEmission.Mode.off
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
    var onSelect: ((UUID) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(emission)
        addSubview(scroll)
        addSubview(flightOverlay)
        addSubview(power)
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
        power.changed = { [weak emission] enabled in emission?.isEnabled = enabled }
    }

    required init?(coder: NSCoder) { nil }

    func clearHover() {
        for cell in visibleCells { cell.setHovered(false, animated: false) }
    }

    func update(_ items: [BatchLightTableItem], isEnabled: Bool) {
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
        let viewport = scroll.contentView.bounds
        let preload = viewport.insetBy(dx: 0, dy: -min(110, viewport.height * 0.25))
        let visiblePages = pages.filter { $0.frame.intersects(preload) }
        let sleeveCells = visiblePages.flatMap(\.frames).filter { tray.slot(for: $0.id) == nil }
        let candidateCells = tray.visibleIDs(in: preload).compactMap { cells[$0] }
        let newCells = sleeveCells + candidateCells
        let ids = Set(newCells.map(\.id))
        for cell in visibleCells where !ids.contains(cell.id) { cell.setThumbnail(nil) }
        visibleCells = newCells
        for cell in visibleCells where cell.thumbnail == nil {
            let url = cell.url
            if let image = thumbnails.object(forKey: url as NSURL) {
                cell.setThumbnail(image)
            } else if unreadable.contains(url) {
                cell.setUnavailable()
            } else if pending.count < 2, pending.insert(url).inserted {
                thumbnailQueue.addOperation { [weak self] in
                    let thumbnail = autoreleasepool { Self.thumbnail(at: url) }
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

    private static func thumbnail(at url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
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
        }
        let aperture = bed.insetBy(dx: 2, dy: 2)
        emission.setApertureFrame(aperture)
        flightOverlay.frame = aperture
        scroll.frame = aperture
        var previousOffset = scroll.contentView.bounds.origin
        let viewport = scroll.contentSize
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
        empty.frame = NSRect(x: 0, y: (viewport.height - 20) / 2, width: viewport.width, height: 20)
        let restored = NSPoint(x: 0, y: min(max(0, previousOffset.y), max(0, contentHeight - viewport.height)))
        if scroll.contentView.bounds.origin != restored {
            scroll.contentView.scroll(to: restored)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let switchSize = NSSize(width: 78, height: 35)
        power.frame = NSRect(x: bed.maxX - switchSize.width,
                             y: bed.minY - (lowerRailHeight + switchSize.height) / 2,
                             width: switchSize.width, height: switchSize.height)
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
        stroke(chamfer, neutral(1, 0.17), width: 0.8)

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
        NSGraphicsContext.saveGraphicsState()
        bezel.addClip()
        NSGradient(colors: [neutral(1, 0.09), neutral(1, 0.018), neutral(0, 0.15)])?
            .draw(in: bezel.bounds, angle: 145)
        let grain = NSBezierPath()
        let box = bezel.bounds
        for index in 1..<Int(box.height) {
            let y = box.minY + CGFloat(index) + (index.isMultiple(of: 2) ? 0.25 : 0)
            let offset = CGFloat((index * 17) % 101)
            for start in stride(from: box.minX + offset - 100, to: box.maxX, by: 147) {
                grain.move(to: NSPoint(x: start, y: y))
                grain.line(to: NSPoint(x: start + CGFloat(22 + (index * 31) % 80), y: y))
            }
        }
        stroke(grain, neutral(1, 0.055), width: 0.34)
        NSGraphicsContext.restoreGraphicsState()
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
        for frame in frames { frame.setBacklight(backlight) }
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

private final class IlluminatedThumbnail: NSView {
    private let surface = CALayer()
    private var cache: (mode: DiffuserEmission.Mode, image: CGImage)?

    init() {
        super.init(frame: .zero)
        layer = surface
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func clearCache() { cache = nil }

    func copyPresentation(from source: IlluminatedThumbnail) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.contents = source.surface.contents
        if #available(macOS 26.0, *) { surface.preferredDynamicRange = source.surface.preferredDynamicRange }
        isHidden = source.isHidden
        CATransaction.commit()
    }

    func present(_ mode: DiffuserEmission.Mode, thumbnail: NSImage?) {
        var image: CGImage?
        if mode != .off {
            if cache?.mode != mode, let thumbnail, let illuminated = Self.image(thumbnail, mode: mode) {
                cache = (mode, illuminated)
            }
            if cache?.mode == mode { image = cache?.image }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.contents = image
        if #available(macOS 26.0, *) {
            if image != nil, case .high = mode {
                surface.preferredDynamicRange = .high
            } else {
                surface.preferredDynamicRange = .standard
            }
        }
        isHidden = image == nil
        CATransaction.commit()
    }

    /// Share of the lamp passed by clear film base (tune here if frames look too bright).
    static let filmBaseTransmission: Float = 0.8

    static func image(_ thumbnail: NSImage, mode: DiffuserEmission.Mode) -> CGImage? {
        guard let source = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let width = source.width
        let height = source.height
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

        let headroom: Float
        let gain: Float
        let ceiling: Float
        if case .high(let peak) = mode {
            // [Claude 2026-11-07] A frame on a light box is the lamp seen through the film:
            // clear base passes about 80 % of it, so the highlights sit just under the
            // diffuser instead of at a fixed SDR multiple far below it.
            headroom = Float(peak)
            gain = Self.filmBaseTransmission * headroom
            ceiling = gain
        } else {
            headroom = 1
            gain = 1.44
            ceiling = 0.98
        }
        let shoulder = max(0, gain / ceiling - 1)
        var pixels = [Float16](repeating: 0, count: linear.count)
        var imagePeak: Float = 1
        for offset in stride(from: 0, to: linear.count, by: 4) {
            let alpha = linear[offset + 3]
            let highest = max(0, linear[offset], linear[offset + 1], linear[offset + 2])
            // All three linear channels share a scale to preserve the film's colors.
            let scale = alpha > 0 ? gain / (1 + shoulder * highest / alpha) : 0
            pixels[offset] = Float16(linear[offset] * scale)
            pixels[offset + 1] = Float16(linear[offset + 1] * scale)
            pixels[offset + 2] = Float16(linear[offset + 2] * scale)
            pixels[offset + 3] = Float16(alpha)
            imagePeak = max(imagePeak, Float(pixels[offset]), Float(pixels[offset + 1]), Float(pixels[offset + 2]))
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let format = floatFormat.union(.byteOrder16Little)
        if #available(macOS 26.0, *), case .high = mode {
            // Tag the frame with the lamp's headroom so both are tone mapped alike.
            return CGImage(headroom: max(imagePeak, headroom), width: width, height: height, bitsPerComponent: 16,
                           bitsPerPixel: 64, bytesPerRow: width * 8, space: colorSpace, bitmapInfo: format,
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                       bytesPerRow: width * 8, space: colorSpace, bitmapInfo: format,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private final class FrameButton: NSButton {
    private let illuminated = IlluminatedThumbnail()
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    private var hoverLayoutSize = NSSize.zero
    let id: UUID
    private(set) var url: URL
    private(set) var thumbnail: NSImage?
    private var number = ""
    private var status = ""
    private var selected = false
    private var unavailable = false
    private var backlight = DiffuserEmission.Mode.off
    private let handler: () -> Void

    init(item: BatchLightTableItem, number: Int, action: @escaping () -> Void) {
        id = item.id
        url = item.url
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(run)
        isBordered = false
        focusRingType = .exterior
        setAccessibilityRole(.checkBox)
        wantsLayer = true
        addSubview(illuminated)
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverArea = tracking
        update(item, number: number)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func run() { handler() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func accessibilityValue() -> Any? { selected ? 1 : 0 }

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
        if isEnabled, !visibleRect.isEmpty { addCursorRect(visibleRect, cursor: .pointingHand) }
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
        guard url != item.url || self.number != position || status != item.status || selected != item.selected else { return }
        if url != item.url {
            url = item.url
            unavailable = false
            setThumbnail(nil)
        }
        self.number = position
        status = item.status
        let selectionChanged = selected != item.selected
        selected = item.selected
        let filename = item.url.lastPathComponent
        setAccessibilityLabel(L10n.surface("第 \(position) 帧，\(filename)，\(item.status)"))
        let action = selected ? L10n.surface("点击放回原位") : L10n.surface("点击移入候选区")
        toolTip = "\(action) · \(filename)"
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
        updatePhoto()
        needsDisplay = true
    }

    func copyArtwork(from source: FrameButton) {
        thumbnail = source.thumbnail
        unavailable = source.unavailable
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

    private func updatePhoto() {
        illuminated.frame = photoRect
        illuminated.present(backlight, thumbnail: thumbnail)
    }

    override func layout() {
        super.layout()
        if hoverLayoutSize != frame.size {
            hoverLayoutSize = frame.size
            updateCardScale(animated: false)
        }
        illuminated.frame = photoRect
    }

    private var cardCanvas: NSRect { NSRect(origin: .zero, size: frame.size) }

    func center(in view: NSView) -> NSPoint {
        convert(NSPoint(x: bounds.midX, y: bounds.midY), to: view)
    }

    private var photoRect: NSRect {
        let card = cardCanvas.insetBy(dx: 1, dy: 0.5)
        let available = card.insetBy(dx: 3, dy: 0)
        let maxHeight = available.height - 18
        guard let image = thumbnail, image.size.width > 0, image.size.height > 0,
              available.width > 0, maxHeight > 0 else { return .zero }
        let scale = min(available.width / image.size.width, maxHeight / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: card.midX - size.width / 2, y: card.minY + 1 + (maxHeight - size.height) / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = cardCanvas.insetBy(dx: 1, dy: 0.5)
        let shape = rounded(card, 2)
        fill(shape, neutral(0.065))
        let area = photoRect
        if let image = thumbnail, !area.isEmpty {
            image.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high])
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
        let numberStyle: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                                                          .foregroundColor: selected ? StudioStyle.amber : StudioStyle.secondaryText]
        let statusParagraph = NSMutableParagraphStyle()
        statusParagraph.alignment = .right
        statusParagraph.lineBreakMode = .byTruncatingTail
        let statusStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: StudioStyle.secondaryText,
            .paragraphStyle: statusParagraph
        ]
        let labelY = card.maxY - 13
        (number as NSString).draw(at: NSPoint(x: card.minX + 6, y: labelY), withAttributes: numberStyle)
        let numberWidth = (number as NSString).size(withAttributes: numberStyle).width
        let statusX = card.minX + numberWidth + 13
        let statusRect = NSRect(x: statusX, y: labelY, width: max(0, card.maxX - statusX - 6), height: 12)
        (status as NSString).draw(in: statusRect, withAttributes: statusStyle)
        let border = selected ? StudioStyle.amber : neutral(1, isHovered ? 0.48 : 0.12)
        stroke(shape, border, width: selected || isHovered ? 1.5 : 0.5)
    }
}

final class BatchLightTableController: NSWindowController, NSWindowDelegate {
    var onSelect: ((UUID) -> Void)?
    var onNext: (() -> Void)?
    var onReturn: (() -> Void)?

    private let board = LightTable()
    private let count = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var next = PrimaryActionButton(title: L10n.surface("下一步"), target: self, action: #selector(advance))

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1110, height: 718),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "PURE Neg · " + L10n.surface("全卷处理")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        build(window)
        window.center()
        board.onSelect = { [weak self] id in self?.onSelect?(id) }
        update(items: [], status: "", busy: false)
    }

    required init?(coder: NSCoder) { nil }

    func cachedThumbnail(for url: URL) -> CGImage? { board.cachedThumbnail(for: url) }

    func update(items: [BatchLightTableItem], status: String, busy: Bool) {
        board.update(items, isEnabled: !busy)
        let pickedCount = items.filter(\.selected).count
        count.stringValue = pickedCount > 0
            ? L10n.surface("已选 \(pickedCount) / \(items.count) 帧")
            : L10n.surface("共 \(items.count) 帧")
        let scope = pickedCount > 0
            ? L10n.surface("下一步处理所选 \(pickedCount) 帧。")
            : L10n.surface("下一步处理全部 \(items.count) 帧。")
        statusLabel.stringValue = status.isEmpty ? scope : status
        statusLabel.toolTip = statusLabel.stringValue
        next.isEnabled = !busy && !items.isEmpty
    }

    func present(from source: NSWindow? = nil) {
        guard let window else { return }
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

    private func build(_ window: NSWindow) {
        let root = NSView()
        window.contentView = root
        StudioStyle.installBackdrop(in: window, root: root)

        let name = NSTextField(labelWithString: L10n.surface("全卷处理"))
        name.textColor = StudioStyle.secondaryText
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let back = NSButton(title: L10n.surface("返回来源"), target: self, action: #selector(returnToSource))
        let toolbar = bar([StudioStyle.wordmark(width: 114, maxHeight: 29, fallbackSize: 19),
                           name, NSView(), StudioStyle.actionControl(back), SupportWindows.supportControl()], height: 45)
        let detail = NSTextField(labelWithString: L10n.surface("点击底片移入候选区。未单独选片时，默认处理全部。"))
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
        let footer = bar([statusLabel, NSView(), StudioStyle.actionControl(next)], height: 51)
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
        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .followsWindowActiveState
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        StudioStyle.embed(horizontal(views), in: panel, horizontal: 14, vertical: 6)
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
