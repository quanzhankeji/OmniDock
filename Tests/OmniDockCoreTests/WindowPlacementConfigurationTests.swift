import XCTest
import AppKit
@testable import OmniDockCore

final class WindowPlacementConfigurationTests: XCTestCase {
    func testSettingsWindowLayoutRejectsRestoredOversizedFrame() {
        XCTAssertEqual(
            SettingsWindowLayoutMetrics.normalizedContentSize(
                NSSize(width: 2_059, height: 732)
            ),
            NSSize(width: 960, height: 732)
        )
        XCTAssertEqual(
            SettingsWindowLayoutMetrics.normalizedContentSize(
                NSSize(width: 700, height: 500)
            ),
            NSSize(width: 760, height: 560)
        )
        XCTAssertEqual(
            SettingsWindowLayoutMetrics.normalizedContentSize(
                NSSize(width: 840, height: 680)
            ),
            NSSize(width: 840, height: 680)
        )
    }

    @MainActor
    func testWindowPlacementEditorStaysInsideCompactSettingsWidth() {
        let defaultsName = "OmniDockWindowPlacementLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let view = WindowPlacementSettingsView(
            settings: SettingsStore(
                defaults: defaults,
                livePreviewLimitProvider: { 8 }
            ),
            registrationStatus: WindowPlacementRegistrationStatusStore()
        )
        view.frame = CGRect(x: 0, y: 0, width: 732, height: 760)
        view.layoutSubtreeIfNeeded()

