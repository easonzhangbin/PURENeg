import AppKit
import CoreImage
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

final class ReviewLoadingView: NSView {
    private static let thumbnailLimit = 512
    private static let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PURENeg.loadingBackdrop"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private static let blurContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    private let artwork = NSView()
    private let backdrop = CALayer()
    private let scrim = CAGradientLayer()
    private let dust = CALayer()
    private let cloud = CAEmitterLayer()
    private let atmosphere = CAEmitterLayer()
    private var sourceURL: URL?
    private var sourceThumbnail: CGImage?
    private var imageOperation: BlockOperation?
    private var visibilityGeneration = 0
    private var isLoading = false
    private var isRevealing = false
    private var allowsAnimation = true
    private var particlesRunning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        isHidden = true

        artwork.wantsLayer = true
        artwork.autoresizingMask = [.width, .height]
        addSubview(artwork)
        artwork.layer?.backgroundColor = NSColor(srgbRed: 0.079, green: 0.083, blue: 0.090, alpha: 1).cgColor
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.opacity = 0.87
        artwork.layer?.addSublayer(backdrop)
        scrim.type = .radial
        scrim.startPoint = CGPoint(x: 0.5, y: 0.5)
        scrim.endPoint = CGPoint(x: 1, y: 1)
        scrim.colors = [NSColor.black.withAlphaComponent(0.34).cgColor, NSColor.black.withAlphaComponent(0.70).cgColor]
        artwork.layer?.addSublayer(scrim)
        cloud.emitterShape = .circle
        cloud.emitterMode = .surface
        atmosphere.emitterShape = .rectangle
        atmosphere.emitterMode = .surface
        dust.isHidden = true
        dust.addSublayer(cloud)
        dust.addSublayer(atmosphere)
        artwork.layer?.addSublayer(dust)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(animationEnvironmentChanged(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(animationEnvironmentChanged(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(animationEnvironmentChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(animationEnvironmentChanged(_:)),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        imageOperation?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        artwork.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = artwork.bounds
        scrim.frame = artwork.bounds
        let dustSizeChanged = dust.bounds.size != artwork.bounds.size
        dust.frame = artwork.bounds
        cloud.frame = dust.bounds
        atmosphere.frame = dust.bounds
        atmosphere.emitterPosition = CGPoint(x: dust.bounds.midX, y: dust.bounds.midY)
        atmosphere.emitterSize = dust.bounds.size
        if dustSizeChanged && particlesRunning { animateDustCloud() }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateParticles()
    }

    func setSource(_ url: URL?, thumbnail: CGImage? = nil) {
        if url == sourceURL {
            guard let thumbnail else { return }
            if let cached = sourceThumbnail, max(cached.width, cached.height) >= max(thumbnail.width, thumbnail.height) {
                return
            }
            sourceThumbnail = thumbnail
            if isLoading, backdrop.contents == nil { requestBackdrop() }
            return
        }
        sourceURL = url
        sourceThumbnail = thumbnail
        setBackdrop(nil)
        if isLoading { requestBackdrop() }
    }

    func setLoading(_ loading: Bool, animated: Bool = true) {
        guard loading != isLoading || (!loading && !animated && isRevealing) else { return }
        isLoading = loading
        visibilityGeneration += 1
        isRevealing = false
        layer?.removeAnimation(forKey: "reviewReveal")
        dust.removeAnimation(forKey: "dustSweep")
        if loading {
            setOpacity(1)
            isHidden = false
            requestBackdrop()
        } else {
            imageOperation?.cancel()
            imageOperation = nil
            if animated, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer {
                isRevealing = true
                let generation = visibilityGeneration
                let reveal = CABasicAnimation(keyPath: "opacity")
                reveal.fromValue = 1
                reveal.toValue = 0
                reveal.duration = 0.24
                reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
                setOpacity(0)
                layer.add(reveal, forKey: "reviewReveal")
                if particlesRunning {
                    let sweep = CABasicAnimation(keyPath: "transform")
                    sweep.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
                    sweep.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(48, 14, 0))
                    sweep.duration = reveal.duration
                    sweep.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    dust.add(sweep, forKey: "dustSweep")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + reveal.duration) { [weak self] in
                    guard let self, visibilityGeneration == generation else { return }
                    finishReveal()
                }
            } else {
                finishReveal()
            }
        }
        updateParticles()
    }

    func setAnimating(_ active: Bool) {
        guard allowsAnimation != active else { return }
        allowsAnimation = active
        updateParticles()
    }

    private func finishReveal() {
        isRevealing = false
        isHidden = true
        setBackdrop(nil)
        setOpacity(1)
        updateParticles()
    }

    private func setOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = opacity
        CATransaction.commit()
    }

    private func setBackdrop(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.contents = image
        CATransaction.commit()
    }

    private func requestBackdrop() {
        imageOperation?.cancel()
        imageOperation = nil
        let url = sourceURL
        let thumbnail = sourceThumbnail
        guard url != nil || thumbnail != nil else { return }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let image = autoreleasepool { Self.blurredBackdrop(url, thumbnail: thumbnail) }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, let operation, imageOperation === operation, isLoading else { return }
                imageOperation = nil
                setBackdrop(image)
            }
        }
        imageOperation = operation
        Self.imageQueue.addOperation(operation)
    }

