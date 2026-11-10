import AppKit
import ImageIO

final class BatchReviewSidebar: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    struct Item: Equatable {
        let id: UUID
        let url: URL
        let number: Int
        let name: String
        let status: String
        let isCurrent: Bool
        let canExport: Bool
        let canOpen: Bool
    }

    var onOpen: ((UUID) -> Void)?
    var onToggle: ((UUID) -> Void)?
    // [Claude 2026-11-09] Select all / none for export: true ticks every exportable photo.
    var onToggleAll: ((Bool) -> Void)?
    var onDetect: (() -> Void)?
    var onStop: (() -> Void)?
    var onThumbnailReady: ((URL, CGImage) -> Void)?

    private let table = NSTableView()
    private let frameCount = NSTextField(labelWithString: "")
    private let selectAllButton = NSButton(title: L10n.surface("全选"), target: nil, action: nil)
    private let activity = NSTextField(wrappingLabelWithString: "")
    private let detectButton = NSButton(title: L10n.surface("检测本批"), target: nil, action: nil)
    private let stopButton = NSButton(title: L10n.surface("停止检测"), target: nil, action: nil)
    private lazy var detectControl = StudioStyle.actionControl(detectButton)
    private lazy var stopControl = StudioStyle.actionControl(stopButton)

    private var items: [Item] = []
    private var checked = Set<UUID>()
    private var busy = false
    private var updatingTable = false
    private var progressID: UUID?
    private var progressRowIndex: Int?
    private var progressFraction: Double = 0

    init() {
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        let borderAlpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.32 : 0.14
        layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor
        layer?.borderWidth = 1

        buildInterface()
        update(items: [], checked: [], busy: false)
        setActivity("", canDetect: false, canStop: false)
    }

    required init?(coder: NSCoder) { nil }

    func update(items: [Item], checked: Set<UUID>, busy: Bool) {
        let previousCurrent = self.items.first(where: \.isCurrent)?.id
        let checked = Set(items.filter { $0.canExport && checked.contains($0.id) }.map(\.id))
        let needsReload = self.items != items || self.checked != checked || self.busy != busy
        self.items = items
        self.checked = checked
        self.busy = busy

        frameCount.stringValue = L10n.surface("\(items.count) 张")
        let exportable = items.filter(\.canExport)
        let allChecked = !exportable.isEmpty && exportable.allSatisfy { checked.contains($0.id) }
        selectAllButton.title = allChecked ? L10n.surface("全不选") : L10n.surface("全选")
        selectAllButton.isEnabled = !exportable.isEmpty && !busy

        guard needsReload else { return }
        progressRowIndex = progressID.flatMap { id in items.firstIndex { $0.id == id } }
        updatingTable = true
        defer { updatingTable = false }
        table.reloadData()
        if let row = items.firstIndex(where: \.isCurrent) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if items[row].id != previousCurrent {
                let currentID = items[row].id
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.items.indices.contains(row), self.items[row].id == currentID,
                          self.items[row].isCurrent, self.progressRowIndex == nil else { return }
                    self.table.scrollRowToVisible(row)
                }
            }
        } else {
            table.deselectAll(nil)
        }
    }

    @objc private func toggleAll() {
        let exportable = items.filter(\.canExport)
        onToggleAll?(!(exportable.allSatisfy { checked.contains($0.id) }))
    }

    func setActivity(_ status: String, canDetect: Bool, canStop: Bool) {
        activity.stringValue = status
        activity.toolTip = status.isEmpty ? nil : status
        detectButton.isEnabled = canDetect
        stopButton.isEnabled = canStop
        detectControl.isHidden = canStop
        stopControl.isHidden = !canStop
    }

    func setProgress(id: UUID?, fraction: Double?, follow: Bool) {
        let reportedFraction = fraction ?? 0
        let value = id != nil && reportedFraction.isFinite ? min(max(reportedFraction, 0), 1) : 0
        if progressID == id {
            guard progressFraction != value else { return }
            progressFraction = value
            if let progressRowIndex { updateVisibleProgress(in: progressRowIndex) }
            return
        }

        let previousRow = progressRowIndex
        progressID = id
        progressFraction = value
        progressRowIndex = id.flatMap { id in items.firstIndex { $0.id == id } }
        let changedRows = IndexSet([previousRow, progressRowIndex].compactMap { $0 })
        guard !changedRows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: changedRows)
        }
        for row in changedRows { updateVisibleProgress(in: row) }
        if follow, let progressRowIndex {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.progressID == id, self.progressRowIndex == progressRowIndex else { return }
                self.table.scrollRowToVisible(progressRowIndex)
            }
        }
    }

    private func updateVisibleProgress(in row: Int) {
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BatchSidebarRow
        cell?.setProgress(row == progressRowIndex ? progressFraction : nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row == progressRowIndex ? BatchSidebarRow.progressHeight : BatchSidebarRow.normalHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        items.indices.contains(row) && items[row].canOpen
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard !updatingTable, items.indices.contains(row), items[row].canOpen, !items[row].isCurrent else { return }
        onOpen?(items[row].id)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: BatchSidebarRow.reuseIdentifier, owner: nil) as? BatchSidebarRow
            ?? BatchSidebarRow()
        cell.onThumbnailReady = { [weak self] url, image in self?.onThumbnailReady?(url, image) }
        cell.update(item, checked: checked.contains(item.id), busy: busy)
        cell.setProgress(row == progressRowIndex ? progressFraction : nil)
        cell.onToggle = { [weak self] id in self?.onToggle?(id) }
        return cell
    }

    @objc private func detectBatch() { onDetect?() }
    @objc private func stopDetection() { onStop?() }

    private func buildInterface() {
        let heading = StudioStyle.section("04", L10n.surface("照片列表"), size: 14)
        frameCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        frameCount.textColor = StudioStyle.amber
        selectAllButton.bezelStyle = .inline
        selectAllButton.controlSize = .small
        selectAllButton.font = .systemFont(ofSize: 11, weight: .medium)
        selectAllButton.target = self
        selectAllButton.action = #selector(toggleAll)
        selectAllButton.setAccessibilityLabel(L10n.surface("全选或全不选可导出的照片"))
        let header = NSStackView(views: [heading, NSView(), selectAllButton, frameCount])
        header.alignment = .firstBaseline
        header.spacing = 8

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("batch-photo"))
        column.minWidth = 120
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.rowHeight = BatchSidebarRow.normalHeight
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.setAccessibilityLabel(L10n.surface("载入的照片"))
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        activity.font = .systemFont(ofSize: 11)
        activity.textColor = StudioStyle.secondaryText
        activity.maximumNumberOfLines = 2
        activity.lineBreakMode = .byTruncatingTail
        activity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activity.setContentCompressionResistancePriority(.required, for: .vertical)

        detectButton.target = self
        detectButton.action = #selector(detectBatch)
        stopButton.target = self
        stopButton.action = #selector(stopDetection)

        let detectRow = NSStackView(views: [detectControl, stopControl, NSView()])
        detectRow.alignment = .centerY
        let separator = NSBox()
        separator.boxType = .separator
        let views = [header, scroll, separator, activity, detectRow] as [NSView]
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 9
        StudioStyle.embed(content, in: self, horizontal: 12, vertical: 14)
        for view in views { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }
}

