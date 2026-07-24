import AppKit
import UniformTypeIdentifiers

enum ApplicationPickerContentState: Equatable, Sendable {
    case loading
    case content
    case empty
    case failed
}

@MainActor
final class ApplicationPickerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let excludedBundleIdentifiers: Set<String>
    private let excludedBundleURLs: Set<URL>
    private let loader: ApplicationSelectionLoading
    private let onSelect: (URL) -> Void
    private let onClose: () -> Void
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let selectButton = NSButton(title: AppStrings.text(.pickerSelect), target: nil, action: nil)
    private let emptyField = NSTextField(labelWithString: AppStrings.text(.pickerEmpty))
    private let loadingIndicator = NSProgressIndicator()
    private let loadingField = NSTextField(labelWithString: AppStrings.text(.pickerLoading))
    private let loadingStack = NSStackView()
    private let failureField = NSTextField(labelWithString: AppStrings.text(.pickerLoadFailure))
    private let retryButton = NSButton(title: AppStrings.text(.pickerRetry), target: nil, action: nil)
    private let failureStack = NSStackView()
    private let cancelButton = NSButton(title: AppStrings.text(.pickerCancel), target: nil, action: nil)
    private let browseButton = NSButton(title: AppStrings.text(.pickerBrowseOther), target: nil, action: nil)
    private let iconCache = NSCache<NSString, NSImage>()
    private let iconLoader = ApplicationPickerIconLoader()
    private var loadingIconPaths = Set<String>()
    private lazy var placeholderIcon: NSImage = {
        let icon = NSImage(named: NSImage.applicationIconName) ?? NSImage(size: CGSize(width: 32, height: 32))
        icon.size = CGSize(width: 32, height: 32)
        return icon
    }()
    private(set) var allCandidates: [ApplicationSelectionCandidate] = []
    private(set) var filteredCandidates: [ApplicationSelectionCandidate] = []
    private(set) var contentState: ApplicationPickerContentState = .loading
    private var hasLoadedCandidates = false
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt = 0

    init(
        existingBindings: [AppHotkeyBinding],
        loader: ApplicationSelectionLoading? = nil,
        onSelect: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        excludedBundleIdentifiers = Set(existingBindings.compactMap(\.bundleIdentifier))
        excludedBundleURLs = Set(existingBindings.compactMap {
            $0.bundleURL?.standardizedFileURL
        })
        self.loader = loader ?? ApplicationSelectionCatalogLoader()
        self.onSelect = onSelect
        self.onClose = onClose

        let window = Self.makeWindow()
        super.init(window: window)
        finishInitialization(window: window)
    }

    init(
        excluding shortcuts: [FinderLaunchShortcut],
        loader: ApplicationSelectionLoading? = nil,
        onSelect: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        excludedBundleIdentifiers = Set(shortcuts.compactMap(\.bundleIdentifier))
        excludedBundleURLs = Set(shortcuts.compactMap {
            $0.bundleURL?.standardizedFileURL
        })
        self.loader = loader ?? ApplicationSelectionCatalogLoader()
        self.onSelect = onSelect
        self.onClose = onClose

        let window = Self.makeWindow()
        super.init(window: window)
        finishInitialization(window: window)
    }

    private static func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    private func finishInitialization(window: NSWindow) {
        window.title = AppStrings.text(.pickerTitle)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContentView()
        updateContentStateUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(over parentWindow: NSWindow) {
        guard let window else {
            return
        }
        reloadCandidates()
        parentWindow.beginSheet(window) { [weak self] _ in
            self?.invalidateCandidateLoading()
            self?.onClose()
        }
        window.makeFirstResponder(searchField)
    }

    func refreshLocalization() {
        window?.title = AppStrings.text(.pickerTitle)
        searchField.placeholderString = AppStrings.text(.pickerSearchPlaceholder)
        selectButton.title = AppStrings.text(.pickerSelect)
        cancelButton.title = AppStrings.text(.pickerCancel)
        browseButton.title = AppStrings.text(.pickerBrowseOther)
        emptyField.stringValue = AppStrings.text(.pickerEmpty)
        loadingField.stringValue = AppStrings.text(.pickerLoading)
        failureField.stringValue = AppStrings.text(.pickerLoadFailure)
        retryButton.title = AppStrings.text(.pickerRetry)
        tableView.reloadData()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else {
            return
        }
        invalidateCandidateLoading()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, sender.sheetParent != nil else {
            return true
        }
        closeSheet()
        return false
    }

    func dismiss() {
        closeSheet()
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = AppStrings.text(.pickerSearchPlaceholder)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.intercellSpacing = CGSize(width: 0, height: 4)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(confirmSelection(_:))
        tableView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView

        emptyField.alignment = .center
        emptyField.font = .systemFont(ofSize: 13)
        emptyField.textColor = .secondaryLabelColor
        emptyField.isHidden = true
        emptyField.translatesAutoresizingMaskIntoConstraints = false

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

        loadingField.font = .systemFont(ofSize: 13)
        loadingField.textColor = .secondaryLabelColor
        loadingField.translatesAutoresizingMaskIntoConstraints = false

        loadingStack.orientation = .horizontal
        loadingStack.alignment = .centerY
        loadingStack.spacing = 8
        loadingStack.addArrangedSubview(loadingIndicator)
        loadingStack.addArrangedSubview(loadingField)
        loadingStack.translatesAutoresizingMaskIntoConstraints = false

        failureField.alignment = .center
        failureField.font = .systemFont(ofSize: 13)
        failureField.textColor = .secondaryLabelColor
        failureField.maximumNumberOfLines = 2
        failureField.lineBreakMode = .byWordWrapping
        failureField.translatesAutoresizingMaskIntoConstraints = false

        retryButton.target = self
        retryButton.action = #selector(retryLoading(_:))
        retryButton.bezelStyle = .rounded
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        failureStack.orientation = .vertical
        failureStack.alignment = .centerX
        failureStack.spacing = 10
        failureStack.addArrangedSubview(failureField)
        failureStack.addArrangedSubview(retryButton)
        failureStack.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        browseButton.target = self
        browseButton.action = #selector(browseOther(_:))
        browseButton.bezelStyle = .rounded
        browseButton.translatesAutoresizingMaskIntoConstraints = false

        selectButton.target = self
        selectButton.action = #selector(confirmSelection(_:))
        selectButton.bezelStyle = .rounded
        selectButton.keyEquivalent = "\r"
        selectButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyField)
        root.addSubview(loadingStack)
        root.addSubview(failureStack)
        root.addSubview(browseButton)
        root.addSubview(cancelButton)
        root.addSubview(selectButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            scrollView.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -16),

            emptyField.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyField.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            loadingStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            failureStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            failureStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            failureField.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            selectButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            selectButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),

            cancelButton.trailingAnchor.constraint(equalTo: selectButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: selectButton.centerYAnchor),

            browseButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            browseButton.centerYAnchor.constraint(equalTo: selectButton.centerYAnchor)
        ])

        return root
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applyFilter()
    }

    @objc private func retryLoading(_ sender: Any?) {
        reloadCandidates()
    }

    @objc private func cancel(_ sender: Any?) {
        closeSheet()
    }

    @objc private func browseOther(_ sender: Any?) {
        guard let window else {
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle, .application]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK,
                  let url = panel.url
            else {
                return
            }

            Task { @MainActor [weak self] in
                self?.closeSheet()
                self?.onSelect(url)
            }
        }
    }

    @objc private func confirmSelection(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredCandidates.count else {
            return
        }

        let candidate = filteredCandidates[row]
        guard !isAlreadySelected(candidate) else {
            return
        }

        closeSheet()
        onSelect(candidate.bundleURL)
    }

    private func closeSheet() {
        invalidateCandidateLoading()
        guard let window else {
            return
        }
        window.sheetParent?.endSheet(window)
    }

    func reloadCandidates() {
        cancelActiveLoad()
        loadGeneration &+= 1
        let generation = loadGeneration
        hasLoadedCandidates = false
        allCandidates = []
        filteredCandidates = []
        tableView.reloadData()
        setContentState(.loading)

        let loader = loader
        loadTask = Task { @MainActor [weak self, loader] in
            do {
                try Task.checkCancellation()
                let candidates = try await loader.loadCandidates()
                self?.finishLoading(candidates, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.finishLoadingWithFailure(generation: generation)
            }
        }
    }

    func invalidateCandidateLoading() {
        loadGeneration &+= 1
        cancelActiveLoad()
    }

    private func cancelActiveLoad() {
        loadTask?.cancel()
        loadTask = nil
        loader.cancel()
    }

    private func finishLoading(
        _ candidates: [ApplicationSelectionCandidate],
        generation: UInt
    ) {
        guard generation == loadGeneration else {
            return
        }
        loadTask = nil
        hasLoadedCandidates = true
        allCandidates = candidates
        applyFilter()
    }

    private func finishLoadingWithFailure(generation: UInt) {
        guard generation == loadGeneration else {
            return
        }
        loadTask = nil
        hasLoadedCandidates = false
        allCandidates = []
        filteredCandidates = []
        tableView.reloadData()
        setContentState(.failed)
    }

    private func applyFilter() {
        guard hasLoadedCandidates else {
            return
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredCandidates = allCandidates
        } else {
            filteredCandidates = allCandidates.filter { candidate in
                candidate.displayName.lowercased().contains(query)
                    || candidate.detailText.lowercased().contains(query)
                    || candidate.bundleURL.path.lowercased().contains(query)
            }
        }

        tableView.reloadData()
        setContentState(filteredCandidates.isEmpty ? .empty : .content)
        selectFirstAvailableCandidate()
        updateSelectButton()
    }

    private func setContentState(_ state: ApplicationPickerContentState) {
        contentState = state
        updateContentStateUI()
    }

    private func updateContentStateUI() {
        let isLoading = contentState == .loading
        tableView.isHidden = contentState != .content
        emptyField.isHidden = contentState != .empty
        loadingStack.isHidden = !isLoading
        failureStack.isHidden = contentState != .failed
        if isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        updateSelectButton()
    }

    private func selectFirstAvailableCandidate() {
        guard let index = filteredCandidates.firstIndex(where: { !isAlreadySelected($0) }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    private func updateSelectButton() {
        let row = tableView.selectedRow
        selectButton.isEnabled = contentState == .content
            && row >= 0
            && row < filteredCandidates.count
            && !isAlreadySelected(filteredCandidates[row])
    }

    private func isAlreadySelected(_ candidate: ApplicationSelectionCandidate) -> Bool {
        if let bundleIdentifier = candidate.bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        return excludedBundleURLs.contains(candidate.bundleURL.standardizedFileURL)
    }

    private func cachedIcon(for candidate: ApplicationSelectionCandidate) -> NSImage? {
        iconCache.object(forKey: candidate.bundleURL.path as NSString)
    }

    private func loadIconIfNeeded(
        for candidate: ApplicationSelectionCandidate
    ) {
        let path = candidate.bundleURL.path
        guard loadingIconPaths.insert(path).inserted else {
            return
        }
        iconLoader.loadIcon(atPath: path) { [weak self] icon in
            guard let self else {
                return
            }
            self.loadingIconPaths.remove(path)
            self.iconCache.setObject(icon, forKey: path as NSString)
            let matchingRows = IndexSet(self.filteredCandidates.indices.filter { index in
                self.filteredCandidates[index].bundleURL.path == path
            })
            guard !matchingRows.isEmpty else {
                return
            }
            self.tableView.reloadData(
                forRowIndexes: matchingRows,
                columnIndexes: IndexSet(integersIn: 0..<self.tableView.numberOfColumns)
            )
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCandidates.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < filteredCandidates.count else {
            return false
        }
        return !isAlreadySelected(filteredCandidates[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < filteredCandidates.count else {
            return nil
        }

        let identifier = NSUserInterfaceItemIdentifier("ApplicationPickerCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ApplicationPickerCellView
            ?? ApplicationPickerCellView()
        cell.identifier = identifier
        let candidate = filteredCandidates[row]
        let cachedIcon = cachedIcon(for: candidate)
        cell.configure(
            candidate: candidate,
            icon: cachedIcon ?? placeholderIcon,
            isAlreadySelected: isAlreadySelected(candidate)
        )
        if cachedIcon == nil {
            loadIconIfNeeded(for: candidate)
        }
        return cell
    }
}

private final class ApplicationPickerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(candidate: ApplicationSelectionCandidate, icon: NSImage, isAlreadySelected: Bool) {
        iconView.image = icon
        titleField.stringValue = isAlreadySelected
            ? AppStrings.format(.pickerSelectedName, candidate.displayName)
            : candidate.displayName
        detailField.stringValue = candidate.detailText
        badgeField.stringValue = candidate.isSystemApplication
            ? AppStrings.text(.pickerSystemBadge)
            : AppStrings.text(.pickerApplicationBadge)
        alphaValue = isAlreadySelected ? 0.48 : 1
    }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingMiddle
        detailField.translatesAutoresizingMaskIntoConstraints = false

        badgeField.font = .systemFont(ofSize: 11, weight: .medium)
        badgeField.textColor = .secondaryLabelColor
        badgeField.alignment = .right
        badgeField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(detailField)
        addSubview(badgeField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            badgeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badgeField.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeField.widthAnchor.constraint(equalToConstant: 34),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: badgeField.leadingAnchor, constant: -10),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3)
        ])
    }
}
