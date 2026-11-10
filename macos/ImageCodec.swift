import CoreGraphics
import CoreML
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

private struct CodecError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}

private struct ImageFile {
    let properties: [String: Any]
    let image: CGImage

    init(_ url: URL, type: UTType) throws {
        let decodedSource: CGImageSource?
        if type == .jpeg {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard completeJPEG(data) else { throw CodecError("JPEG 数据不完整或已损坏。") }
            decodedSource = CGImageSourceCreateWithData(data as CFData, nil)
        } else {
            decodedSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let source = decodedSource,
              let identifier = CGImageSourceGetType(source), identifier as String == type.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 300_000_000 / height else {
            throw CodecError("无法读取图像。请选择单张、尺寸不超过 300MP 的 \(type == .jpeg ? "JPEG" : "TIFF")。")
        }
        if let model = properties[kCGImagePropertyColorModel as String] as? String,
           model != kCGImagePropertyColorModelRGB as String,
           model != kCGImagePropertyColorModelGray as String {
            throw CodecError("仅支持 RGB 和灰度图像。")
        }
        if let depth = properties[kCGImagePropertyDepth as String] as? Int, depth != 8 && depth != 16 {
            throw CodecError("仅支持 8 位和 16 位整数图像。")
        }
        let options = [kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let model = image.colorSpace?.model, model == .rgb || model == .monochrome else {
            throw CodecError("图像解码失败。请选择完整的 RGB 或灰度图像。")
        }
        guard (image.bitsPerComponent == 8 || image.bitsPerComponent == 16),
              !image.bitmapInfo.contains(.floatComponents) else {
            throw CodecError("仅支持 8 位和 16 位整数图像。")
        }
        self.properties = properties
        self.image = image
    }

    var orientation: Int { properties[kCGImagePropertyOrientation as String] as? Int ?? 1 }

    var resolution: [String: Double] {
        let x = kCGImagePropertyDPIWidth as String, y = kCGImagePropertyDPIHeight as String
        let swap = orientation >= 5
        var values: [String: Double] = [:]
        values[x] = properties[swap ? y : x] as? Double
        values[y] = properties[swap ? x : y] as? Double
        return values
    }

    func normalizedJPEG() throws -> CGImage {
        guard (1...8).contains(orientation), image.bitsPerComponent == 8 else {
            throw CodecError("仅支持标准方向的 8 位 JPEG。")
        }
        if orientation == 1 { return image }
        return try rotateJPEG(image, orientation: orientation)
    }
}

// ImageIO can decode a truncated JPEG and fill in missing pixels. Confirm an
// end marker in the main stream, skipping APP metadata and entropy escapes.
private func completeJPEG(_ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard raw.count >= 4, raw[0] == 0xff, raw[1] == 0xd8, let bytes = raw.baseAddress else { return false }
        var offset = 2, scanning = false, sawScan = false
        while offset < raw.count {
            if scanning {
                guard let marker = memchr(bytes + offset, 0xff, raw.count - offset) else { return false }
                offset = bytes.distance(to: UnsafeRawPointer(marker))
            } else if raw[offset] != 0xff {
                return false
            }
            repeat { offset += 1 } while offset < raw.count && raw[offset] == 0xff
            guard offset < raw.count else { return false }
            let marker = raw[offset]
            offset += 1
            if marker == 0xd9 { return sawScan }
            if marker == 0x00 || (0xd0...0xd7).contains(marker) {
                if scanning { continue }
                return false
            }
            if marker == 0x01 { continue }
            guard marker != 0xd8, raw.count - offset >= 2 else { return false }
            let length = 256 * Int(raw[offset]) + Int(raw[offset + 1])
            guard length >= 2, length <= raw.count - offset else { return false }
            offset += length
            scanning = marker == 0xda
            sawScan = sawScan || scanning
        }
        return false
    }
}

private func rotateJPEG(_ image: CGImage, orientation: Int) throws -> CGImage {
    let pixel = image.bitsPerPixel / 8, row = image.bytesPerRow
    guard let space = image.colorSpace, let raster = image.dataProvider?.data,
          let source = CFDataGetBytePtr(raster),
          [1, 3, 4].contains(pixel), image.bitsPerPixel == 8 * pixel,
          row >= image.width * pixel, row <= CFDataGetLength(raster) / image.height else {
        throw CodecError("无法读取用于校正 JPEG 拍摄方向的像素。")
    }
    let lastColumn = (image.width - 1) * pixel, lastRow = (image.height - 1) * row
    let start: Int, stepX: Int, stepY: Int
    switch orientation {
    case 2: (start, stepX, stepY) = (lastColumn, -pixel, row)
    case 3: (start, stepX, stepY) = (lastRow + lastColumn, -pixel, -row)
    case 4: (start, stepX, stepY) = (lastRow, pixel, -row)
    case 5: (start, stepX, stepY) = (0, row, pixel)
    case 6: (start, stepX, stepY) = (lastRow, -row, pixel)
    case 7: (start, stepX, stepY) = (lastRow + lastColumn, -row, -pixel)
    case 8: (start, stepX, stepY) = (lastColumn, row, -pixel)
    default: throw CodecError("JPEG 拍摄方向无效。")
    }
    // Remap decoded pixels without drawing through a color space. The
    // ImageIO thumbnail transform can change gray samples near odd edges.
    let swap = orientation >= 5
    let width = swap ? image.height : image.width, height = swap ? image.width : image.height
    let bytesPerRow = width * pixel
    var rotated = Data(count: bytesPerRow * height)
    rotated.withUnsafeMutableBytes { buffer in
        guard let target = buffer.baseAddress else { return }
        for y in 0..<height {
            var offset = start + y * stepY
            var output = target + y * bytesPerRow
            for _ in 0..<width {
                output.copyMemory(from: source + offset, byteCount: pixel)
                offset += stepX
                output += pixel
            }
        }
    }
    guard let provider = CGDataProvider(data: rotated as CFData),
          let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: image.bitsPerPixel,
                               bytesPerRow: bytesPerRow, space: space, bitmapInfo: image.bitmapInfo,
                               provider: provider, decode: nil, shouldInterpolate: false, intent: image.renderingIntent) else {
        throw CodecError("无法在原尺寸和色彩模式下校正 JPEG 拍摄方向。")
    }
    return result
}

