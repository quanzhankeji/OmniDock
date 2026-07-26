import AppKit

@MainActor
final class WindowPlacementSettingsView: NSView {
    var onEnableRequest: ((NSSwitch) -> Bool)?

    private let settings: SettingsStore
    private let registrationStatus: WindowPlacementRegistrationStatusStore
    private var selectedCommandID: UUID?

    private let masterSwitch = WindowPlacementFirstClickSwitch()
    private let greenButtonSwitch = WindowPlacementFirstClickSwitch()
    private let dragSwitch = WindowPlacementFirstClickSwitch()
    private let commandRows = NSStackView()
    private let editor = NSStackView()
    private let nameField = NSTextField()
    private let targetGrid = WindowPlacementGridView()
    private let shortcutRecorder = ShortcutRecorderView()
    private let activationGrid = WindowPlacementGridView()
    private let warningField = NSTextField(wrappingLabelWithString: "")
    private let registrationWarningField = NSTextField(wrappingLabelWithString: "")
    private let deleteButton = WindowPlacementFirstClickButton()

    init(
        settings: SettingsStore,
        registrationStatus: WindowPlacementRegistrationStatusStore
    ) {
        self.settings = settings
        self.registrationStatus = registrationStatus
        super.init(frame: .zero)
        build()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        let configuration = settings.windowPlacementConfiguration
        masterSwitch.state = configuration.isEnabled ? .on : .off
        greenButtonSwitch.state = configuration.showsGreenButtonPalette ? .on : .off
        dragSwitch.state = configuration.observesWindowDragging ? .on : .off
        greenButtonSwitch.isEnabled = configuration.isEnabled
        dragSwitch.isEnabled = configuration.isEnabled
        registrationWarningField.stringValue = registrationStatus.warning ?? ""
        registrationWarningField.isHidden = registrationStatus.warning == nil

        if selectedCommandID == nil
            || !configuration.commands.contains(where: { $0.id == selectedCommandID }) {
            selectedCommandID = configuration.commands.first?.id
        }
        rebuildCommandRows(configuration)
        refreshEditor(configuration)
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        masterSwitch.target = self
        masterSwitch.action = #selector(toggleMaster(_:))
        root.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.windowPlacementEnableTitle),
            detail: AppStrings.text(.windowPlacementEnableDetail),
            control: masterSwitch
        ))

        greenButtonSwitch.target = self
        greenButtonSwitch.action = #selector(toggleGreenButton(_:))
        root.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.windowPlacementGreenButtonTitle),
            detail: AppStrings.text(.windowPlacementGreenButtonDetail),
            control: greenButtonSwitch
        ))

        dragSwitch.target = self
        dragSwitch.action = #selector(toggleDrag(_:))
        root.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.windowPlacementDragTitle),
            detail: AppStrings.text(.windowPlacementDragDetail),
            control: dragSwitch
        ))

        registrationWarningField.font = .systemFont(ofSize: 12)
        registrationWarningField.textColor = .systemRed
        registrationWarningField.maximumNumberOfLines = 2
        registrationWarningField.isHidden = true
        root.addArrangedSubview(registrationWarningField)

        let split = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(split)

        let commandColumn = makeCommandColumn()
        let editorColumn = makeEditorColumn()
        commandColumn.translatesAutoresizingMaskIntoConstraints = false
        editorColumn.translatesAutoresizingMaskIntoConstraints = false
        split.addSubview(commandColumn)
        split.addSubview(editorColumn)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),

            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
            commandColumn.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            commandColumn.topAnchor.constraint(equalTo: split.topAnchor),
            commandColumn.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            commandColumn.widthAnchor.constraint(equalToConstant: 210),

            editorColumn.leadingAnchor.constraint(
                equalTo: commandColumn.trailingAnchor,
                constant: 18
            ),
            editorColumn.topAnchor.constraint(equalTo: split.topAnchor),
            editorColumn.bottomAnchor.constraint(lessThanOrEqualTo: split.bottomAnchor),
            editorColumn.widthAnchor.constraint(equalToConstant: 400),
            editorColumn.trailingAnchor.constraint(
                lessThanOrEqualTo: split.trailingAnchor
            )
        ])
    }

    private func makeCommandColumn() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 8

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        let title = NSTextField(labelWithString: AppStrings.text(.windowPlacementCommands))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let add = WindowPlacementFirstClickButton()
        add.title = AppStrings.text(.windowPlacementAdd)
        add.target = self
        add.action = #selector(addCommand(_:))
        add.bezelStyle = .rounded
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(add)
        column.addArrangedSubview(header)

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = TopAnchoredDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        commandRows.orientation = .vertical
        commandRows.alignment = .width
        commandRows.spacing = 0
        commandRows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(commandRows)
        scroll.documentView = document
        column.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 460),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            commandRows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            commandRows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            commandRows.topAnchor.constraint(equalTo: document.topAnchor),
            commandRows.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor)
        ])
        return column
    }

    private func makeEditorColumn() -> NSView {
        editor.orientation = .vertical
        editor.alignment = .width
        editor.spacing = 12

        nameField.placeholderString = AppStrings.text(.windowPlacementCustomDefaultName)
        nameField.target = self
        nameField.action = #selector(commitName(_:))
        editor.addArrangedSubview(nameField)

        let targetSection = makeSection(
            title: AppStrings.text(.windowPlacementTargetRegion),
            content: targetGrid
        )
        targetGrid.onChange = { [weak self] region in
            self?.updateSelectedCommand { command in
                guard command.behavior.supportsRegionEditing else {
                    return
                }
                command.targetRegion = region
            }
        }
        editor.addArrangedSubview(targetSection)

        shortcutRecorder.heightAnchor.constraint(equalToConstant: 36).isActive = true
        shortcutRecorder.onChange = { [weak self] shortcut in
            self?.updateShortcut(shortcut)
        }
        editor.addArrangedSubview(makeSection(
            title: AppStrings.text(.windowPlacementShortcut),
            content: shortcutRecorder
        ))

        activationGrid.allowsEmptySelection = true
        activationGrid.showsResizeHandles = true
        activationGrid.showsRemovalControl = true
        activationGrid.preventsOccupiedSelection = true
        activationGrid.onChange = { [weak self] region in
            self?.updateActivationRegion(region)
        }
        let activationContainer = NSStackView()
        activationContainer.orientation = .vertical
        activationContainer.alignment = .width
        activationContainer.spacing = 6
        activationContainer.addArrangedSubview(activationGrid)
        editor.addArrangedSubview(makeSection(
            title: AppStrings.text(.windowPlacementActivationRegion),
            content: activationContainer
        ))

        warningField.font = .systemFont(ofSize: 12)
        warningField.textColor = .systemRed
        warningField.maximumNumberOfLines = 2
        warningField.isHidden = true
        editor.addArrangedSubview(warningField)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(makeButton(
            title: AppStrings.text(.windowPlacementMoveUp),
            action: #selector(moveCommandUp(_:))
        ))
        actions.addArrangedSubview(makeButton(
            title: AppStrings.text(.windowPlacementMoveDown),
            action: #selector(moveCommandDown(_:))
        ))
        deleteButton.title = AppStrings.text(.windowPlacementRemove)
        deleteButton.target = self
        deleteButton.action = #selector(deleteCommand(_:))
        deleteButton.bezelStyle = .rounded
        actions.addArrangedSubview(deleteButton)
        actions.addArrangedSubview(NSView())
        editor.addArrangedSubview(actions)
        return editor
    }

    private func rebuildCommandRows(_ configuration: WindowPlacementConfiguration) {
        commandRows.removeAllArrangedSubviews()
        configuration.commands.forEach { command in
            let row = WindowPlacementCommandRowView(
                command: command,
                title: WindowPlacementNames.title(for: command),
                isSelected: command.id == selectedCommandID
            )
            row.onSelect = { [weak self] in
                self?.selectedCommandID = command.id
                self?.reload()
            }
            row.onToggle = { [weak self] enabled in
                self?.selectedCommandID = command.id
                self?.updateCommand(id: command.id) {
                    $0.isEnabled = enabled
                }
            }
            commandRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: commandRows.widthAnchor).isActive = true
        }
    }

    private func refreshEditor(_ configuration: WindowPlacementConfiguration) {
        guard let command = configuration.commands.first(where: {
            $0.id == selectedCommandID
        }) else {
            editor.isHidden = true
            return
        }
        editor.isHidden = false
        nameField.stringValue = WindowPlacementNames.title(for: command)
        nameField.isEditable = command.builtIn == nil
        targetGrid.region = command.targetRegion
        targetGrid.isEnabled = command.behavior.supportsRegionEditing
        shortcutRecorder.recordedShortcut = command.shortcut
        shortcutRecorder.isEnabled = command.isEnabled
        activationGrid.region = command.activationRegion
        activationGrid.occupiedRegions = configuration.reservedActivationRegions(
            excluding: command.id
        )
        activationGrid.isEnabled = command.isEnabled
            && command.behavior.supportsDragActivation
        deleteButton.isEnabled = command.builtIn == nil
    }

    private func updateShortcut(_ shortcut: RecordedShortcut?) {
        guard let selectedCommandID else {
            return
        }
        let configuration = settings.windowPlacementConfiguration
        if let shortcut,
           let reason = WindowPlacementShortcutPolicy.rejectionReason(
               for: shortcut,
               commandID: selectedCommandID,
               configuration: configuration,
               settings: settings
           ) {
            showWarning(reason)
            shortcutRecorder.recordedShortcut = configuration.commands.first {
                $0.id == selectedCommandID
            }?.shortcut
            return
        }
        hideWarning()
        var updatedConfiguration = configuration
        guard let index = updatedConfiguration.commands.firstIndex(where: {
            $0.id == selectedCommandID
        }) else {
            return
        }
        updatedConfiguration.commands[index].shortcut = shortcut
        settings.windowPlacementConfiguration = updatedConfiguration
        if let registrationWarning = registrationStatus.warning {
            settings.windowPlacementConfiguration = configuration
            shortcutRecorder.recordedShortcut = configuration.commands[index].shortcut
            showWarning(registrationWarning)
        }
    }

    private func updateActivationRegion(_ region: WindowPlacementRegion?) {
        guard let selectedCommandID else {
            return
        }
        var configuration = settings.windowPlacementConfiguration
        guard let index = configuration.commands.firstIndex(where: {
            $0.id == selectedCommandID
        }) else {
            return
        }
        let original = configuration.commands[index].activationRegion
        configuration.commands[index].activationRegion = region
        if configuration.activationConflict(
            for: selectedCommandID,
            region: region
        ) != nil {
            configuration.commands[index].activationRegion = original
            activationGrid.region = original
            showWarning(AppStrings.text(.windowPlacementActivationConflict))
            return
        }
        hideWarning()
        settings.windowPlacementConfiguration = configuration
    }

    private func updateSelectedCommand(
        _ update: (inout WindowPlacementCommand) -> Void
    ) {
        guard let selectedCommandID else {
            return
        }
        updateCommand(id: selectedCommandID, update)
    }

    private func updateCommand(
        id: UUID,
        _ update: (inout WindowPlacementCommand) -> Void
    ) {
        var configuration = settings.windowPlacementConfiguration
        guard let index = configuration.commands.firstIndex(where: {
            $0.id == id
        }) else {
            return
        }
        update(&configuration.commands[index])
        settings.windowPlacementConfiguration = configuration
    }

    private func showWarning(_ message: String) {
        warningField.stringValue = message
        warningField.isHidden = false
    }

    private func hideWarning() {
        warningField.stringValue = ""
        warningField.isHidden = true
    }

    @objc private func toggleMaster(_ sender: NSSwitch) {
        if sender.state == .on, onEnableRequest?(sender) == false {
            sender.state = .off
            return
        }
        settings.windowPlacementEnabled = sender.state == .on
    }

    @objc private func toggleGreenButton(_ sender: NSSwitch) {
        var configuration = settings.windowPlacementConfiguration
        configuration.showsGreenButtonPalette = sender.state == .on
        settings.windowPlacementConfiguration = configuration
    }

    @objc private func toggleDrag(_ sender: NSSwitch) {
        var configuration = settings.windowPlacementConfiguration
        configuration.observesWindowDragging = sender.state == .on
        settings.windowPlacementConfiguration = configuration
    }

    @objc private func addCommand(_ sender: NSButton) {
        var configuration = settings.windowPlacementConfiguration
        let command = WindowPlacementCommand.custom(
            name: AppStrings.text(.windowPlacementCustomDefaultName)
        )
        configuration.commands.append(command)
        selectedCommandID = command.id
        settings.windowPlacementConfiguration = configuration
    }

    @objc private func deleteCommand(_ sender: NSButton) {
        guard let selectedCommandID else {
            return
        }
        var configuration = settings.windowPlacementConfiguration
        guard configuration.commands.first(where: {
            $0.id == selectedCommandID
        })?.builtIn == nil else {
            return
        }
        configuration.commands.removeAll { $0.id == selectedCommandID }
        self.selectedCommandID = configuration.commands.first?.id
        settings.windowPlacementConfiguration = configuration
    }

    @objc private func moveCommandUp(_ sender: NSButton) {
        moveSelectedCommand(offset: -1)
    }

    @objc private func moveCommandDown(_ sender: NSButton) {
        moveSelectedCommand(offset: 1)
    }

    private func moveSelectedCommand(offset: Int) {
        guard let selectedCommandID else {
            return
        }
        var configuration = settings.windowPlacementConfiguration
        guard let index = configuration.commands.firstIndex(where: {
            $0.id == selectedCommandID
        }) else {
            return
        }
        let destination = index + offset
        guard configuration.commands.indices.contains(destination) else {
            return
        }
        configuration.commands.swapAt(index, destination)
        settings.windowPlacementConfiguration = configuration
    }

    @objc private func commitName(_ sender: NSTextField) {
        let trimmed = sender.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        updateSelectedCommand {
            guard $0.builtIn == nil else {
                return
            }
            $0.customName = trimmed.isEmpty
                ? AppStrings.text(.windowPlacementCustomDefaultName)
                : trimmed
        }
    }

    private func makeSettingRow(
        title: String,
        detail: String,
        control: NSView
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        detailField.maximumNumberOfLines = 2
        labels.addArrangedSubview(titleField)
        labels.addArrangedSubview(detailField)
        row.addArrangedSubview(labels)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(control)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func makeSection(title: String, content: NSView) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .width
        section.spacing = 6
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        section.addArrangedSubview(titleField)
        section.addArrangedSubview(content)
        return section
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = WindowPlacementFirstClickButton()
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        return button
    }
}