        let grids = descendants(of: view, matching: WindowPlacementGridView.self)
        XCTAssertEqual(grids.count, 2)
        for grid in grids {
            let frame = grid.convert(grid.bounds, to: view)
            XCTAssertGreaterThanOrEqual(frame.minX, view.bounds.minX)
            XCTAssertLessThanOrEqual(frame.maxX, view.bounds.maxX)
            XCTAssertGreaterThanOrEqual(frame.width, 390)
            XCTAssertTrue(view.hitTest(CGPoint(x: frame.midX, y: frame.midY)) === grid)
        }
    }

    @MainActor
    func testWindowPlacementCommandRowHasNoDeadSelectionArea() throws {
        let command = try XCTUnwrap(WindowPlacementConfiguration.default.commands.first)
        let row = WindowPlacementCommandRowView(
            command: command,
            title: "Left",
            isSelected: false
        )
        row.frame = CGRect(x: 0, y: 0, width: 210, height: 34)
        row.layoutSubtreeIfNeeded()

        var selectionCount = 0
        row.onSelect = {
            selectionCount += 1
        }
        XCTAssertTrue(row.acceptsFirstMouse(for: nil))

        for point in [
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 33),
            CGPoint(x: 105, y: 1),
            CGPoint(x: 105, y: 33)
        ] {
            XCTAssertNotNil(row.hitTest(point))
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            row.mouseDown(with: event)
        }
        XCTAssertEqual(selectionCount, 4)
    }

    @MainActor
    func testPresentedSettingsWindowKeepsCompactUserAdjustedSizeAcrossTabs() throws {
        _ = NSApplication.shared
        let defaultsName = "OmniDockSettingsWindowLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let settings = SettingsStore(
            defaults: defaults,
            livePreviewLimitProvider: { 8 }
        )
        let permissionService = PermissionService()
        let windowControlService = WindowControlService()
        let previewService = ScreenCapturePreviewService()
        let previewPanelController = PreviewPanelController(
            windowControlService: windowControlService
        )
        let coordinator = DockInteractionCoordinator(
            settings: settings,
            permissionService: permissionService,
            dockHitTester: DockHitTester(permissionService: permissionService),
            windowControlService: windowControlService,
            previewService: previewService,
            previewPanelController: previewPanelController
        )
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = SettingsWindowController(
            settings: settings,
            permissionService: permissionService,
            coordinator: coordinator,
            hotkeyRegistrationStatus: AppHotkeyRegistrationStatusStore(),
            windowCycleRegistrationStatus: WindowCycleRegistrationStatusStore(),
            clipboardHistoryRegistrationStatus: ClipboardHistoryRegistrationStatus(),
            windowPlacementRegistrationStatus: WindowPlacementRegistrationStatusStore(),
            presentationCoordinator: ApplicationPresentationCoordinator(
                setActivationPolicy: { _ in true },
                activateApplication: {},
                scheduleDeferred: { $0() }
            ),
            onPermissionGateRequired: { _ in },
            onOpenPermissionOnboarding: {}
        )

        controller.show(tab: .windowPlacement)
        let window = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
                && $0.title == "OmniDock"
        })
        defer {
            window.close()
        }
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(
            window.contentView?.bounds.size,
            SettingsWindowLayoutMetrics.preferredContentSize
        )

        window.setContentSize(SettingsWindowLayoutMetrics.minimumContentSize)
        for tab in SettingsTab.allCases {
            controller.show(tab: tab)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                window.contentView?.bounds.size,
                SettingsWindowLayoutMetrics.minimumContentSize,
                "Minimum settings size changed for \(tab)"
            )
        }

        let adjustedSize = NSSize(width: 900, height: 760)
        window.setContentSize(adjustedSize)
        for tab in SettingsTab.allCases {
            controller.show(tab: tab)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                window.contentView?.bounds.size,
                adjustedSize,
                "User-adjusted settings size changed for \(tab)"
            )
        }

        for tab in [SettingsTab.hotkeys, .clipboardHistory] {
            window.setContentSize(SettingsWindowLayoutMetrics.minimumContentSize)
            controller.show(tab: tab)
            window.contentView?.layoutSubtreeIfNeeded()
            let compactHeight = try XCTUnwrap(
                descendants(of: window.contentView!, matching: NSScrollView.self)
                    .map(\.frame.height)
                    .max()
            )

            window.setContentSize(adjustedSize)
            window.contentView?.layoutSubtreeIfNeeded()
            let expandedHeight = try XCTUnwrap(
                descendants(of: window.contentView!, matching: NSScrollView.self)
                    .map(\.frame.height)
                    .max()
            )

            XCTAssertGreaterThan(
                expandedHeight,
                compactHeight + 150,
                "\(tab) list did not expand with the settings window"
            )
        }
    }

    @MainActor
    func testHotkeyRowsKeepCompactHeightInsideExpandedList() {
        let binding = AppHotkeyBinding(
            appName: "Example",
            bundleURLString: "file:///Applications/Example.app",
            bundleIdentifier: "com.example.app"
        )
        let standardRow = AppHotkeyRowView(binding: binding, warning: nil)
        let warningRow = AppHotkeyRowView(binding: binding, warning: "Warning")

        XCTAssertEqual(
            standardRow.constraints.first(where: {
                $0.firstAttribute == .height && $0.relation == .equal
            })?.constant,
            AppHotkeyRowView.standardHeight
        )
        XCTAssertEqual(
            warningRow.constraints.first(where: {
                $0.firstAttribute == .height && $0.relation == .equal
            })?.constant,
            AppHotkeyRowView.warningHeight
        )
    }

    func testPaletteGeometryPlacesArrowTipAtGreenButtonLowerEdge() {
        let anchor = CGRect(x: 600, y: 850, width: 16, height: 16)
        let panelSize = CGSize(width: 240, height: 400)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)

        let origin = WindowPlacementPaletteGeometry.origin(
            panelSize: panelSize,
            anchor: anchor,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.x, 578)
        XCTAssertEqual(origin.y, 451)
        XCTAssertEqual(
            origin.y + panelSize.height,
            anchor.minY + WindowPlacementPaletteGeometry.anchorOverlap
        )
        XCTAssertEqual(
            WindowPlacementPaletteGeometry.arrowCenterX(
                anchor: anchor,
                panelOrigin: origin,
                panelWidth: panelSize.width
            ),
            WindowPlacementPaletteGeometry.preferredArrowCenterX
        )
    }

    private func descendants<T: NSView>(
        of view: NSView,
        matching type: T.Type
    ) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? descendants(of: child, matching: type)
        }
    }


    func testPaletteGeometryKeepsBubbleInsideOffsetDisplay() {
        let anchor = CGRect(x: -1_435, y: 80, width: 16, height: 16)
        let panelSize = CGSize(width: 240, height: 400)
        let visibleFrame = CGRect(x: -1_440, y: -200, width: 1_440, height: 900)

        let origin = WindowPlacementPaletteGeometry.origin(
            panelSize: panelSize,
            anchor: anchor,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.x, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(origin.y, visibleFrame.minY)
        XCTAssertLessThanOrEqual(
            origin.y + panelSize.height,
            visibleFrame.maxY
        )
        XCTAssertEqual(
            WindowPlacementPaletteGeometry.arrowCenterX(
                anchor: anchor,
                panelOrigin: origin,
                panelWidth: panelSize.width
            ),
            WindowPlacementPaletteGeometry.arrowHorizontalInset
        )
    }

    func testBubbleShapeUsesOneContinuousOutline() {
        let path = WindowPlacementBubbleShape.path(
            in: CGRect(x: 0, y: 0, width: 260, height: 420),
            arrowCenterX: 100
        )
        var moveCount = 0
        var closeCount = 0

        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint:
                moveCount += 1
            case .closeSubpath:
                closeCount += 1
            default:
                break
            }
        }

        XCTAssertEqual(moveCount, 1)
        XCTAssertEqual(closeCount, 1)
    }

    func testBuiltInRegionsUseExpectedFractions() {
        let frame = CGRect(x: -1440, y: 30, width: 1440, height: 900)

        XCTAssertEqual(
            BuiltInWindowPlacement.leftHalf.defaultRegion?.frame(in: frame),
            CGRect(x: -1440, y: 30, width: 720, height: 900)
        )
        XCTAssertEqual(
            BuiltInWindowPlacement.centerThird.defaultRegion?.frame(in: frame),
            CGRect(x: -960, y: 30, width: 480, height: 900)
        )
        XCTAssertEqual(
            BuiltInWindowPlacement.rightTwoThirds.defaultRegion?.frame(in: frame),
            CGRect(x: -960, y: 30, width: 960, height: 900)
        )
    }

    func testGridSelectionNormalizesReverseDrag() {
        let region = WindowPlacementRegion.gridSelection(
            from: (column: 11, row: 8),
            to: (column: 4, row: 2)
        )

        XCTAssertEqual(region, WindowPlacementRegion(column: 4, row: 2, columnSpan: 8, rowSpan: 7))
    }

    func testGridBoundsResizeSelectedEdgesAndCorners() {
        let original = WindowPlacementRegion(
            column: 4,
            row: 2,
            columnSpan: 8,
            rowSpan: 6
        )

        XCTAssertEqual(
            original.gridBounds.resized(
                edges: [.left, .bottom],
                to: (column: 2, row: 9)
            ),
            WindowPlacementRegion(
                column: 2,
                row: 2,
                columnSpan: 10,
                rowSpan: 8
            )
        )
        XCTAssertEqual(
            original.gridBounds.resized(
                edges: [.right, .top],
                to: (column: 3, row: 9)
            ),
            WindowPlacementRegion(
                column: 4,
                row: 7,
                columnSpan: 1,
                rowSpan: 1
            )
        )
    }

    func testActivationConflictRejectsOverlapButAllowsTouchingEdges() {
        var configuration = WindowPlacementConfiguration(commands: [])
        let first = WindowPlacementCommand(
            behavior: .proportional,
            targetRegion: .full,
            activationRegion: .init(column: 0, row: 0, columnSpan: 2, rowSpan: 2)
        )
        let second = WindowPlacementCommand(
            behavior: .proportional,
            targetRegion: .full,
            activationRegion: .init(column: 2, row: 0, columnSpan: 2, rowSpan: 2)
        )
        configuration.commands = [first, second]

        XCTAssertNil(configuration.activationConflict(for: second.id, region: second.activationRegion))
        XCTAssertEqual(
            configuration.activationConflict(
                for: second.id,
                region: .init(column: 1, row: 1, columnSpan: 2, rowSpan: 2)
            ),
            first.id
        )
    }

    func testDisabledCommandsKeepTheirPlannedActivationRegionsReserved() {
        let reserved = WindowPlacementCommand(
            behavior: .proportional,
            activationRegion: .init(
                column: 0,
                row: 0,
                columnSpan: 2,
                rowSpan: 2
            ),
            isEnabled: false
        )
        let selected = WindowPlacementCommand(
            behavior: .proportional,
            activationRegion: .init(
                column: 4,
                row: 0,
                columnSpan: 2,
                rowSpan: 2
            )
        )
        let configuration = WindowPlacementConfiguration(
            commands: [reserved, selected]
        )

        XCTAssertEqual(
            configuration.reservedActivationRegions(excluding: selected.id),
            [reserved.activationRegion]
        )
        XCTAssertEqual(
            configuration.activationConflict(
                for: selected.id,
                region: .init(
                    column: 1,
                    row: 1,
                    columnSpan: 2,
                    rowSpan: 2
                )
            ),
            reserved.id
        )
    }

    func testDragZonePresentationIncludesOnlyEffectiveActivationRegions() {
        let active = WindowPlacementCommand(
            behavior: .proportional,
            activationRegion: .init(
                column: 0,
                row: 0,
                columnSpan: 2,
                rowSpan: 2
            )
        )
        let disabled = WindowPlacementCommand(
            behavior: .proportional,
            activationRegion: .init(
                column: 2,
                row: 0,
                columnSpan: 2,
                rowSpan: 2
            ),
            isEnabled: false
        )
        let noRegion = WindowPlacementCommand(
            behavior: .proportional
        )
        let restore = WindowPlacementCommand(
            behavior: .restore,
            activationRegion: .init(
                column: 4,
                row: 0,
                columnSpan: 2,
                rowSpan: 2
            )
        )

        XCTAssertEqual(
            WindowPlacementDragZonePolicy.descriptors(
                for: [active, disabled, noRegion, restore]
            ),
            [
                WindowPlacementDragZoneDescriptor(
                    commandID: active.id,
                    region: active.activationRegion!
                )
            ]
        )
    }

    @MainActor
    func testActivationGridRejectsOccupiedCellsWhileAllowingAdjacentCells() {
        let grid = WindowPlacementGridView()
        grid.preventsOccupiedSelection = true
        grid.occupiedRegions = [
            .init(column: 0, row: 0, columnSpan: 2, rowSpan: 2)
        ]

        XCTAssertFalse(
            grid.canSelect(
                .init(column: 1, row: 1, columnSpan: 2, rowSpan: 2)
            )
        )
        XCTAssertTrue(
            grid.canSelect(
                .init(column: 2, row: 0, columnSpan: 2, rowSpan: 2)
            )
        )
        XCTAssertTrue(grid.acceptsFirstMouse(for: nil))
    }

    @MainActor
    func testActivationGridHoverOffersImmediateRegionRemoval() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let grid = WindowPlacementGridView()
        grid.frame = window.contentView!.bounds
        grid.showsRemovalControl = true
        grid.region = .init(
            column: 0,
            row: 0,
            columnSpan: 12,
            rowSpan: 6
        )
        window.contentView?.addSubview(grid)
        var removedRegion: WindowPlacementRegion?
        var changeCount = 0
        grid.onChange = { region in
            removedRegion = region
            changeCount += 1
        }

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: CGPoint(x: 100, y: 150),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        grid.mouseMoved(with: event)

        let removalButton = try XCTUnwrap(
            grid.subviews.compactMap { $0 as? NSButton }.first
        )
        XCTAssertFalse(removalButton.isHidden)
        removalButton.performClick(nil)
        XCTAssertNil(grid.region)
        XCTAssertNil(removedRegion)
        XCTAssertEqual(changeCount, 1)
    }

    @MainActor
    func testPaletteDefersSettingsPresentationUntilClickFinishes() {
        var deferredAction: WindowPlacementPaletteController.DeferredAction?
        let controller = WindowPlacementPaletteController { action in
            deferredAction = action
        }
        var presentationCount = 0
        controller.onOpenSettings = {
            presentationCount += 1
        }

        controller.requestSettingsPresentation()

        XCTAssertEqual(presentationCount, 0)
        XCTAssertNotNil(deferredAction)
        deferredAction?()
        XCTAssertEqual(presentationCount, 1)
    }

    func testConfigurationRoundTripsAndRestoresMissingBuiltIns() throws {
        let custom = WindowPlacementCommand.custom(name: "Reading")
        var configuration = WindowPlacementConfiguration(commands: [custom])
        let decoded = try JSONDecoder().decode(
            WindowPlacementConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        XCTAssertEqual(decoded, configuration)

        configuration.normalize()
        XCTAssertEqual(configuration.commands.first, custom)
        XCTAssertEqual(
            Set(configuration.commands.compactMap(\.builtIn)),
            Set(BuiltInWindowPlacement.allCases)
        )
    }

    func testGeometryCentersAndMapsAcrossDisplays() {
        let center = WindowPlacementCommand(
            behavior: .center
        )
        XCTAssertEqual(
            WindowPlacementGeometry.targetFrame(
                for: center,
                currentFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                visibleFrame: CGRect(x: 100, y: 50, width: 1000, height: 700)
            ),
            CGRect(x: 400, y: 250, width: 400, height: 300)
        )

        let next = WindowPlacementCommand(behavior: .nextDisplay)
        XCTAssertEqual(
            WindowPlacementGeometry.targetFrame(
                for: next,
                currentFrame: CGRect(x: 100, y: 100, width: 500, height: 400),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                adjacentVisibleFrame: CGRect(x: -1600, y: 0, width: 1600, height: 900)
            ),
            CGRect(x: -1290, y: 138, width: 500, height: 400)
        )
    }

    @MainActor
    func testScreenSelectionSupportsNegativeCoordinatesAndAdjacentWrapping() {
        let left = WindowPlacementScreen(
            displayID: 2,
            frame: CGRect(x: -1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: -1600, y: 24, width: 1600, height: 876)
        )
        let main = WindowPlacementScreen(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
        )
        let screens = [main, left]

        XCTAssertEqual(
            WindowPlacementScreens.screen(
                withLargestIntersection: CGRect(x: -500, y: 100, width: 700, height: 600),
                in: screens
            ),
            left
        )
        XCTAssertEqual(
            WindowPlacementScreens.adjacent(
                to: left,
                direction: .nextDisplay,
                in: screens
            ),
            main
        )
        XCTAssertEqual(
            WindowPlacementScreens.adjacent(
                to: left,
                direction: .previousDisplay,
                in: screens
            ),
            main
        )
    }

    func testShortcutPolicyRejectsOtherOmniDockFeaturesAndDuplicateLayouts() {
        let suiteName = "WindowPlacementShortcutPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(
            defaults: defaults,
            livePreviewLimitProvider: { 6 }
        )
        let shortcut = RecordedShortcut(
            keyCode: 37,
            modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue
        )
        settings.appHotkeyBindings = [
            AppHotkeyBinding(
                appName: "Sample",
                bundleURLString: "file:///Applications/Sample.app",
                bundleIdentifier: "com.example.Sample",
                keyCode: shortcut.keyCode,
                modifierFlags: shortcut.modifierFlags
            )
        ]

        var configuration = settings.windowPlacementConfiguration
        configuration.commands[0].shortcut = shortcut
        XCTAssertEqual(
            WindowPlacementShortcutPolicy.rejectionReason(
                for: shortcut,
                commandID: configuration.commands[0].id,
                configuration: configuration,
                settings: settings,
                systemShortcuts: []
            ),
            AppStrings.text(.windowPlacementShortcutConflict)
        )

        settings.appHotkeyBindings = []
        configuration.commands[1].shortcut = shortcut
        XCTAssertEqual(
            WindowPlacementShortcutPolicy.rejectionReason(
                for: shortcut,
                commandID: configuration.commands[0].id,
                configuration: configuration,
                settings: settings,
                systemShortcuts: []
            ),
            AppStrings.text(.hotkeyDuplicate)
        )
    }

    func testShortcutPolicyRejectsActiveWindowCycleShortcut() {
        let suiteName = "WindowPlacementWindowCycleShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(
            defaults: defaults,
            livePreviewLimitProvider: { 6 }
        )
        settings.windowCycleEnabled = true
        let command = WindowPlacementConfiguration.default.commands[0]

        XCTAssertNotNil(WindowPlacementShortcutPolicy.rejectionReason(
            for: WindowCycleShortcut.recorded,
            commandID: command.id,
            configuration: .default,
            settings: settings,
            systemShortcuts: []
        ))
    }

    func testWindowPlacementLabelsAreLocalized() {
        XCTAssertEqual(
            AppLocalization.text(.tabWindowPlacement, language: .en),
            "Window Layout"
        )
        XCTAssertEqual(
            AppLocalization.text(.tabWindowPlacement, language: .zhHans),
            "窗口调整"
        )
        XCTAssertEqual(
            AppLocalization.text(.windowPlacementLeftHalf, language: .en),
            "Left"
        )
        XCTAssertEqual(
            AppLocalization.text(.windowPlacementLeftHalf, language: .zhHans),
            "左侧"
        )
    }

    func testGreenButtonClickFailsOpenWithoutFreshOptionHit() {
        let frame = CGRect(x: 100, y: 40, width: 16, height: 16)
        XCTAssertTrue(WindowPlacementGreenButtonPolicy.shouldConsume(
            point: CGPoint(x: 108, y: 48),
            flags: [.maskAlternate],
            buttonFrame: frame,
            expiresAt: 5,
            now: 4
        ))
        XCTAssertFalse(WindowPlacementGreenButtonPolicy.shouldConsume(
            point: CGPoint(x: 108, y: 48),
            flags: [],
            buttonFrame: frame,
            expiresAt: 5,
            now: 4
        ))
        XCTAssertFalse(WindowPlacementGreenButtonPolicy.shouldConsume(
            point: CGPoint(x: 108, y: 48),
            flags: [.maskAlternate],
            buttonFrame: frame,
            expiresAt: 3,
            now: 4
        ))
        XCTAssertGreaterThan(
            WindowPlacementGreenButtonPolicy.snapshotLifetime,
            WindowPlacementGreenButtonPolicy.refreshInterval
        )
    }

    func testGreenButtonShieldForwardsPlainClickButKeepsOptionForPalette() {
        XCTAssertTrue(
            WindowPlacementGreenButtonPolicy.shouldForwardNativeAction(
                modifiers: []
            )
        )
        XCTAssertFalse(
            WindowPlacementGreenButtonPolicy.shouldForwardNativeAction(
                modifiers: [.option]
            )
        )
    }

    func testGreenButtonHoverIsSuppressedOnlyInsideFreshSnapshot() {
        let frame = CGRect(x: 20, y: 30, width: 14, height: 14)
        XCTAssertTrue(
            WindowPlacementGreenButtonPolicy.shouldSuppressNativeHover(
                point: CGPoint(x: 27, y: 37),
                buttonFrame: frame,
                expiresAt: 12,
                now: 11
            )
        )
        XCTAssertFalse(
            WindowPlacementGreenButtonPolicy.shouldSuppressNativeHover(
                point: CGPoint(x: 80, y: 80),
                buttonFrame: frame,
                expiresAt: 12,
                now: 11
            )
        )
        XCTAssertFalse(
            WindowPlacementGreenButtonPolicy.shouldSuppressNativeHover(
                point: CGPoint(x: 27, y: 37),
                buttonFrame: frame,
                expiresAt: 10,
                now: 11
            )
        )
    }

    func testGreenButtonHoverCanTriggerAgainAfterPointerLeaves() {
        var tracker = WindowPlacementGreenButtonHoverTracker()
        let target = WindowPlacementRuntimeIdentifier(
            processIdentifier: 42,
            windowID: 7,
            fallbackElementHash: 0
        )
        let frame = CGRect(x: 20, y: 30, width: 14, height: 14)

        XCTAssertTrue(
            tracker.entered(
                targetIdentifier: target,
                buttonFrame: frame
            )
        )
        XCTAssertFalse(
            tracker.entered(
                targetIdentifier: target,
                buttonFrame: frame
            )
        )

        tracker.leftButton()

        XCTAssertTrue(
            tracker.entered(
                targetIdentifier: target,
                buttonFrame: frame
            )
        )
    }

    func testDragPolicyRequiresTheWindowFrameToMove() {
        let initial = CGRect(x: 100, y: 100, width: 600, height: 400)
        XCTAssertFalse(WindowPlacementDragPolicy.recognizedWindowMovement(
            initialFrame: initial,
            currentFrame: initial.offsetBy(dx: 2, dy: 0)
        ))
        XCTAssertTrue(WindowPlacementDragPolicy.recognizedWindowMovement(
            initialFrame: initial,
            currentFrame: initial.offsetBy(dx: 4, dy: 0)
        ))
    }

    func testDragPolicyOnlyActivatesInsideConfiguredZone() throws {
        let command = WindowPlacementCommand(
            behavior: .proportional,
            activationRegion: .init(
                column: 0,
                row: 0,
                columnSpan: 2,
                rowSpan: 2
            )
        )
        let configuration = WindowPlacementConfiguration(
            commands: [command]
        )
        let screen = WindowPlacementScreen(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1_200, height: 876)
        )

        XCTAssertEqual(
            WindowPlacementDragPolicy.matchingCommand(
                at: CGPoint(x: 40, y: 40),
                screen: screen,
                configuration: configuration
            )?.id,
            command.id
        )
        XCTAssertNil(
            WindowPlacementDragPolicy.matchingCommand(
                at: CGPoint(x: 600, y: 450),
                screen: screen,
                configuration: configuration
            )
        )
    }

}