private func writeImage(_ image: CGImage, to output: URL, type: UTType, resolution: [String: Double],
                        quality: Double = 0.95, lzw: Bool = false) throws {
    let temporary = output.deletingLastPathComponent().appendingPathComponent(".image-codec-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
        throw CodecError("无法创建图像输出文件。")
    }
    var properties: [String: Any] = [kCGImageDestinationOptimizeColorForSharing as String: false]
    for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
        if let dpi = resolution[key as String], dpi.isFinite && dpi > 0 {
            properties[key as String] = dpi
        }
    }
    if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality as String] = quality }
    if type == .tiff && lzw { properties[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFCompression as String: 5] }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination),
          let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
          let encoded = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          encoded[kCGImagePropertyPixelWidth as String] as? Int == image.width,
          encoded[kCGImagePropertyPixelHeight as String] as? Int == image.height,
          encoded[kCGImagePropertyDepth as String] as? Int == (type == .jpeg ? 8 : image.bitsPerComponent) else {
        throw CodecError("图像编码失败，或输出尺寸与位深发生了变化。")
    }
    try FileManager.default.moveItem(at: temporary, to: output)
}

/// [Claude 2026-11-09] The image in another colour space and/or bit depth, converted by
/// ColorSync (relative colorimetric, as CGContext draws). "keep" and an unchanged depth return
/// the image untouched, so a plain export stays bit-exact.
private func converted(_ image: CGImage, space: String, depth: Int) throws -> CGImage {
    let names: [String: CFString] = ["srgb": CGColorSpace.sRGB, "p3": CGColorSpace.displayP3, "adobergb": CGColorSpace.adobeRGB1998]
    guard space == "keep" || names[space] != nil, depth == 8 || depth == 16 else { throw CodecError("导出色彩空间或位深无效。") }
    if space == "keep" && depth == image.bitsPerComponent { return image }
    let target = space == "keep" ? (image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) : CGColorSpace(name: names[space]!)!
    guard target.model == .rgb || target.model == .monochrome else { throw CodecError("仅支持 RGB 和灰度图像。") }
    let gray = target.model == .monochrome
    let info: UInt32 = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let order: UInt32 = depth == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: depth, bytesPerRow: 0,
                                  space: target, bitmapInfo: info | order) else { throw CodecError("无法转换色彩空间。") }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = context.makeImage() else { throw CodecError("无法转换色彩空间。") }
    return result
}