final class WindowPlacementCommandRowView: NSView {
    var onSelect: (() -> Void)?
    var onToggle: ((Bool) -> Void)?

    private let selectionButton = WindowPlacementFirstClickButton()
    private let enabledSwitch = WindowPlacementFirstClickSwitch()

    init(command: WindowPlacementCommand, title: String, isSelected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor

        selectionButton.title = title
        selectionButton.image = WindowPlacementGlyph.image(for: command)
        selectionButton.imagePosition = .imageLeading
        selectionButton.alignment = .left
        selectionButton.isBordered = false
        selectionButton.target = self
        selectionButton.action = #selector(select(_:))
        selectionButton.translatesAutoresizingMaskIntoConstraints = false

        enabledSwitch.state = command.isEnabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggle(_:))
        enabledSwitch.controlSize = .small
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false

        addSubview(selectionButton)
        addSubview(enabledSwitch)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            selectionButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            selectionButton.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            selectionButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            selectionButton.trailingAnchor.constraint(
                equalTo: enabledSwitch.leadingAnchor,
                constant: -2
            ),
            enabledSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            enabledSwitch.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func select(_ sender: NSButton) {
        onSelect?()
    }

    @objc private func toggle(_ sender: NSSwitch) {
        onToggle?(sender.state == .on)
    }
}

