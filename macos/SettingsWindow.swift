import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AppPreferences {
    fileprivate enum Key {
        static let exportFormat = "settings.exportFormat"
        static let includeMask = "settings.includeMask"
        static let exportFolder = "settings.exportFolder"
        static let cpuMode = "settings.cpuMode"
        static let gpuPreview = "settings.gpuPreview"
        static let conserveMemory = "settings.conserveMemory"
        static let autoDetectWhenIdle = "settings.autoDetectWhenIdle"
        static let language = "settings.language"
    }

    private static var defaults: UserDefaults { .standard }
    fileprivate static let defaultConserveMemory = ProcessInfo.processInfo.physicalMemory <= 16 * 1_024 * 1_024 * 1_024
    static let idleDetectionDelay: TimeInterval = 4

    static var exportFormat: String {
        let value = defaults.string(forKey: Key.exportFormat) ?? "tiff"
        return ["tiff", "jpeg", "png"].contains(value) ? value : "tiff"
    }

    static var includeMask: Bool { defaults.bool(forKey: Key.includeMask) }

    static var exportFolder: URL? {
        guard let path = defaults.string(forKey: Key.exportFolder), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var cpuMode: String {
        let value = defaults.string(forKey: Key.cpuMode) ?? "balanced"
        return ["balanced", "responsive", "efficient"].contains(value) ? value : "balanced"
    }

    static var gpuPreview: Bool { defaults.bool(forKey: Key.gpuPreview) }
    static var conserveMemory: Bool { defaults.object(forKey: Key.conserveMemory) as? Bool ?? defaultConserveMemory }
    static var autoDetectWhenIdle: Bool { defaults.object(forKey: Key.autoDetectWhenIdle) as? Bool ?? true }
    static var language: String { defaults.string(forKey: Key.language) == "en" ? "en" : "zh-Hans" }

    fileprivate static func text(_ chinese: String, _ english: String) -> String {
        language == "en" ? english : chinese
    }
}

enum AppDiagnostics {
    private struct Event {
        let operation: String
        let code: Int32
        let duration: TimeInterval
    }

    private static let lock = NSLock()
    private static var recent: [Event] = []
    private static let operations: Set<String> = [
        "doctor", "prepare", "prepare-photocraft", "photoshop-import", "preview", "confirm", "inspect-review"
    ]

    static func record(operation: String, code: Int32, duration: TimeInterval) {
        // Only known operation names enter the report. Worker output may contain file paths.
        let event = Event(operation: operations.contains(operation) ? operation : "other",
                          code: code, duration: duration.isFinite ? max(0, duration) : 0)
        lock.lock()
        defer { lock.unlock() }
        if recent.count == 32 { recent.removeFirst() }
        recent.append(event)
    }

    fileprivate static func report() -> String {
        lock.lock()
        let events = recent
        lock.unlock()
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "PURE Neg Diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "",
            "Settings",
            "CPU mode: \(AppPreferences.cpuMode)",
            "GPU preview: \(AppPreferences.gpuPreview)",
            "Conserve memory: \(AppPreferences.conserveMemory)",
            "Detect automatically when idle: \(AppPreferences.autoDetectWhenIdle)",
            "Language: \(AppPreferences.language)",
            "Default export format: \(AppPreferences.exportFormat)",
            "Include repair mask: \(AppPreferences.includeMask)",
            "Custom export folder configured: \(AppPreferences.exportFolder != nil)",
            "",
            "Recent operations in this session"
        ]
        if events.isEmpty { lines.append("No operations recorded.") }
        for event in events {
            let seconds = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), event.duration)
            lines.append("\(event.operation) | exit \(event.code) | \(seconds) s")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

@MainActor
enum SettingsWindow {
    private static let actions = SettingsActions()
    private static var window: NSWindow?

    static func show(canClean: @escaping () -> Bool) {
        actions.canClean = canClean
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 430),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: PureNegSettingsView(actions: actions))
            panel.center()
            actions.window = panel
            window = panel
        }
        actions.updateTitle()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class SettingsActions: ObservableObject {
    private enum Result {
        case noCaches, moved(Int, failed: Int), busy, cacheError, reportSaved, reportError
    }

    weak var window: NSWindow?
    var canClean: () -> Bool = { false }
    @Published private(set) var cleaning = false
    @Published private var result: Result?

    var status: String {
        switch result {
        case nil:
            return ""
        case .noCaches:
            return AppPreferences.text("没有可清理的旧审核缓存。", "No old review caches to clear.")
        case .moved(let count, failed: 0):
            return AppPreferences.text("已将 \(count) 份旧审核缓存移到废纸篓。", "Moved \(count) old review caches to the Trash.")
        case .moved(let count, let failed):
            return AppPreferences.text("已移到废纸篓 \(count) 份，\(failed) 份未能移动。",
                                       "Moved \(count) to the Trash. Could not move \(failed).")
        case .busy:
            return AppPreferences.text("请结束审核或处理任务，并关闭其他 PURE Neg 窗口实例后重试。",
                                       "Finish any reviews or jobs and close other copies of PURE Neg, then try again.")
        case .cacheError:
            return AppPreferences.text("无法读取审核缓存。", "Could not read the review cache.")
        case .reportSaved:
            return AppPreferences.text("诊断报告已保存。", "The diagnostic report was saved.")
        case .reportError:
            return AppPreferences.text("无法保存诊断报告。", "Could not save the diagnostic report.")
        }
    }

    func updateTitle() {
        window?.title = AppPreferences.text("PURE Neg 设置", "PURE Neg Settings")
    }

    func chooseExportFolder(onChoose: @escaping (URL) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = AppPreferences.text("选择默认导出位置", "Choose Default Export Location")
        panel.prompt = AppPreferences.text("选择", "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AppPreferences.exportFolder
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { onChoose(url) }
        }
    }

    func saveReport() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = AppPreferences.text("保存诊断报告", "Save Diagnostic Report")
        panel.prompt = AppPreferences.text("保存", "Save")
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "PURE Neg Diagnostics.txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try AppDiagnostics.report().write(to: url, atomically: true, encoding: .utf8)
                self?.result = .reportSaved
            } catch {
                self?.result = .reportError
            }
        }
    }

    func cleanCache() {
        guard !cleaning else { return }
        guard cacheCleanupAllowed else { result = .busy; return }
        cleaning = true
        result = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Swift.Result { try OldReviewCaches.find() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.cleaning = false }
                guard self.cacheCleanupAllowed else { self.result = .busy; return }
                switch found {
                case .success(let candidates):
                    self.trash(candidates)
                case .failure:
                    self.result = .cacheError
                }
            }
        }
    }

    private var cacheCleanupAllowed: Bool {
        guard canClean() else { return false }
        let identifier = "local.filmdust.photocraft.review"
        let current = ProcessInfo.processInfo.processIdentifier
        let instances = [identifier, identifier + ".validation"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
        return instances.allSatisfy {
            $0.processIdentifier == current || $0.isTerminated
        }
    }

    private func trash(_ candidates: [URL]) {
        var moved = 0
        var failed = 0
        for url in candidates where OldReviewCaches.isStillOld(url) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved += 1
            } catch {
                failed += 1
            }
        }
        result = moved == 0 && failed == 0 ? .noCaches : .moved(moved, failed: failed)
    }
}