private final class BatchSidebarRow: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("BatchSidebarRow")
    static let normalHeight: CGFloat = 45
    static let progressHeight: CGFloat = 61
    private static let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    private static let thumbnailCache: NSCache<NSUUID, Thumbnail> = {
        let cache = NSCache<NSUUID, Thumbnail>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 256
        return cache
    }()
    private static let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PURE Neg sidebar thumbnails"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private final class Thumbnail {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    var onToggle: ((UUID) -> Void)?
    var onThumbnailReady: ((URL, CGImage) -> Void)?
    private var id: UUID?
    private var thumbnailTask: Operation?
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let preview = BatchSidebarThumbnailView()
    private let filename = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = LaserProgressBar()
    private let percentage = NSTextField(labelWithString: "")
    private lazy var progressRow = NSStackView(views: [progress, percentage])

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        layer?.cornerRadius = 8
        filename.font = .systemFont(ofSize: 12, weight: .medium)
        filename.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 10)
        status.textColor = StudioStyle.secondaryText
        status.lineBreakMode = .byTruncatingTail
        for label in [filename, status] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        checkbox.target = self
        checkbox.action = #selector(toggle)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { checkbox.tintProminence = .none }
        #endif
        let labels = NSStackView(views: [filename, progressRow, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.detachesHiddenViews = true
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.contentTintColor = StudioStyle.secondaryText
        preview.wantsLayer = true
        preview.layer?.backgroundColor = StudioStyle.photoWell.cgColor
        preview.layer?.cornerRadius = 4
        preview.layer?.masksToBounds = true
        preview.setAccessibilityElement(false)
        percentage.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        percentage.textColor = StudioStyle.amber
        percentage.alignment = .right
        percentage.setAccessibilityElement(false)
        progressRow.alignment = .centerY
        progressRow.spacing = 7
        progressRow.isHidden = true
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        labels.translatesAutoresizingMaskIntoConstraints = false
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        addSubview(preview)
        addSubview(labels)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            checkbox.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 17),
            preview.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 44),
            preview.heightAnchor.constraint(equalToConstant: 33),
            labels.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 7),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            labels.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            filename.widthAnchor.constraint(equalTo: labels.widthAnchor),
            status.widthAnchor.constraint(equalTo: labels.widthAnchor),
            progressRow.widthAnchor.constraint(equalTo: labels.widthAnchor),
            percentage.widthAnchor.constraint(equalToConstant: 33)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        id = nil
    }

    deinit { thumbnailTask?.cancel() }

    func update(_ item: BatchReviewSidebar.Item, checked: Bool, busy: Bool) {
        if id != item.id { requestThumbnail(id: item.id, url: item.url) }
        id = item.id
        filename.stringValue = item.name
        filename.textColor = item.isCurrent ? StudioStyle.amber : StudioStyle.light
        filename.toolTip = item.name
        status.stringValue = String(format: "%02d", item.number) + " · " + item.status
        checkbox.state = checked ? .on : .off
        checkbox.isEnabled = item.canExport && !busy
        checkbox.setAccessibilityLabel(L10n.surface("勾选导出 \(item.name)"))
        checkbox.toolTip = item.canExport
            ? L10n.surface("勾选或取消导出。")
            : L10n.surface("预览就绪后可勾选导出。")
        layer?.backgroundColor = item.isCurrent ? StudioStyle.amber.withAlphaComponent(0.13).cgColor : nil
    }

    func setProgress(_ fraction: Double?) {
        progressRow.isHidden = fraction == nil
        guard let fraction else { return }
        progress.doubleValue = fraction
        percentage.stringValue = "\(Int((fraction * 100).rounded()))%"
    }

    private func requestThumbnail(id: UUID, url: URL) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        let key = id as NSUUID
        preview.image = Self.placeholder
        if let thumbnail = Self.thumbnailCache.object(forKey: key) {
            preview.image = thumbnail.image ?? Self.placeholder
            if let image = thumbnail.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                onThumbnailReady?(url, image)
            }
            return
        }

        let task = BlockOperation()
        task.addExecutionBlock { [weak self, weak task] in
            guard let task, !task.isCancelled else { return }
            let thumbnail = autoreleasepool { Self.readThumbnail(url) }
            guard !task.isCancelled else { return }
            DispatchQueue.main.async { [weak self, weak task] in
                guard let self, let task, !task.isCancelled, self.thumbnailTask === task else { return }
                self.thumbnailTask = nil
                let image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
                let cost = thumbnail.map { $0.bytesPerRow * $0.height } ?? 0
                Self.thumbnailCache.setObject(Thumbnail(image), forKey: key, cost: cost)
                self.preview.image = image ?? Self.placeholder
                if let thumbnail { self.onThumbnailReady?(url, thumbnail) }
            }
        }
        thumbnailTask = task
        Self.thumbnailQueue.addOperation(task)
    }

    private static func readThumbnail(_ url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 132,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @objc private func toggle() {
        guard let id else { return }
        onToggle?(id)
    }
}

private final class BatchSidebarThumbnailView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