/// [Claude 2026-11-08] The eyes of the faces in a scan, as JSON [{"x", "y", "r"}] in pixels
/// from the top-left. The engine leaves repairs there alone: a catchlight is a small round
/// bright speck on a dark ground, which is exactly what a dust speck looks like by itself.
private func findEyes(in image: CGImage, to output: URL) throws {
    // Vision is much slower on 16-bit TIFF rasters. Convert only its input,
    // keeping the original dimensions so landmark coordinates stay aligned.
    let visionImage = try converted(image, space: "keep", depth: 8)
    let request = VNDetectFaceLandmarksRequest()
    try VNImageRequestHandler(cgImage: visionImage, options: [:]).perform([request])
    let size = CGSize(width: image.width, height: image.height)
    var eyes: [[String: Double]] = []
    for face in request.results ?? [] {
        guard let landmarks = face.landmarks else { continue }
        for (eye, pupil) in [(landmarks.leftEye, landmarks.leftPupil), (landmarks.rightEye, landmarks.rightPupil)] {
            guard let outline = eye?.pointsInImage(imageSize: size), !outline.isEmpty else { continue }
            let xs = outline.map(\.x), ys = outline.map(\.y)
            guard let left = xs.min(), let right = xs.max(), let bottom = ys.min(), let top = ys.max() else { continue }
            let center = pupil?.pointsInImage(imageSize: size).first
                ?? CGPoint(x: (left + right) / 2, y: (bottom + top) / 2)
            // The opening of the eye, so a catchlight off the pupil is covered too.
            let radius = max(0.45 * (right - left), 0.75 * (top - bottom), 6)
            // Vision's origin is the bottom-left corner.
            eyes.append(["x": Double(center.x), "y": Double(size.height - center.y), "r": Double(radius)])
        }
    }
    try JSONSerialization.data(withJSONObject: eyes).write(to: output, options: .atomic)
}