private final class WindowPlacementFirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class WindowPlacementFirstClickSwitch: NSSwitch {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class WindowPlacementGridView: NSControl {
    var region: WindowPlacementRegion? {
        didSet {
            updateRemovalControl()
            needsDisplay = true
        }
    }
    var occupiedRegions: [WindowPlacementRegion] = [] {
        didSet {
            needsDisplay = true
        }
    }
    var allowsEmptySelection = false
    var showsResizeHandles = false {
        didSet {
            needsDisplay = true
        }
    }
    var showsRemovalControl = false {
        didSet {
            _ = removalButton
            updateRemovalControl()
        }
    }
    var preventsOccupiedSelection = false
    var onChange: ((WindowPlacementRegion?) -> Void)?

    private enum DragMode {
        case selection(
            anchor: (column: Int, row: Int),
            original: WindowPlacementRegion?
        )
        case resize(
            edges: WindowPlacementResizeEdges,
            original: WindowPlacementRegion
        )

        var originalRegion: WindowPlacementRegion? {
            switch self {
            case let .selection(_, original):
                return original
            case let .resize(_, original):
                return original
            }
        }
    }

    private var dragMode: DragMode?
    private var trackingArea: NSTrackingArea?
    private var pointerLocation: CGPoint?
    private let resizeHitTolerance: CGFloat = 7
    private lazy var removalButton: WindowPlacementFirstClickButton = {
        let button = WindowPlacementFirstClickButton()
        button.title = ""
        button.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: AppStrings.text(
                .windowPlacementNoActivationRegion
            )
        )
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.isBordered = false
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        button.layer?.cornerRadius = 10
        button.toolTip = AppStrings.text(.windowPlacementNoActivationRegion)
        button.target = self
        button.action = #selector(removeSelectedRegion(_:))
        button.isHidden = true
        addSubview(button)
        return button
    }()