    private static func blurredBackdrop(_ url: URL?, thumbnail: CGImage?) -> CGImage? {
        guard let thumbnail = thumbnail ?? url.flatMap(readThumbnail) else { return nil }
        let image = CIImage(cgImage: thumbnail)
        let radius = max(4, min(image.extent.width, image.extent.height) * 0.035)
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return blurContext.createCGImage(blurred, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    private static func readThumbnail(_ url: URL) -> CGImage? {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailLimit,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if CGImageSourceGetType(source) as String? == UTType.tiff.identifier {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            // Large TIFFs can require a full decode to create a thumbnail.
            // In that case use an embedded thumbnail, or the one from the light table.
            if width > 0, height > 0, width <= 24_000_000 / height {
                options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            }
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @objc private func animationEnvironmentChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateParticles() }
    }

    private func updateParticles() {
        let active = (isLoading || isRevealing) && allowsAnimation && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true && NSApp?.isActive == true
            && !isHiddenOrHasHiddenAncestor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard active != particlesRunning else { return }
        particlesRunning = active
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dust.isHidden = !active
        let time = dust.convertTime(CACurrentMediaTime(), from: nil)
        cloud.beginTime = time
        atmosphere.beginTime = time
        cloud.emitterCells = active ? [Self.cloudCell()] : nil
        atmosphere.emitterCells = active ? Self.atmosphereCells() : nil
        if active { animateDustCloud() }
        else { cloud.removeAnimation(forKey: "dustCloud") }
        CATransaction.commit()
    }

    private func animateDustCloud() {
        let size = dust.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let diameter = min(size.width, size.height) * 0.22
        cloud.emitterSize = CGSize(width: diameter, height: diameter)
        let points: [(CGFloat, CGFloat)] = [
            (0.07, 0.24), (0.19, 0.29), (0.32, 0.42), (0.49, 0.34),
            (0.67, 0.45), (0.86, 0.53), (1.08, 0.49)
        ]
        let positions = points.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) }
        let duration: CFTimeInterval = 9.6
        let keyTimes: [NSNumber] = [0, 0.12, 0.28, 0.45, 0.64, 0.82, 1]
        cloud.emitterPosition = positions[0]

        let drift = CAKeyframeAnimation(keyPath: "emitterPosition")
        drift.values = positions.map { NSValue(point: $0) }
        drift.keyTimes = keyTimes
        drift.calculationMode = .cubic
        drift.duration = duration
        // The tail thins before the source returns to the start of its path.
        let density = CAKeyframeAnimation(keyPath: "birthRate")
        density.values = [0.36, 0.92, 0.68, 0.98, 0.62, 0.28, 0]
        density.keyTimes = keyTimes
        density.duration = duration

        let wave = CAAnimationGroup()
        wave.animations = [drift, density]
        wave.duration = duration
        wave.repeatCount = .infinity
        cloud.add(wave, forKey: "dustCloud")
    }

    private static func cloudCell() -> CAEmitterCell {
        let cell = particle(color: NSColor(srgbRed: 0.91, green: 0.86, blue: 0.76, alpha: 0.54),
                            rate: 50, lifetime: 4.5, velocity: 28, scale: 0.22)
        cell.xAcceleration = 4
        cell.yAcceleration = 2
        return cell
    }

    private static func atmosphereCells() -> [CAEmitterCell] {
        let distant = particle(color: NSColor(white: 0.94, alpha: 0.27),
                               rate: 7, lifetime: 6, velocity: 13, scale: 0.17)
        let foreground = particle(color: NSColor(srgbRed: 0.90, green: 0.79, blue: 0.68, alpha: 0.16),
                                  rate: 0.8, lifetime: 4, velocity: 57, scale: 2.8)
        foreground.scaleSpeed = 0.18
        foreground.emissionRange = .pi / 5
        return [distant, foreground]
    }

    private static func particle(color: NSColor, rate: Float, lifetime: Float,
                                 velocity: CGFloat, scale: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = dustSprite
        cell.color = color.cgColor
        cell.birthRate = rate
        cell.lifetime = lifetime
        cell.lifetimeRange = lifetime * 0.22
        cell.velocity = velocity
        cell.velocityRange = velocity * 0.6
        cell.emissionLongitude = .pi / 8
        cell.emissionRange = .pi / 3
        cell.scale = scale
        cell.scaleRange = scale * 0.62
        cell.alphaSpeed = -Float(color.alphaComponent) / lifetime
        return cell
    }

    private static let dustSprite: CGImage? = {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 18, height: 18, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: colorSpace,
                                        colors: [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.4).cgColor,
                                                 NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                        locations: [0, 0.27, 1]) else { return nil }
        let center = CGPoint(x: 9, y: 9)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 9, options: [])
        return context.makeImage()
    }()
}