/// [Claude 2026-11-08] The learned defect map: for every pixel, how likely it is dust or a
/// fibre on the film (0-255), written as raw bytes, row by row. The model (FibreNet, a small
/// U-Net trained on the user's corrected frames) sits next to this executable. It works on
/// fixed 576 px tiles of RGB in 0...1; each tile keeps its central 512 px, so every kept
/// pixel has 32 px of context. The engine only uses the map to find where fibres start;
/// its own tracer and scene tests still decide what is repaired.
private func fibreMap(in image: CGImage, to output: URL) throws {
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let model = try MLModel(contentsOf: here.appendingPathComponent("FibreNet.mlmodelc"), configuration: configuration)
    let W = image.width, H = image.height, T = 576, keep = 512, pad = (T - keep) / 2
    var rgba = [UInt8](repeating: 0, count: W * H * 4)
    guard let context = CGContext(data: &rgba, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CodecError("无法读取图像像素。") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    var map = [UInt8](repeating: 0, count: W * H)
    let input = try MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
    let plane = T * T
    for ty in stride(from: 0, to: H, by: keep) {
        for tx in stride(from: 0, to: W, by: keep) {
            // The tile, edges repeated where it runs past the image (as in training).
            let inPtr = input.dataPointer.bindMemory(to: Float32.self, capacity: 3 * plane)
            for y in 0..<T {
                let sy = min(max(ty - pad + y, 0), H - 1)
                for x in 0..<T {
                    let sx = min(max(tx - pad + x, 0), W - 1), s = (sy * W + sx) * 4, d = y * T + x
                    inPtr[d] = Float32(rgba[s]) / 255
                    inPtr[plane + d] = Float32(rgba[s + 1]) / 255
                    inPtr[2 * plane + d] = Float32(rgba[s + 2]) / 255
                }
            }
            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["rgb": input]))
            guard let prob = result.featureValue(for: "prob")?.multiArrayValue else { throw CodecError("模型没有输出。") }
            let rowStride = prob.strides[2].intValue, colStride = prob.strides[3].intValue
            let value: (Int) -> Float
            switch prob.dataType {
            case .float16:
                let p = prob.dataPointer.bindMemory(to: Float16.self, capacity: prob.count)
                value = { Float(p[$0]) }
            case .float32:
                let p = prob.dataPointer.bindMemory(to: Float32.self, capacity: prob.count)
                value = { p[$0] }
            default:
                value = { prob[$0].floatValue }
            }
            for y in 0..<min(keep, H - ty) {
                for x in 0..<min(keep, W - tx) {
                    let v = value((y + pad) * rowStride + (x + pad) * colStride)
                    map[(ty + y) * W + tx + x] = UInt8(max(0, min(255, (v * 255).rounded())))
                }
            }
        }
    }
    try Data(map).write(to: output, options: .atomic)
}

@main
private struct ImageCodec {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 3 else { throw usage }
            let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
            switch (args[0], args.count) {
            case ("import-jpeg", 3):
                let source = try ImageFile(input, type: .jpeg)
                try writeImage(source.normalizedJPEG(), to: output, type: .tiff, resolution: source.resolution)
            case ("export", 4...):
                // [Claude 2026-11-09] Optional settings after the format, as key=value:
                // space=keep|srgb|p3|adobergb, depth=keep|8|16, compression=none|lzw (TIFF),
                // quality=0.5...1 (JPEG). Without them the image is written as it is.
                let type: UTType
                switch args[3] {
                case "jpeg": type = .jpeg
                case "png": type = .png
                case "tiff": type = .tiff
                default: throw usage
                }
                var options: [String: String] = [:]
                for item in args.dropFirst(4) {
                    let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { throw usage }
                    options[parts[0]] = parts[1]
                }
                let source = try ImageFile(input, type: .tiff)
                guard source.orientation == 1 else { throw CodecError("导出用 TIFF 的方向必须已规范化。") }
                let depth = options["depth"].flatMap(Int.init) ?? (type == .jpeg ? 8 : source.image.bitsPerComponent)
                let image = try converted(source.image, space: options["space"] ?? "keep", depth: depth)
                let quality = options["quality"].flatMap(Double.init).map { min(1, max(0.5, $0)) } ?? 0.95
                try writeImage(image, to: output, type: type, resolution: source.resolution,
                               quality: quality, lzw: options["compression"] == "lzw")
            case ("eyes", 3):
                try findEyes(in: ImageFile(input, type: .tiff).image, to: output)
            case ("fibremap", 3):
                try fibreMap(in: ImageFile(input, type: .tiff).image, to: output)
            default: throw usage
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static let usage = CodecError("用法：image-codec import-jpeg 输入.jpg 输出.tiff 或 image-codec export 输入.tiff 输出文件 tiff|jpeg|png [space=keep|srgb|p3|adobergb] [depth=keep|8|16] [compression=none|lzw] [quality=0.5-1]")
}
