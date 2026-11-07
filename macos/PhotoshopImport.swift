import AppKit
import ApplicationServices
import Foundation
import ImageIO

enum PhotoshopImport {
    struct Snapshot {
        let url: URL
        let name: String
    }

    private enum Failure: LocalizedError {
        case notInstalled
        case notRunning
        case starting
        case launchFailed
        case notAuthorized
        case timedOut
        case noDocument
        case cloudDocument
        case unsupportedMode
        case unsupportedDepth
        case invalidSnapshot
        case hostError(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return L10n.surface("没有找到已安装的 Adobe Photoshop。")
            case .notRunning: return L10n.surface("请先打开 Photoshop，并切换到要导入的文档。")
            case .starting: return L10n.surface("Photoshop 正在启动。请打开文档后重试。")
            case .launchFailed: return L10n.surface("无法打开 Adobe Photoshop。")
            case .notAuthorized:
                return L10n.surface("请在「系统设置 → 隐私与安全性 → 自动化」中允许 PURE Neg 控制 Adobe Photoshop，然后重试。")
            case .timedOut:
                return L10n.surface("等待 Photoshop 创建临时副本超时。请等 Photoshop 完成当前操作后再试。")
            case .noDocument: return L10n.surface("Photoshop 中没有打开的文档。")
            case .cloudDocument: return L10n.surface("请先在 Photoshop 中将云文档另存为本地文件，再导入。")
            case .unsupportedMode: return L10n.surface("当前 Photoshop 文档须为 RGB 或灰度模式。")
            case .unsupportedDepth: return L10n.surface("当前 Photoshop 文档须为每通道 8 位或 16 位。")
            case .invalidSnapshot: return L10n.surface("Photoshop 没有返回可读取的临时 TIFF。")
            case .hostError(let message): return L10n.surface("Photoshop 无法创建临时副本。") + "\n" + message
            }
        }
    }

    private static let bundleIdentifier = "com.adobe.Photoshop"

    /// Runs synchronously on the caller's background queue. Only the temporary copy is saved.
    static func snapshot(in directory: URL) throws -> Snapshot {
        let running = runningApplications()
        guard let photoshop = preferred(in: running.filter(\.isFinishedLaunching)) else {
            if !running.isEmpty { throw Failure.starting }
            throw installedApplication() == nil ? Failure.notInstalled : Failure.notRunning
        }

        let token = UUID().uuidString
        let work = directory.appendingPathComponent("photoshop-" + token, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let output = work.appendingPathComponent("snapshot.tif")
        do {
            let source = script(output: output, copyName: "PURE Neg " + token)
            let result = try send(source, to: photoshop.processIdentifier)
            if result == "NO_DOCUMENT" { throw Failure.noDocument }
            if result == "CLOUD_DOCUMENT" { throw Failure.cloudDocument }
            if result == "UNSUPPORTED_MODE" { throw Failure.unsupportedMode }
            if result == "UNSUPPORTED_DEPTH" { throw Failure.unsupportedDepth }
            if result.hasPrefix("ERROR:") { throw Failure.hostError(String(result.dropFirst(6))) }

            guard result.hasPrefix("OK:"),
                  let image = CGImageSourceCreateWithURL(output as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(image) > 0,
                  let type = CGImageSourceGetType(image), type as String == "public.tiff" else {
                throw Failure.invalidSnapshot
            }
            let name = String(result.dropFirst(3))
            return Snapshot(url: output, name: name.isEmpty ? "Photoshop" : name)
        } catch {
            // On an Apple Event timeout Photoshop may still be writing and will close its copy itself.
            if !didTimeOut(error) { try? FileManager.default.removeItem(at: work) }
            throw error
        }
    }

    static func didTimeOut(_ error: Error) -> Bool {
        if case Failure.timedOut = error { return true }
        return false
    }

    /// Called by the UI to launch Photoshop or reveal a running instance.
    static func open() throws {
        if let photoshop = preferred(in: runningApplications()), photoshop.activate(options: []) { return }
        guard let application = installedApplication() else { throw Failure.notInstalled }
        guard NSWorkspace.shared.open(application) else { throw Failure.launchFailed }
    }

    private static func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter {
            !$0.isTerminated && $0.processIdentifier > 0
        }
    }

    private static func preferred(in applications: [NSRunningApplication]) -> NSRunningApplication? {
        applications.first(where: \.isActive) ?? applications.sorted { left, right in
            let leftIsBeta = isBeta(left.bundleURL)
            let rightIsBeta = isBeta(right.bundleURL)
            if leftIsBeta != rightIsBeta { return !leftIsBeta }
            return (left.launchDate ?? .distantPast) > (right.launchDate ?? .distantPast)
        }.first
    }

    private static func installedApplication() -> URL? {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier).sorted { left, right in
            if isBeta(left) != isBeta(right) { return !isBeta(left) }
            return left.lastPathComponent.compare(right.lastPathComponent, options: .numeric) == .orderedDescending
        }.first
    }

    private static func isBeta(_ url: URL?) -> Bool {
        url?.lastPathComponent.localizedCaseInsensitiveContains("Beta") == true
    }

    private static func send(_ javascript: String, to pid: pid_t) throws -> String {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        // Photoshop.sdef: public "do javascript" command misc/DjxM, direct parameter, text result.
        let event = NSAppleEventDescriptor(eventClass: 0x6D697363, eventID: 0x446A784D,
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: javascript), forKeyword: AEKeyword(keyDirectObject))
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 120)
        } catch {
            let native = error as NSError
            throw translateEventError(native.code, message: native.localizedDescription)
        }
        if let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, code != 0 {
            throw translateEventError(Int(code), message: reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue)
        }
        guard let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
            throw Failure.invalidSnapshot
        }
        return result
    }

    private static func translateEventError(_ code: Int, message: String?) -> Failure {
        switch code {
        case -1743, -1744: return .notAuthorized
        case Int(errAETimeout): return .timedOut
        case Int(procNotFound), -609: return .notRunning
        default: return .hostError(message ?? "Apple Event " + String(code))
        }
    }

    private static func script(output: URL, copyName: String) -> String {
        // ExtendScript's absolute URI path starts at /, with path-component bytes escaped.
        let uriCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/-_.!~*'()")
        let path = output.path.addingPercentEncoding(withAllowedCharacters: uriCharacters) ?? output.path
        return """
        (function () {
            var copy = null;
            var previousDialogs = app.displayDialogs;
            var result;
            try {
                if (app.documents.length === 0) return "NO_DOCUMENT";
                var original = app.activeDocument;
                if (original.cloudDocument === true) return "CLOUD_DOCUMENT";
                if (original.mode !== DocumentMode.RGB && original.mode !== DocumentMode.GRAYSCALE)
                    return "UNSUPPORTED_MODE";
                if (original.bitsPerChannel !== BitsPerChannelType.EIGHT &&
                    original.bitsPerChannel !== BitsPerChannelType.SIXTEEN)
                    return "UNSUPPORTED_DEPTH";

                var name = original.name;
                var tagged = original.colorProfileType !== ColorProfile.NONE;
                app.displayDialogs = DialogModes.NO;
                copy = original.duplicate(\(literal(copyName)), true);
                if (copy.layers.length !== 1 || !copy.layers[0].isBackgroundLayer) copy.flatten();
                var options = new TiffSaveOptions();
                options.embedColorProfile = tagged;
                options.layers = false;
                options.alphaChannels = false;
                options.transparency = false;
                options.spotColors = false;
                options.imageCompression = TIFFEncoding.NONE;
                options.interleaveChannels = true;
                copy.saveAs(new File(\(literal(path))), options, true, Extension.LOWERCASE);
                result = "OK:" + name;
            } catch (error) {
                result = "ERROR:" + error.message;
            } finally {
                try {
                    if (copy !== null) copy.close(SaveOptions.DONOTSAVECHANGES);
                } catch (error) {
                    result = "ERROR:" + error.message;
                } finally {
                    app.displayDialogs = previousDialogs;
                }
            }
            return result;
        })();
        """
    }

    private static func literal(_ value: String) -> String {
        // Escape each UTF-16 code unit for Photoshop's ExtendScript parser.
        "\"" + value.utf16.map { String(format: "\\u%04X", $0) }.joined() + "\""
    }
}