    override var intrinsicContentSize: NSSize {
        NSSize(width: 400, height: 200)
    }

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let cellWidth = bounds.width / CGFloat(WindowPlacementRegion.columns)
        let cellHeight = bounds.height / CGFloat(WindowPlacementRegion.rows)
        for row in 0..<WindowPlacementRegion.rows {
            for column in 0..<WindowPlacementRegion.columns {
                let cellRegion = WindowPlacementRegion(
                    column: column,
                    row: row,
                    columnSpan: 1,
                    rowSpan: 1
                )
                let rect = CGRect(
                    x: CGFloat(column) * cellWidth + 1,
                    y: CGFloat(row) * cellHeight + 1,
                    width: max(cellWidth - 2, 1),
                    height: max(cellHeight - 2, 1)
                )
                let selected = region.map { selectedRegion in
                    selectedRegion.intersects(cellRegion)
                } ?? false
                let occupied = occupiedRegions.contains {
                    $0.intersects(cellRegion)
                }
                cellColor(selected: selected, occupied: occupied).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        }

        drawSelectionFrame()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        if let region,
           let edges = resizeEdges(at: point) {
            dragMode = .resize(edges: edges, original: region)
            updateRemovalControl()
            return
        }

        let position = gridPosition(for: point)
        let candidate = WindowPlacementRegion.gridSelection(
            from: position,
            to: position
        )
        guard canSelect(candidate) else {
            NSCursor.operationNotAllowed.set()
            return
        }
        dragMode = .selection(anchor: position, original: region)
        region = candidate
        updateRemovalControl()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let dragMode else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        updateRemovalControl()
        let position = gridPosition(for: point)
        let candidate: WindowPlacementRegion
        switch dragMode {
        case let .selection(anchor, _):
            candidate = WindowPlacementRegion.gridSelection(
                from: anchor,
                to: position
            )
        case let .resize(edges, original):
            candidate = original.gridBounds.resized(
                edges: edges,
                to: position
            )
        }
        guard canSelect(candidate) else {
            NSCursor.operationNotAllowed.set()
            return
        }
        region = candidate
        updateCursor(
            at: convert(event.locationInWindow, from: nil)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, let dragMode else {
            return
        }
        self.dragMode = nil
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        updateCursor(at: point)
        updateRemovalControl()
        if dragMode.originalRegion != region {
            onChange?(region)
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseMoved,
            .mouseEnteredAndExited
        ]
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        updateCursor(at: point)
        updateRemovalControl()
    }

    override func mouseExited(with event: NSEvent) {
        pointerLocation = nil
        updateRemovalControl()
        NSCursor.arrow.set()
    }

    override func layout() {
        super.layout()
        positionRemovalControl()
    }

    private func gridPosition(for point: CGPoint) -> (column: Int, row: Int) {
        let column = Int(
            floor(point.x / max(bounds.width, 1) * CGFloat(WindowPlacementRegion.columns))
        )
        let row = Int(
            floor(point.y / max(bounds.height, 1) * CGFloat(WindowPlacementRegion.rows))
        )
        return (
            min(max(column, 0), WindowPlacementRegion.columns - 1),
            min(max(row, 0), WindowPlacementRegion.rows - 1)
        )
    }

    func canSelect(_ candidate: WindowPlacementRegion) -> Bool {
        !preventsOccupiedSelection
            || !occupiedRegions.contains(where: { $0.intersects(candidate) })
    }

    private func cellColor(selected: Bool, occupied: Bool) -> NSColor {
        if selected {
            return .controlAccentColor
        }
        if occupied {
            return NSColor.secondaryLabelColor.withAlphaComponent(0.62)
        }
        return .quaternaryLabelColor
    }

    private func drawSelectionFrame() {
        guard showsResizeHandles,
              isEnabled,
              let frame = selectedFrame else {
            return
        }
        let outline = frame.insetBy(dx: 1, dy: 1)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: outline)
        path.lineWidth = 2
        path.stroke()

        for point in handlePoints(for: outline) {
            let handle = CGRect(
                x: point.x - 3,
                y: point.y - 3,
                width: 6,
                height: 6
            )
            NSColor.controlBackgroundColor.setFill()
            NSColor.controlAccentColor.setStroke()
            let handlePath = NSBezierPath(ovalIn: handle)
            handlePath.lineWidth = 1.5
            handlePath.fill()
            handlePath.stroke()
        }
    }