private enum OldReviewCaches {
    private static let age: TimeInterval = 7 * 24 * 60 * 60

    private static var roots: [URL] {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        return ["PURENeg", "PhotoCraft Film Dust"].map {
            support.appendingPathComponent($0, isDirectory: true).appendingPathComponent("reviews", isDirectory: true)
        }
    }

    static func find() throws -> [URL] {
        try roots.filter(isExpectedRoot).flatMap { root in
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        }
            .filter { directory in
                guard let manifest = oldManifest(in: directory),
                      let data = try? Data(contentsOf: manifest, options: .mappedIfSafe),
                      let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let signature = envelope["signature"] as? String,
                      signature.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                      let record = envelope["record"] as? [String: Any],
                      record["schema"] as? String == "photocraft-film-dust-review",
                      record["version"] as? Int == 1,
                      record["id"] as? String == directory.lastPathComponent,
                      let status = record["status"] as? String, ["ready", "confirmed"].contains(status) else { return false }
                return true
            }
    }

    static func isStillOld(_ directory: URL) -> Bool {
        // A new URL gets fresh metadata after the background scan.
        oldManifest(in: URL(fileURLWithPath: directory.path, isDirectory: true)) != nil
    }

    private static func oldManifest(in directory: URL) -> URL? {
        let root = directory.deletingLastPathComponent().standardizedFileURL
        guard roots.contains(where: { $0.standardizedFileURL == root }), isExpectedRoot(root),
              UUID(uuidString: directory.lastPathComponent) != nil,
              let metadata = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
              metadata.isDirectory == true, metadata.isSymbolicLink == false,
              let modified = metadata.contentModificationDate, modified.timeIntervalSinceNow <= -age else { return nil }
        let fm = FileManager.default
        let lock = directory.appendingPathComponent("confirm.lock")
        guard (try? fm.attributesOfItem(atPath: lock.path)) == nil else { return nil }
        let manifest = directory.appendingPathComponent("review.json")
        guard let file = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]),
              file.isRegularFile == true, file.isSymbolicLink == false,
              let size = file.fileSize, size > 0, size <= 16 * 1024 * 1024,
              let manifestModified = file.contentModificationDate, manifestModified.timeIntervalSinceNow <= -age else { return nil }
        return manifest
    }

    private static func isExpectedRoot(_ root: URL) -> Bool {
        for directory in [root, root.deletingLastPathComponent()] {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink == false else { return false }
        }
        return true
    }
}

