import AppKit
import SwiftUI

enum SupportWindows {
    static var supportTitle: String { L10n.surface("支持 PURE Neg") }
    static var guideTitle: String { L10n.surface("PURE Neg 使用指南") }

    private static let actions = SupportWindowActions()
    private static var aboutWindow: NSWindow?
    private static var supportWindow: NSWindow?
    private static var guideWindow: NSWindow?

    static func supportControl() -> NSView {
        let button = NSButton(title: supportTitle, target: actions, action: #selector(SupportWindowActions.openSupport))
        button.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return StudioStyle.actionControl(button)
    }

    static func showAbout() {
        if aboutWindow == nil { aboutWindow = makeAboutWindow() }
        present(aboutWindow)
    }

    private static func makeAboutWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 428, height: 340),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = L10n.text("关于 \("PURE Neg")")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView()
        window.contentView = root
        StudioStyle.installBackdrop(in: window, root: root, contrastOpacity: 0.54)

        let icon = NSImageView(image: StudioStyle.appIcon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 82),
            icon.heightAnchor.constraint(equalToConstant: 82)
        ])
        let wordmark = StudioStyle.wordmark(width: 184, maxHeight: 38, fallbackSize: 27)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let versionText = build.isEmpty ? version : "\(version) (\(build))"
        let versionLabel = NSTextField(labelWithString: L10n.surface("版本 \(versionText)"))
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = StudioStyle.secondaryText
        let summary = NSTextField(labelWithString: L10n.surface("胶片扫描除尘与修整"))
        summary.font = .systemFont(ofSize: 15, weight: .medium)
        summary.textColor = StudioStyle.light
        let credits = NSTextField(labelWithString: L10n.surface("基于 Magnus Holmes 的 film-dust（MIT）"))
        credits.font = .systemFont(ofSize: 12)
        credits.textColor = StudioStyle.secondaryText

        let github = PrimaryActionButton(title: "GitHub", target: actions, action: #selector(SupportWindowActions.openProject))
        github.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
        github.imagePosition = .imageTrailing
        github.setAccessibilityLabel(L10n.surface("在 GitHub 上查看 PURE Neg"))
        var links = [StudioStyle.actionControl(github)]
        if Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") != nil {
            let notices = NSButton(title: L10n.surface("第三方许可"), target: actions, action: #selector(SupportWindowActions.openNotices))
            links.append(StudioStyle.actionControl(notices))
        }
        let linkRow = NSStackView(views: links)
        linkRow.alignment = .centerY
        linkRow.spacing = 8
        let content = NSStackView(views: [icon, wordmark, versionLabel, summary, credits, linkRow])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 8
        content.setCustomSpacing(13, after: icon)
        content.setCustomSpacing(18, after: versionLabel)
        content.setCustomSpacing(17, after: credits)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -6),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20)
        ])
        window.center()
        return window
    }

    static func showSupport() {
        if supportWindow == nil {
            supportWindow = makeWindow(title: supportTitle, size: NSSize(width: 520, height: 820),
                                       minimumSize: NSSize(width: 420, height: 520), content: PureNegSupportView())
        }
        present(supportWindow)
    }

    static func showGuide() {
        if guideWindow == nil {
            guideWindow = makeWindow(title: guideTitle, size: NSSize(width: 880, height: 680),
                                     minimumSize: NSSize(width: 760, height: 560), content: PureNegGuideView())
        }
        present(guideWindow)
    }

    private static func makeWindow<Content: View>(title: String, size: NSSize, minimumSize: NSSize, content: Content) -> NSWindow {
        let available = NSScreen.main?.visibleFrame.insetBy(dx: 20, dy: 20).size ?? size
        let initialSize = NSSize(width: min(size.width, available.width), height: min(size.height, available.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentMinSize = minimumSize
        window.isReleasedWhenClosed = false
        // An opaque window background: with .clear the title bar and the
        // guide's reading pane showed the window behind straight through.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = NSHostingView(rootView: content.environment(\.locale, L10n.locale))
        window.center()
        return window
    }

    private static func present(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

private final class SupportWindowActions: NSObject {
    @objc func openSupport() { SupportWindows.showSupport() }
    @objc func openProject() { NSWorkspace.shared.open(AppUpdates.projectURL) }
    @objc func openNotices() {
        if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            NSWorkspace.shared.open(notices)
        }
    }
}

private struct PureNegSupportView: View {
    @State private var showingDonors = false
    private static let artworkURL = Bundle.main.url(forResource: "SupportAlipay", withExtension: "jpg")
    private static let artwork = artworkURL.flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "cup.and.saucer")
                    .font(.system(size: 28, weight: .regular)).foregroundStyle(.secondary)
                Text(L10n.surface("请我喝杯咖啡")).font(.title2.weight(.semibold))
                Text(L10n.surface("如果 PURE Neg 对你有帮助，欢迎支持后续的开发与影像研究。"))
                    .font(.callout).multilineTextAlignment(.center)
                Text(L10n.surface("支持完全自愿，不影响任何功能，也无需付费解锁。"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

                if let artwork = Self.artwork {
                    Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(Text(L10n.surface("支付宝支持二维码，收款方 StudioPURE。请用支付宝扫码，并在支付前核对收款方。")))
                    Text(L10n.surface("支付宝扫码 · 收款方 StudioPURE"))
                        .font(.callout.weight(.medium))
                    Text(L10n.surface("请在支付前核对收款方，金额由你自行决定。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.surface("查看收款码原图"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        if let artworkURL = Self.artworkURL { NSWorkspace.shared.open(artworkURL) }
                    }.buttonStyle(.bordered)
                } else {
                    ContentUnavailableView(L10n.surface("收款码暂不可用"), systemImage: "qrcode")
                }
                Text(L10n.surface("感谢每一份支持，也感谢你反馈问题、分享实验和贡献代码。"))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10n.surface("捐赠者名单"), systemImage: "heart.text.clipboard") {
                    showingDonors = true
                }.buttonStyle(.bordered)
            }
            .foregroundStyle(.primary)
            .padding(24).frame(maxWidth: 460)
            .modifier(SupportGlass(cornerRadius: 20))
            .padding(20).frame(maxWidth: .infinity)
        }
        .background { SupportBackdrop(material: .underWindowBackground) }
        .frame(minWidth: 420, minHeight: 520)
        .sheet(isPresented: $showingDonors) {
            VStack(spacing: 0) {
                PureNegGuideView(initialTopic: .donors)
                HStack {
                    Spacer()
                    Button(L10n.surface("完成")) { showingDonors = false }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
    }
}

private enum GuideTopic: String, CaseIterable, Identifiable {
    case quickStart, batch, trainingFeedback, idleDetection, host, performance, technology, support, donors

    var id: Self { self }

    var title: String {
        switch self {
        case .quickStart: return L10n.surface("快速开始")
        case .batch: return L10n.surface("批量选片与导出")
        case .trainingFeedback: return L10n.surface("训练数据包与识别反馈")
        case .idleDetection: return L10n.surface("闲置检测")
        case .host: return L10n.surface("从其他应用载入")
        case .performance: return L10n.surface("性能与设置")
        case .technology: return L10n.surface("技术内核与开源项目")
        case .support: return SupportWindows.supportTitle
        case .donors: return L10n.surface("捐赠者名单")
        }
    }

    var symbol: String {
        switch self {
        case .quickStart: return "book"
        case .batch: return "film.stack"
        case .trainingFeedback: return "tray.and.arrow.up"
        case .idleDetection: return "clock.arrow.circlepath"
        case .host: return "arrow.down.app"
        case .performance: return "speedometer"
        case .technology: return "cpu"
        case .support: return "cup.and.saucer"
        case .donors: return "heart.text.clipboard"
        }
    }

    var paragraphs: [String] {
        var content: [String.LocalizationValue]
        switch self {
        case .quickStart:
            content = [
                "在「独立处理」中载入 TIFF 或 JPEG，按需勾选灰尘、划痕、毛发／纤维。点「直接开始除尘」会跳过观片台，开始检测已载入的照片。",
                "已载入的照片直接显示在来源页。可以继续添加照片或文件夹，也可以在列表中逐张移除。",
                "TIFF 内嵌缩略图明确标记为低分辨率预览时，按全尺寸主图处理。多页 TIFF 请先导出为单帧。",
                "在审核页切换「原图」「修复后」和「分割对比」。滚动缩放，按住空格拖动可平移。打开修复蒙版可查看将被修复的像素，颜色和不透明度可调。",
                "在左侧「检测灵敏度」下，调整已启用的灰尘、划痕和毛发／纤维滑块。点「重新检测」更新当前照片，运行期间仍显示上一版预览。手动笔画会保留，无法匹配的旧排除点位会提示复核。",
                "启用毛发／纤维检测后，可调整「纤维弯曲度」和「纤维软度」再重新检测。较高的弯曲度有助于找出短而弯的纤维，较高的软度会接纳更宽、更模糊的痕迹。调高后请检查发丝、褶皱和背景轮廓有没有被误修。",
                "「斑块（试验）」默认关闭，可尝试识别较宽的亮色碎屑和斑块。扫描包含片边时，在审核页开启「保留片边和齿孔」，预览会自动更新，保护检测到的片边、齿孔和片号。",
                "在检查模式把鼠标移到蒙版上的自动点位可查看检测类别。点击点位后，可在鼠标旁选择「撤销识别」，也可在左侧点位列表取消勾选。按 B 用画笔补修漏点，按 E 用橡皮擦恢复误修，按 V 返回检查。",
                "按 【 或 】 缩小或增大画笔半径。按 ⌘Z 撤销修整，按 ⇧⌘Z 重做。",
                "在导出窗口选择 TIFF、JPEG 或 PNG，可设置色彩空间、位深，以及相应的 TIFF 压缩或 JPEG 质量。色彩空间和位深可选择「保持原样」，JPEG 始终为 8 位。修复蒙版可按需附带。",
                "点「在观片器中查看」，用右下角电源点亮修复后的照片。支持 HDR 的屏幕会按可用亮度呈现观片效果。顶部按钮可左右旋转 90°、水平或垂直翻转，方向只用于预览。点击右下角的放大镜或直接把它拖到照片上，双击放大镜或拖回右下角可归位。",
                "拖动放大镜的蓝点可调整镜面大小，绿点可调整放大倍率。也可在镜内滚动或捏合缩放。放大镜获得焦点时，按 + 或 − 调整倍率，按住 Option 再按可调整镜面大小。"
            ]
        case .batch:
            content = [
                "载入多张 TIFF 或 JPEG 后，点「打开观片台」。在下方点底片将它移入候选区，再点一次可放回底片袋。候选区为空时，点「下一步」会纳入全部照片。",
                "观片台和审核页默认铺满所在屏幕的可用区域。审核时切换照片会保留窗口位置与尺寸。点「返回灯板」可以重新选片。",
                "观片台右下角的电源按钮可点亮灯板。支持 HDR 时，灯板、底片和底片袋的透光区域会提亮，边框与接缝以标准动态范围绘制。",
                "审核页右侧只列出本批选中的照片，并保留原始帧号。检测和导出进度显示在对应文件名下方。各帧独立保留画笔修整和排除点位。",
                "等待预览时，中央显示当前照片的模糊背景。细尘会成团卷过画面，近处偶尔掠过虚焦的颗粒。预览就绪后会显示清晰的修复结果。",
                "检查修复结果后，在左下角的「导出」区选择「导出当前」或「导出所选」。在右侧可逐张勾选预览就绪的照片，也可用「全选」或「全不选」操作。",
                "照片直接保存到所选目录，文件名以「-PN」标记，重名时自动加序号。导出后仍可在当前批次用画笔补修漏点或用橡皮擦恢复误修，再导出新版本。"
            ]
            #if PURENEG_TONE_CALIBRATION
            content.append("开灯后可在底部调整曝光、亮部、暗部和伽马。曝光以 0 EV 为基准，范围是 −8 至 +8 EV。亮部可调到屏幕当前可用的 HDR 上限，伽马调整中间调。点「确认」会保存这组数值和屏幕的 HDR 余量。")
            #endif
        case .trainingFeedback:
            content = [
                "遇到漏检或误修时，在审核页用画笔补修漏点，用「撤销识别」或橡皮擦恢复误修的细节。记录这些修整，有助于改进识别模型。",
                "打开「PURE Neg → 设置 → 导出」，开启「导出训练数据包」，再在导出窗口勾选「导出训练数据包」。照片若仍有未修整处，请取消勾选「这张已修干净（可用于训练）」。",
                "修复照片旁会生成一个以「-training」结尾的文件夹，包含未修复的扫描图、自动检测与手动修整的各层蒙版、修复点和检测设置。请保留整个文件夹。",
                "在复现问题的同一次运行中，打开「PURE Neg → 设置 → 维护」，点击「保存诊断报告…」。将未经修改的原片、整个训练数据包和诊断报告一起压缩成 ZIP，邮件发送至 easonzhang@studiopure.cn，并简单注明漏检或误修的位置。",
                "训练数据包和诊断报告都保存在本机，由你决定是否发送。请只提供你有权分享的照片。"
            ]
        case .idleDetection:
            content = [
                "批量审核时优先检测当前照片。检测中可直接点另一张切换，正在检测的照片会让出引擎。",
                "默认停止操作 4 秒后，后台逐张检测本批剩余照片。恢复滚动、缩放或拖动等操作时，后台检测会暂停并保留进度，重新闲置后继续。右侧列表会标出当前的后台状态。",
                "生成修整预览、导出或检测另一张照片需要使用引擎时，后台任务先让出引擎。为控制内存占用，闲置后可能从头检测那张被中断的照片。",
                "可在「PURE Neg → 设置 → 性能」关闭「闲置时自动检测」。右侧「停止检测」会停止当前批次的自动检测，点「检测本批」可重新开始。"
            ]
        case .host:
            content = [
                "选择「从 PhotoCraft 载入」并启动或连接专用会话，在该会话中打开照片。通过 PURE Neg 审核后可将修复图层和蒙版导回 PhotoCraft。",
                "在 Photoshop 中打开文档，然后选择「从 Photoshop 载入」并点「载入并预览」。首次使用时按 macOS 提示允许通信。PURE Neg 载入当前文档的可见合成，可审核并另存为新文件。"
            ]
        case .performance:
            content = [
                "在「PURE Neg → 设置」可以更改语言、默认导出格式、目录和蒙版选项，也可以清理旧审核缓存或保存本次运行的诊断报告。自动导出目录为 ~/Pictures/PURENeg，语言切换在重启后生效。",
                "在「性能」中可为支持的图像启用 Metal 预览。「处理模式」选「高性能」可并行解压支持的 TIFF。内存充足时，模型推理和基础检测也可同时进行。",
                "内存为 16 GB 或更少的 Mac 默认开启「节省内存」。它会缩小预览缓存，对超过 6400 万像素的照片用较小的工作图检测灰尘和纤维。细小痕迹的检测结果可能变化，修复和导出使用原始分辨率。"
            ]
        case .technology:
            content = [
                "自动检测和修补基于 Magnus Holmes 的 film-dust（MIT，基准提交 fcf68d6）。引擎使用 JavaScript，在可用时通过 Node-API 调用 C++ 内核加速滤波、检测和推理。PURE Neg 在原始像素上补充划痕检测与纤维追踪。",
                "FibreNet v3 用人工审核过的样本训练，通过 Core ML 在本机生成纤维概率图。引擎结合概率、线宽、形状和周边画面判断是否修复，并尝试沿纤维接回较淡的尾端。",
                "上游骨架细化使用 scikit-image 的查表方法。按上游许可说明，场景判断模型源自 torchvision 的 MobileNetV3-small ImageNet 权重。两项引用均采用 BSD 3-Clause 许可。",
                "应用内附 Node.js，图像处理在本机运行。界面使用 AppKit 与 SwiftUI，ImageIO 用于 JPEG 导入、JPEG 和 PNG 导出及预览，支持的预览可用 Core Image 与 Metal 加速。观片台的 HDR 光源使用 Core Animation 的扩展动态范围。",
                "闲置时启动后台任务的交互参考 Final Cut Pro 的后台渲染。PURE Neg 自行调度除尘任务，并通过 macOS 进程组一起暂停或恢复检测与解码进程。"
            ]
        case .support:
            content = ["欢迎自愿支持 PURE Neg 的开发与影像研究。支付宝收款方为 StudioPURE。"]
        case .donors:
            content = [
                "感谢支持 PURE Neg 开发与影像研究的朋友。",
                "J3RRYK33PF1T",
                "熊小默",
                "以后有新的捐赠者，名单会随版本更新持续追加。",
                "也感谢匿名支持、反馈问题和贡献代码的朋友。"
            ]
        }
        return content.map(L10n.surface)
    }
}

private struct PureNegGuideView: View {
    @State private var selection: GuideTopic?
    @State private var search = ""

    init(initialTopic: GuideTopic = .quickStart) {
        _selection = State(initialValue: initialTopic)
    }

    private var topics: [GuideTopic] {
        GuideTopic.allCases.filter { topic in
            search.isEmpty || ([topic.title] + topic.paragraphs).joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField(L10n.surface("搜索使用指南"), text: $search).textFieldStyle(.roundedBorder).padding(12)
                List(topics, selection: $selection) { topic in
                    Label(topic.title, systemImage: topic.symbol).tag(topic)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 220)
            .background(.regularMaterial)
            .onChange(of: search) {
                if let selection, topics.contains(selection) { return }
                selection = topics.first
            }
            Divider()
            if let selection {
                if selection == .support {
                    PureNegSupportView()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(selection.title).font(.largeTitle.weight(.semibold))
                            ForEach(Array(selection.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph).lineSpacing(5)
                            }
                            if selection == .quickStart {
                                Button(SupportWindows.supportTitle, systemImage: "cup.and.saucer") {
                                    self.selection = .support
                                }
                            }
                            if selection == .technology {
                                if let source = URL(string: "https://github.com/magholmes/film-dust/commit/fcf68d6c6a77e4373db28f878c7f80f7b8934f3f") {
                                    Link(L10n.surface("查看 film-dust 基准提交"), destination: source)
                                }
                                if let reference = URL(string: "https://support.apple.com/guide/final-cut-pro/ver717f3ca3/mac") {
                                    Link(L10n.surface("Final Cut Pro 后台渲染说明"), destination: reference)
                                }
                                if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                                    Button(L10n.surface("打开随应用附带的第三方许可说明")) { NSWorkspace.shared.open(notices) }
                                }
                            }
                        }
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(28)
                        .frame(maxWidth: 720, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(selection)
                }
            } else {
                ContentUnavailableView(L10n.surface("没有匹配的帮助"), systemImage: "book.closed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background { SupportBackdrop(material: .underWindowBackground) }
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct SupportGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            }
            #else
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            #endif
        }
    }
}

private struct SupportBackdrop: View {
    let material: NSVisualEffectView.Material
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                SupportWindowMaterial(material: material)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SupportWindowMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
