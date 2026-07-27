import AppKit
import ImageIO

@MainActor
final class ClipboardHistoryListController: NSObject {
    let view: NSView

    var onCopy: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onHoverChanged: ((UUID, Bool) -> Void)?

    private(set) var createdRowViewCount = 0
    var recordCount: Int {
        records.count
    }

    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let thumbnailLoader = ClipboardHistoryThumbnailLoader()
    private var records: [ClipboardHistoryRecord] = []

    override init() {
        let container = NSView()
        let scrollView = NSScrollView()
        view = container
        super.init()

        container.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.rowHeight = 48
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor,
                constant: 20
            ),
            emptyLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -20
            )
        ])
        refreshLocalization()
        updateEmptyState()
    }

    func apply(records: [ClipboardHistoryRecord]) {
        self.records = records
        tableView.reloadData()
        updateEmptyState()
    }

    func refreshLocalization() {
        emptyLabel.stringValue = AppStrings.text(.clipboardEmpty)
        for row in tableView.rows(in: tableView.visibleRect).integerIndexes {
            guard let record = record(at: row),
                  let view = tableView.view(
                      atColumn: 0,
                      row: row,
                      makeIfNecessary: false
                  ) as? ClipboardArchiveSettingsRowView
            else {
                continue
            }
            configure(view, with: record)
        }
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !records.isEmpty
        tableView.isHidden = records.isEmpty
    }

    private func record(at row: Int) -> ClipboardHistoryRecord? {
        guard records.indices.contains(row) else {
            return nil
        }
        return records[row]
    }

    private func configure(
        _ rowView: ClipboardArchiveSettingsRowView,
        with record: ClipboardHistoryRecord
    ) {
        let thumbnail = thumbnailLoader.cachedImage(for: record.id)
        rowView.configure(record: record, thumbnail: thumbnail)
        rowView.onCopy = { [weak self] in
            self?.onCopy?(record.id)
        }
        rowView.onDelete = { [weak self] in
            self?.onDelete?(record.id)
        }
        rowView.onHoverChanged = { [weak self] hovering in
            self?.onHoverChanged?(record.id, hovering)
        }

        guard thumbnail == nil, let data = record.thumbnailData else {
            return
        }
        thumbnailLoader.load(recordID: record.id, data: data) { [weak self] image in
            guard let self,
                  let row = self.records.firstIndex(where: { $0.id == record.id }),
                  let currentRecord = self.record(at: row),
                  let rowView = self.tableView.view(
                      atColumn: 0,
                      row: row,
                      makeIfNecessary: false
                  ) as? ClipboardArchiveSettingsRowView,
                  rowView.recordID == record.id
            else {
                return
            }
            rowView.configure(record: currentRecord, thumbnail: image)
        }
    }

    private static let columnIdentifier = NSUserInterfaceItemIdentifier(
        "ClipboardHistorySettingsColumn"
    )
    private static let rowIdentifier = NSUserInterfaceItemIdentifier(
        "ClipboardHistorySettingsRow"
    )
}

extension ClipboardHistoryListController: NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated {
            records.count
        }
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        MainActor.assumeIsolated {
            guard let record = record(at: row) else {
                return nil
            }
            let rowView: ClipboardArchiveSettingsRowView
            if let reused = tableView.makeView(
                withIdentifier: Self.rowIdentifier,
                owner: self
            ) as? ClipboardArchiveSettingsRowView {
                rowView = reused
            } else {
                rowView = ClipboardArchiveSettingsRowView()
                rowView.identifier = Self.rowIdentifier
                createdRowViewCount += 1
            }
            configure(rowView, with: record)
            return rowView
        }
    }
}

@MainActor
private final class ClipboardHistoryThumbnailLoader {
    private let cache = NSCache<NSUUID, NSImage>()
    private let decodeQueue = DispatchQueue(
        label: "com.quanzhankeji.OmniDock.clipboard-thumbnail-decode",
        qos: .userInitiated
    )
    private var loadingIDs: Set<UUID> = []
    private var failedIDs: Set<UUID> = []

    init() {
        cache.totalCostLimit = 32 * 1_024 * 1_024
        cache.countLimit = 128
    }

    @MainActor
    func cachedImage(for recordID: UUID) -> NSImage? {
        cache.object(forKey: recordID as NSUUID)
    }

    @MainActor
    func load(
        recordID: UUID,
        data: Data,
        completion: @escaping @MainActor @Sendable (NSImage?) -> Void
    ) {
        if let cached = cache.object(forKey: recordID as NSUUID) {
            completion(cached)
            return
        }
        guard !loadingIDs.contains(recordID), !failedIDs.contains(recordID) else {
            return
        }
        loadingIDs.insert(recordID)

        decodeQueue.async { [weak self] in
            let decoded = Self.decode(data)
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.loadingIDs.remove(recordID)
                guard let decoded else {
                    self.failedIDs.insert(recordID)
                    completion(nil)
                    return
                }
                let image = NSImage(cgImage: decoded.image, size: decoded.size)
                self.cache.setObject(
                    image,
                    forKey: recordID as NSUUID,
                    cost: decoded.cost
                )
                completion(image)
            }
        }
    }

    nonisolated private static func decode(_ data: Data) -> DecodedThumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 120
                  ] as CFDictionary
              )
        else {
            return nil
        }
        return DecodedThumbnail(
            image: image,
            size: NSSize(width: image.width, height: image.height),
            cost: image.bytesPerRow * image.height
        )
    }

    private struct DecodedThumbnail {
        let image: CGImage
        let size: NSSize
        let cost: Int
    }
}

private extension NSRange {
    var integerIndexes: [Int] {
        guard location != NSNotFound, length > 0 else {
            return []
        }
        return Array(location..<(location + length))
    }
}