    private var selectedFrame: CGRect? {
        guard let region, !region.isEmpty else {
            return nil
        }
        return region.frame(in: bounds)
    }

    private func resizeEdges(at point: CGPoint) -> WindowPlacementResizeEdges? {
        guard showsResizeHandles,
              let frame = selectedFrame,
              frame.insetBy(
                  dx: -resizeHitTolerance,
                  dy: -resizeHitTolerance
              ).contains(point) else {
            return nil
        }

        var edges: WindowPlacementResizeEdges = []
        let horizontalDistances = [
            (WindowPlacementResizeEdges.left, abs(point.x - frame.minX)),
            (WindowPlacementResizeEdges.right, abs(point.x - frame.maxX))
        ]
        if let nearest = horizontalDistances.min(by: { $0.1 < $1.1 }),
           nearest.1 <= resizeHitTolerance {
            edges.insert(nearest.0)
        }
        let verticalDistances = [
            (WindowPlacementResizeEdges.top, abs(point.y - frame.minY)),
            (WindowPlacementResizeEdges.bottom, abs(point.y - frame.maxY))
        ]
        if let nearest = verticalDistances.min(by: { $0.1 < $1.1 }),
           nearest.1 <= resizeHitTolerance {
            edges.insert(nearest.0)
        }
        return edges.isEmpty ? nil : edges
    }

