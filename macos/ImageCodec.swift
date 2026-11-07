import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

private func writeImage(_ image: CGImage, to output: URL, type: UTType, resolution: [String: Double]) throws {
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
    if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95 }
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
            case ("export", 4):
                let type: UTType
                switch args[3] {
                case "jpeg": type = .jpeg
                case "png": type = .png
                default: throw usage
                }
                let source = try ImageFile(input, type: .tiff)
                guard source.orientation == 1 else { throw CodecError("导出用 TIFF 的方向必须已规范化。") }
                try writeImage(source.image, to: output, type: type, resolution: source.resolution)
            default: throw usage
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static let usage = CodecError("用法：image-codec import-jpeg 输入.jpg 输出.tiff 或 image-codec export 输入.tiff 输出文件 jpeg|png")
}