private struct PureNegSettingsView: View {
    @ObservedObject var actions: SettingsActions
    @AppStorage(AppPreferences.Key.exportFormat) private var exportFormat = "tiff"
    @AppStorage(AppPreferences.Key.includeMask) private var includeMask = false
    @AppStorage(AppPreferences.Key.exportFolder) private var exportFolder = ""
    @AppStorage(AppPreferences.Key.cpuMode) private var cpuMode = "balanced"
    @AppStorage(AppPreferences.Key.gpuPreview) private var gpuPreview = false
    @AppStorage(AppPreferences.Key.conserveMemory) private var conserveMemory = AppPreferences.defaultConserveMemory
    @AppStorage(AppPreferences.Key.autoDetectWhenIdle) private var autoDetectWhenIdle = true
    @AppStorage(AppPreferences.Key.language) private var language = "zh-Hans"

    var body: some View {
        let idleSeconds = Int(AppPreferences.idleDetectionDelay)
        TabView {
            Form {
                Picker(label("界面语言", "Interface language"), selection: $language) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Text(label("重新打开 PURE Neg 后应用界面语言。", "Reopen PURE Neg to apply the interface language."))
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label(label("通用", "General"), systemImage: "gearshape") }

            Form {
                Picker(label("默认格式", "Default format"), selection: $exportFormat) {
                    Text("TIFF").tag("tiff")
                    Text("JPEG").tag("jpeg")
                    Text("PNG").tag("png")
                }
                Toggle(label("默认附带修复蒙版", "Include the repair mask by default"), isOn: $includeMask)
                Section(label("默认导出位置", "Default export location")) {
                    Text(exportFolder.isEmpty ? label("自动", "Automatic") : exportFolder)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(exportFolder)
                    HStack {
                        Button(label("选择文件夹…", "Choose Folder…")) {
                            actions.chooseExportFolder { exportFolder = $0.path }
                        }
                        Button(label("使用自动位置", "Use Automatic Location")) { exportFolder = "" }
                            .disabled(exportFolder.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(label("导出", "Export"), systemImage: "square.and.arrow.up") }

            Form {
                Picker(label("CPU 调度", "CPU scheduling"), selection: $cpuMode) {
                    Text(label("平衡", "Balanced")).tag("balanced")
                    Text(label("优先响应", "Prefer Responsiveness")).tag("responsive")
                    Text(label("节能", "Energy Efficient")).tag("efficient")
                }
                Toggle(label("GPU 预览", "GPU preview"), isOn: $gpuPreview)
                Text(label("为支持的图像启用 Metal 预览。自动检测由 CPU 完成。",
                           "Use Metal for supported previews. Automatic detection runs on the CPU."))
                    .foregroundStyle(.secondary)
                Toggle(label("节省内存", "Conserve memory"), isOn: $conserveMemory)
                Text(label("内存为 16 GB 或更少的 Mac 默认开启。缩小预览缓存。超过 6400 万像素时，自动灰尘和纤维检测使用缩小的工作图，细小痕迹的检测结果可能变化。修复和导出使用原始分辨率。",
                           "On by default on Macs with 16 GB of memory or less. Uses a smaller preview cache. On scans over 64 megapixels, automatic dust and fiber detection uses a smaller working image, which can change results for fine details. Repair and export use the original resolution."))
                    .foregroundStyle(.secondary)
                Text(label("性能设置会应用到后续启动的任务和打开的预览。", "Performance settings apply to new jobs and previews."))
                    .foregroundStyle(.secondary)
                Toggle(label("闲置时自动检测", "Detect Automatically When Idle"), isOn: $autoDetectWhenIdle)
                Text(label("优先处理当前照片和修整操作。闲置 \(idleSeconds) 秒后，后台会自动开始或恢复检测其余照片。",
                           "The current photo and your edits take priority. After \(idleSeconds) seconds of inactivity, background detection starts or resumes on the remaining photos."))
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label(label("性能", "Performance"), systemImage: "speedometer") }

            Form {
                Section(label("本地缓存", "Local cache")) {
                    Text(label("将七天前的审核缓存移到废纸篓。请先结束审核或处理任务。",
                               "Move review caches older than seven days to the Trash. Finish any reviews or jobs first."))
                        .foregroundStyle(.secondary)
                    Button(label("清理旧审核缓存", "Clear Old Review Caches"), action: actions.cleanCache)
                        .disabled(actions.cleaning)
                }
                Section(label("诊断", "Diagnostics")) {
                    Text(label("报告仅包含版本、相关设置及本次运行的操作结果。",
                               "The report contains versions, relevant settings, and operation results from this session."))
                        .foregroundStyle(.secondary)
                    Button(label("保存诊断报告…", "Save Diagnostic Report…"), action: actions.saveReport)
                }
                if actions.cleaning {
                    ProgressView(label("正在检查审核缓存…", "Checking review caches…"))
                } else if !actions.status.isEmpty {
                    Text(actions.status).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(label("维护", "Maintenance"), systemImage: "wrench.and.screwdriver") }
        }
        .padding(14)
        .frame(width: 610, height: 430)
        .environment(\.locale, Locale(identifier: language))
        .onChange(of: language) { _, _ in actions.updateTitle() }
    }

    private func label(_ chinese: String, _ english: String) -> String { language == "en" ? english : chinese }
}
