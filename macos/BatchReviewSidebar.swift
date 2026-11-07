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
    var onExport: ((Set<UUID>) -> Void)?
    var onDetect: (() -> Void)?
    var onStop: (() -> Void)?
    var onThumbnailReady: ((URL, CGImage) -> Void)?

    private let table = NSTableView()
    private let frameCount = NSTextField(labelWithString: "")
    private let exportCount = NSTextField(labelWithString: "")
    private let activity = NSTextField(wrappingLabelWithString: "")
    private let detectButton = NSButton(title: L10n.surface("检测本批"), target: nil, action: nil)
    private let stopButton = NSButton(title: L10n.surface("停止检测"), target: nil, action: nil)
    private let checkedButton = NSButton(title: L10n.surface("导出所选"), target: nil, action: nil)
    private lazy var detectControl = StudioStyle.actionControl(detectButton)
    private lazy var stopControl = StudioStyle.actionControl(stopButton)

    private var items: [Item] = []
    private var checked = Set<UUID>()
    private var busy = false
    private var updatingTable = false
    private var detectionID: UUID?
    private var detectionRow: Int?
    private var detectionFraction: Double = 0

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
        exportCount.stringValue = checked.isEmpty
            ? L10n.surface("勾选已就绪的照片可批量导出。")
            : L10n.surface("已勾选 \(checked.count) 张")
        checkedButton.isEnabled = !busy && !checked.isEmpty

        guard needsReload else { return }
        detectionRow = detectionID.flatMap { id in items.firstIndex { $0.id == id } }
        updatingTable = true
        defer { updatingTable = false }
        table.reloadData()
        if let row = items.firstIndex(where: \.isCurrent) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if items[row].id != previousCurrent {
                let currentID = items[row].id
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.items.indices.contains(row), self.items[row].id == currentID,
                          self.items[row].isCurrent, self.detectionRow == nil else { return }
                    self.table.scrollRowToVisible(row)
                }
            }
        } else {
            table.deselectAll(nil)
        }
    }

    func setActivity(_ status: String, canDetect: Bool, canStop: Bool) {
        activity.stringValue = status
        activity.toolTip = status.isEmpty ? nil : status
        detectButton.isEnabled = canDetect
        stopButton.isEnabled = canStop
        detectControl.isHidden = canStop
        stopControl.isHidden = !canStop
    }

    func setDetectionProgress(id: UUID?, fraction: Double?, follow: Bool) {
        let reportedFraction = fraction ?? 0
        let value = id != nil && reportedFraction.isFinite ? min(max(reportedFraction, 0), 1) : 0
        if detectionID == id {
            guard detectionFraction != value else { return }
            detectionFraction = value
            if let detectionRow { updateVisibleProgress(in: detectionRow) }
            return
        }

        let previousRow = detectionRow
        detectionID = id
        detectionFraction = value
        detectionRow = id.flatMap { id in items.firstIndex { $0.id == id } }
        let changedRows = IndexSet([previousRow, detectionRow].compactMap { $0 })
        guard !changedRows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: changedRows)
        }
        for row in changedRows { updateVisibleProgress(in: row) }
        if follow, let detectionRow {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.detectionID == id, self.detectionRow == detectionRow else { return }
                self.table.scrollRowToVisible(detectionRow)
            }
        }
    }

    private func updateVisibleProgress(in row: Int) {
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BatchSidebarRow
        cell?.setDetectionProgress(row == detectionRow ? detectionFraction : nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row == detectionRow ? BatchSidebarRow.detectionHeight : BatchSidebarRow.normalHeight
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
        cell.setDetectionProgress(row == detectionRow ? detectionFraction : nil)
        cell.onToggle = { [weak self] id in self?.onToggle?(id) }
        return cell
    }

    @objc private func exportChecked() {
        guard !busy, !checked.isEmpty else { return }
        onExport?(checked)
    }

    @objc private func detectBatch() { onDetect?() }
    @objc private func stopDetection() { onStop?() }

    private func buildInterface() {
        let heading = StudioStyle.section("04", L10n.surface("照片列表"), size: 14)
        frameCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        frameCount.textColor = StudioStyle.amber
        let header = NSStackView(views: [heading, NSView(), frameCount])
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

        exportCount.font = .systemFont(ofSize: 11)
        exportCount.textColor = StudioStyle.secondaryText
        exportCount.lineBreakMode = .byTruncatingTail
        activity.font = .systemFont(ofSize: 11)
        activity.textColor = StudioStyle.secondaryText
        activity.maximumNumberOfLines = 2
        activity.lineBreakMode = .byTruncatingTail
        for label in [exportCount, activity] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        detectButton.target = self
        detectButton.action = #selector(detectBatch)
        stopButton.target = self
        stopButton.action = #selector(stopDetection)
        checkedButton.target = self
        checkedButton.action = #selector(exportChecked)
        checkedButton.toolTip = L10n.surface("一起导出已勾选的照片。")

        let detectRow = NSStackView(views: [detectControl, stopControl, NSView()])
        detectRow.alignment = .centerY
        let exports = StudioStyle.actionControl(checkedButton)
        let separator = NSBox()
        separator.boxType = .separator
        let views = [header, scroll, separator, activity, detectRow, exportCount, exports] as [NSView]
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
    static let detectionHeight: CGFloat = 61
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
        let labels = NSStackView(views: [filename, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
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
        addSubview(progressRow)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            checkbox.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 17),
            preview.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            preview.widthAnchor.constraint(equalToConstant: 44),
            preview.heightAnchor.constraint(equalToConstant: 33),
            labels.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 7),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            labels.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            filename.widthAnchor.constraint(equalTo: labels.widthAnchor),
            status.widthAnchor.constraint(equalTo: labels.widthAnchor),
            progressRow.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            progressRow.trailingAnchor.constraint(equalTo: labels.trailingAnchor),
            progressRow.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 3),
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

    func setDetectionProgress(_ fraction: Double?) {
        progressRow.isHidden = fraction == nil
        guard let fraction else { return }
        progress.doubleValue = fraction
        percentage.stringValue = "\(Int(fraction * 100))%"
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
