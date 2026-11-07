import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

final class AppUpdates {
    static let shared = AppUpdates()
    static let projectURL = URL(string: "https://github.com/easonzhangbin/PURENeg")!
    static let automaticChecksKey = "settings.automaticUpdateChecks"

    private static let releasesURL = projectURL.appendingPathComponent("releases")
    private static let releaseAPI = URL(string: "https://api.github.com/repos/easonzhangbin/PURENeg/releases/latest")!
    private static let lastCheckKey = "updates.lastAutomaticCheck"
    private static let lastNoticeKey = "updates.lastNotifiedVersion"

    private let session: URLSession
    private let preferences: UserDefaults
    private var checking = false
    private var manual = false
    private var showingAlert = false
    #if canImport(Sparkle)
    private var sparkle: SPUStandardUpdaterController?
    #endif

    init(session: URLSession = URLSession(configuration: .ephemeral), preferences: UserDefaults = .standard) {
        self.session = session
        self.preferences = preferences
    }

    func start() {
        #if canImport(Sparkle)
        _ = startSparkle()
        #endif
        checkAutomatically()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        #if canImport(Sparkle)
        if let updater = sparkle?.updater {
            updater.automaticallyChecksForUpdates = enabled
            return
        }
        #endif
        if enabled { checkAutomatically() }
    }

    func checkManually() {
        #if canImport(Sparkle)
        if let updater = startSparkle() {
            updater.checkForUpdates(nil)
            return
        }
        #endif
        check(manual: true)
    }

    #if canImport(Sparkle)
    private func startSparkle() -> SPUStandardUpdaterController? {
        if let sparkle { return sparkle }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        if let enabled = preferences.object(forKey: Self.automaticChecksKey) as? Bool,
           updater.updater.automaticallyChecksForUpdates != enabled {
            updater.updater.automaticallyChecksForUpdates = enabled
        }
        sparkle = updater
        return updater
    }
    #endif

    private func checkAutomatically() {
        #if canImport(Sparkle)
        if sparkle != nil { return }
        #endif
        guard preferences.object(forKey: Self.automaticChecksKey) as? Bool != false,
              Date().timeIntervalSince1970 - preferences.double(forKey: Self.lastCheckKey) >= 24 * 60 * 60,
              !checking else { return }
        preferences.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        check(manual: false)
    }

    private func check(manual: Bool) {
        guard !showingAlert else { return }
        self.manual = self.manual || manual
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: Self.releaseAPI, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PURENeg-macOS", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let result = Self.releaseStatus(data: data, status: (response as? HTTPURLResponse)?.statusCode,
                                            current: current, hadError: error != nil)
            DispatchQueue.main.async { self?.finished(result) }
        }.resume()
    }

    enum ReleaseStatus: Equatable {
        case update(String), current, unavailable, failed
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    static func releaseStatus(data: Data?, status: Int?, current: String, hadError: Bool = false) -> ReleaseStatus {
        if status == 404 { return .unavailable }
        guard !hadError, status == 200, let data,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              !release.draft, !release.prerelease,
              let latest = versionComponents(release.tag_name), let installed = versionComponents(current) else {
            return .failed
        }
        return installed.lexicographicallyPrecedes(latest) ? .update(release.tag_name) : .current
    }

    private static func versionComponents(_ tag: String) -> [Int]? {
        let version = tag.first == "v" || tag.first == "V" ? tag.dropFirst() : tag[...]
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }

    private func finished(_ result: ReleaseStatus) {
        checking = false
        let wasManual = manual
        manual = false
        let window = NSApp.keyWindow.flatMap { $0.isVisible && $0.attachedSheet == nil ? $0 : nil }
        if !wasManual {
            guard case .update(let tag) = result, NSApp.isActive, window != nil,
                  preferences.string(forKey: Self.lastNoticeKey) != tag else { return }
            preferences.set(tag, forKey: Self.lastNoticeKey)
        }
        let alert = NSAlert()
        let url: URL?
        switch result {
        case .update(let tag):
            alert.messageText = L10n.surface("发现 PURE Neg 新版本")
            alert.informativeText = L10n.surface("版本 \(tag) 已发布。打开 GitHub 下载更新。")
            alert.addButton(withTitle: L10n.surface("查看并下载更新"))
            alert.addButton(withTitle: L10n.surface("稍后"))
            url = Self.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
        case .current:
            alert.messageText = L10n.surface("你使用的是最新版本")
            alert.addButton(withTitle: L10n.surface("好"))
            url = nil
        case .unavailable, .failed:
            alert.messageText = L10n.surface("暂时无法检查更新")
            alert.informativeText = result == .unavailable
                ? L10n.surface("打开 GitHub 发布页并登录有访问权限的账号。")
                : L10n.surface("请检查网络后重试，也可以打开 GitHub 发布页。")
            alert.addButton(withTitle: L10n.surface("打开 GitHub 发布页"))
            alert.addButton(withTitle: L10n.surface("关闭"))
            url = Self.releasesURL
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.showingAlert = false
            if response == .alertFirstButtonReturn, let url { NSWorkspace.shared.open(url) }
        }
        showingAlert = true
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }
}