    private func handlePoints(for frame: CGRect) -> [CGPoint] {
        [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.midX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.midY),
            CGPoint(x: frame.maxX, y: frame.midY),
            CGPoint(x: frame.minX, y: frame.maxY),
            CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.maxX, y: frame.maxY)
        ]
    }

    private func updateCursor(at point: CGPoint) {
        guard let edges = resizeEdges(at: point) else {
            let position = gridPosition(for: point)
            let hoveredCell = WindowPlacementRegion.gridSelection(
                from: position,
                to: position
            )
            if !canSelect(hoveredCell) {
                NSCursor.operationNotAllowed.set()
                return
            }
            NSCursor.crosshair.set()
            return
        }
        let isHorizontal = edges.contains(.left) || edges.contains(.right)
        let isVertical = edges.contains(.top) || edges.contains(.bottom)
        switch (isHorizontal, isVertical) {
        case (true, true):
            NSCursor.crosshair.set()
        case (true, false):
            WindowPlacementGridCursor.horizontal.set()
        case (false, true):
            WindowPlacementGridCursor.vertical.set()
        case (false, false):
            NSCursor.crosshair.set()
        }
    }

    private func updateRemovalControl() {
        guard showsRemovalControl,
              isEnabled,
              dragMode == nil,
              let pointerLocation,
              selectedFrame?.contains(pointerLocation) == true
        else {
            removalButton.isHidden = true
            return
        }
        positionRemovalControl()
        removalButton.isHidden = false
    }

    private func positionRemovalControl() {
        guard showsRemovalControl, let selectedFrame else {
            return
        }
        let size: CGFloat = 20
        removalButton.frame = CGRect(
            x: min(
                max(selectedFrame.maxX - size - 3, bounds.minX + 2),
                bounds.maxX - size - 2
            ),
            y: min(
                max(selectedFrame.minY + 3, bounds.minY + 2),
                bounds.maxY - size - 2
            ),
            width: size,
            height: size
        )
    }

    @objc private func removeSelectedRegion(_ sender: NSButton) {
        guard isEnabled, region != nil else {
            return
        }
        region = nil
        pointerLocation = nil
        onChange?(nil)
    }
}

private enum WindowPlacementGridCursor {
    static let horizontal = makeCursor(
        symbolName: "arrow.left.and.right"
    )
    static let vertical = makeCursor(
        symbolName: "arrow.up.and.down"
    )

    private static func makeCursor(symbolName: String) -> NSCursor {
        guard let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) else {
            return .crosshair
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: size.width / 2, y: size.height / 2)
        )
    }
}
