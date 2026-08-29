import AppKit
import Carbon.HIToolbox
import CoreData
import CryptoKit
import XCTest
@testable import OmniDockCore

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    func testClipboardHistoryDefaultsOffAndPersistsLimit() {
        let defaults = isolatedDefaults()
        let settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })

        XCTAssertFalse(settings.clipboardHistoryEnabled)
        XCTAssertEqual(settings.clipboardHistoryLimit, 200)

        settings.clipboardHistoryEnabled = true
        settings.clipboardHistoryLimit = 350

        let reloaded = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        XCTAssertTrue(reloaded.clipboardHistoryEnabled)
        XCTAssertEqual(reloaded.clipboardHistoryLimit, 350)
    }

    func testDisabledClipboardHistoryDoesNotCreateStoreOrReadKey() {
        let settings = SettingsStore(
            defaults: isolatedDefaults(),
            livePreviewLimitProvider: { 8 }
        )
        let keyStore = ClipboardHistoryKeyStoreSpy()
        var storeCreationCount = 0
        let service = ClipboardHistoryService(
            settings: settings,
            permissionService: PermissionService(),
            storeProvider: {
                storeCreationCount += 1
                return ClipboardHistoryStore(
                    storeURL: nil,
                    inMemory: false,
                    keyStore: keyStore
                )
            },
            panelController: ClipboardPaletteController(),
            registrationStatus: ClipboardHistoryRegistrationStatus(),
            hotkeyRegistry: ClipboardHistoryHotkeyRegistrySpy()
        )

        service.start()

        XCTAssertEqual(storeCreationCount, 0)
        XCTAssertEqual(keyStore.loadCount, 0)
        XCTAssertEqual(service.snapshot().records, [])
        XCTAssertNil(service.snapshot().warning)
        service.stop()
    }

    func testEnablingClipboardHistoryCreatesStoreOnlyOncePerRun() {
        let settings = SettingsStore(
            defaults: isolatedDefaults(),
            livePreviewLimitProvider: { 8 }
        )
        let keyStore = ClipboardHistoryKeyStoreSpy(
            failure: .storageUnavailable(EACCES)
        )
        var storeCreationCount = 0
        let service = ClipboardHistoryService(
            settings: settings,
            permissionService: PermissionService(),
            storeProvider: {
                storeCreationCount += 1
                return ClipboardHistoryStore(
                    storeURL: nil,
                    inMemory: false,
                    keyStore: keyStore
                )
            },
            panelController: ClipboardPaletteController(),
            registrationStatus: ClipboardHistoryRegistrationStatus(),
            hotkeyRegistry: ClipboardHistoryHotkeyRegistrySpy()
        )
        service.start()

        settings.clipboardHistoryEnabled = true
        XCTAssertEqual(storeCreationCount, 1)
        XCTAssertEqual(keyStore.loadCount, 1)
        XCTAssertEqual(
            service.snapshot().warning,
            AppStrings.text(.clipboardStorageUnavailable)
        )

        settings.clipboardHistoryEnabled = false
        settings.clipboardHistoryEnabled = true
        XCTAssertEqual(storeCreationCount, 1)
        XCTAssertEqual(keyStore.loadCount, 1)
        service.stop()
    }

    func testSettingsExposeClipboardAndWindowPlacementTabs() {
        XCTAssertEqual(SettingsTab.allCases.count, 7)
        XCTAssertEqual(SettingsTab.allCases[4], .clipboardHistory)
        XCTAssertEqual(SettingsTab.allCases.last, .hiddenBar)
    }

    func testClipboardHistoryLabelsAreLocalized() {
        LocalizedResourceCatalog.configure(language: .en)
        XCTAssertEqual(AppStrings.text(.tabClipboardHistory), "Clipboard History")
        XCTAssertEqual(AppStrings.text(.clipboardEnableTitle), "Enable Clipboard History")

        LocalizedResourceCatalog.configure(language: .zhHans)
        XCTAssertEqual(AppStrings.text(.tabClipboardHistory), "剪贴板历史")
        XCTAssertEqual(AppStrings.text(.clipboardEnableTitle), "启用剪贴板历史")
        LocalizedResourceCatalog.configure(language: .system)
    }

    func testLongClipboardContentUsesACompactSingleLineListSummary() {
        let content = String(repeating: "Long clipboard line\n", count: 80)

        let summary = ClipboardHistoryDisplayText.summary(content)

        XCTAssertEqual(summary.count, ClipboardHistoryDisplayText.maximumSummaryLength)
        XCTAssertFalse(summary.contains("\n"))
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testLongClipboardContentCannotExpandSettingsHistoryRow() {
        let record = ClipboardHistoryRecord(
            id: UUID(),
            capturedAt: Date(),
            lastCopiedAt: Date(),
            sourceApplicationName: String(repeating: "Source application ", count: 40),
            sourceBundleIdentifier: nil,
            kind: .text,
            summary: String(repeating: "Very long clipboard content ", count: 200),
            searchableText: String(repeating: "Very long clipboard content ", count: 200),
            copyCount: 1,
            byteCount: 8_000,
            thumbnailData: nil
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 48))
        let row = ClipboardArchiveSettingsRowView(record: record)
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.frame.width, container.bounds.width, accuracy: 0.5)
        for field in descendantTextFields(in: row) {
            let fieldFrame = field.convert(field.bounds, to: row)
            XCTAssertGreaterThanOrEqual(fieldFrame.minX, row.bounds.minX)
            XCTAssertLessThanOrEqual(fieldFrame.maxX, row.bounds.maxX)
        }
    }

    func testSettingsHistoryListVirtualizesLargeArchive() {
        let controller = ClipboardHistoryListController()
        let records = (0..<999).map { index in
            ClipboardHistoryRecord(
                id: UUID(),
                capturedAt: Date(),
                lastCopiedAt: Date(),
                sourceApplicationName: "Source \(index)",
                sourceBundleIdentifier: nil,
                kind: .text,
                summary: "Clipboard entry \(index)",
                searchableText: "Clipboard entry \(index)",
                copyCount: 1,
                byteCount: 32,
                thumbnailData: nil
            )
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        controller.apply(records: records)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        XCTAssertEqual(controller.recordCount, 999)
        XCTAssertGreaterThan(controller.createdRowViewCount, 0)
        XCTAssertLessThan(controller.createdRowViewCount, 40)
    }

    func testClipboardHistorySnapshotRevisionChangesAfterMutation() throws {
        let store = ClipboardHistoryStore(storeURL: nil, inMemory: true)
        let record = try XCTUnwrap(store.store(
            try candidate(text: "Revision", capturedAt: Date()),
            limit: 200,
            maximumTotalBytes: 1_000_000
        ))
        let settings = SettingsStore(
            defaults: isolatedDefaults(),
            livePreviewLimitProvider: { 8 }
        )
        settings.clipboardHistoryEnabled = true
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardHistoryService(
            settings: settings,
            permissionService: PermissionService(),
            store: store,
            panelController: ClipboardPaletteController(),
            registrationStatus: ClipboardHistoryRegistrationStatus(),
            hotkeyRegistry: ClipboardHistoryHotkeyRegistrySpy(),
            pasteboard: pasteboard
        )
        service.start()
        defer { service.stop() }
        let initialRevision = service.snapshot().revision

        service.delete(id: record.id)

        XCTAssertGreaterThan(service.snapshot().revision, initialRevision)
        XCTAssertTrue(service.snapshot().records.isEmpty)
    }

    func testSettingsHistoryRowShowsStoredAndFallbackImageThumbnails() throws {
        let imageData = try tinyPNGData()
        for usesStoredThumbnail in [true, false] {
            let record = ClipboardHistoryRecord(
                id: UUID(),
                capturedAt: Date(),
                lastCopiedAt: Date(),
                sourceApplicationName: "Preview Source",
                sourceBundleIdentifier: nil,
                kind: .image,
                summary: "Image",
                searchableText: "Image",
                copyCount: 1,
                byteCount: imageData.count,
                thumbnailData: usesStoredThumbnail ? imageData : nil
            )
            let row = ClipboardArchiveSettingsRowView(
                record: record,
                fallbackImage: usesStoredThumbnail ? nil : NSImage(data: imageData)
            )

            XCTAssertEqual(
                descendantImageViews(in: row).count,
                2
            )
        }
    }

    func testSettingsHistoryRowPublishesHoverChanges() throws {
        let record = ClipboardHistoryRecord(
            id: UUID(),
            capturedAt: Date(),
            lastCopiedAt: Date(),
            sourceApplicationName: "Preview Source",
            sourceBundleIdentifier: nil,
            kind: .text,
            summary: "Text",
            searchableText: "Text",
            copyCount: 1,
            byteCount: 4,
            thumbnailData: nil
        )
        let row = ClipboardArchiveSettingsRowView(record: record)
        var hoverChanges: [Bool] = []
        row.onHoverChanged = {
            hoverChanges.append($0)
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        row.mouseEntered(with: event)
        row.mouseExited(with: event)

        XCTAssertEqual(hoverChanges, [true, false])
    }

    func testClipboardHoverDismissesVisiblePreviewWhenPointerLeavesItsRow() {
        let recordID = UUID()

        XCTAssertEqual(
            ClipboardHoverPreviewPolicy.action(
                recordID: recordID,
                hovering: false,
                pendingRecordID: nil,
                previewedRecordID: recordID,
                previewVisible: true
            ),
            .dismiss
        )
    }

    func testClipboardHoverCancelsPendingPreviewBeforeItAppears() {
        let recordID = UUID()

        XCTAssertEqual(
            ClipboardHoverPreviewPolicy.action(
                recordID: recordID,
                hovering: false,
                pendingRecordID: recordID,
                previewedRecordID: nil,
                previewVisible: false
            ),
            .cancelPending
        )
    }

    func testClipboardHistoryLimitIsClampedToSupportedRange() {
        let settings = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })

        settings.clipboardHistoryLimit = 0
        XCTAssertEqual(settings.clipboardHistoryLimit, 1)

        settings.clipboardHistoryLimit = 1_500
        XCTAssertEqual(settings.clipboardHistoryLimit, 999)
    }

    func testCodecPreservesMultipleFilesAsOnePayload() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let firstURL = URL(fileURLWithPath: "/tmp/First.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/Second.md")
        let first = NSPasteboardItem()
        let second = NSPasteboardItem()
        XCTAssertTrue(first.setString(firstURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(second.setString(secondURL.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let candidate = try XCTUnwrap(makeCandidate(from: pasteboard))
        let payload = try XCTUnwrap(ClipboardHistoryCodec.decode(candidate.payloadData))

        XCTAssertEqual(candidate.kind, .files)
        XCTAssertEqual(payload.items.count, 2)
        XCTAssertTrue(candidate.searchableText.contains(firstURL.path))
        XCTAssertTrue(candidate.searchableText.contains(secondURL.path))
    }

    func testCodecRejectsPrivacyMarkerTypes() {
        for type in [
            ClipboardHistoryCodec.transientType,
            ClipboardHistoryCodec.concealedType,
            ClipboardHistoryCodec.autoGeneratedType
        ] {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setString("secret", forType: .string))
            XCTAssertTrue(item.setString("", forType: type))
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([item]))

            XCTAssertNil(makeCandidate(from: pasteboard))
        }
    }

    func testCodecRoundTripsTextAndRichRepresentations() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("Formatted text", forType: .string))
        let attributed = NSAttributedString(
            string: "Formatted text",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        let range = NSRange(location: 0, length: attributed.length)
        let rtf = try attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        XCTAssertTrue(item.setData(rtf, forType: .rtf))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let candidate = try XCTUnwrap(makeCandidate(from: pasteboard))
        let payload = try XCTUnwrap(ClipboardHistoryCodec.decode(candidate.payloadData))
        let output = NSPasteboard.withUniqueName()
        defer { output.releaseGlobally() }

        XCTAssertTrue(ClipboardHistoryCodec.write(
            payload,
            to: output,
            sourceIdentifier: "com.example.Test"
        ))
        XCTAssertEqual(output.string(forType: .string), "Formatted text")
        XCTAssertNotNil(output.data(forType: .rtf))
    }

    func testCodecCapturesURLAndImageContent() throws {
        let URLPasteboard = NSPasteboard.withUniqueName()
        defer { URLPasteboard.releaseGlobally() }
        URLPasteboard.clearContents()
        XCTAssertTrue(URLPasteboard.setString("https://example.com/path", forType: .URL))
        let URLCandidate = try XCTUnwrap(makeCandidate(from: URLPasteboard))
        XCTAssertEqual(URLCandidate.kind, .url)
        XCTAssertTrue(URLCandidate.searchableText.contains("example.com"))

        let imagePasteboard = NSPasteboard.withUniqueName()
        defer { imagePasteboard.releaseGlobally() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        imagePasteboard.clearContents()
        XCTAssertTrue(imagePasteboard.setData(imageData, forType: .png))
        let imageCandidate = try XCTUnwrap(makeCandidate(from: imagePasteboard))
        XCTAssertEqual(imageCandidate.kind, .image)
        XCTAssertNotNil(imageCandidate.thumbnailData)
    }

    func testStagedCaptureMatchesDirectCandidate() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Staged capture", forType: .string))

        let direct = try XCTUnwrap(makeCandidate(from: pasteboard))
        let payload = try XCTUnwrap(ClipboardHistoryCodec.payload(from: pasteboard))
        let processed = try XCTUnwrap(ClipboardHistoryCodec.processedCapture(
            from: payload,
            maximumPayloadBytes: ClipboardHistoryService.maximumEntryBytes
        ))
        let staged = ClipboardHistoryCodec.candidate(
            from: processed,
            sourceApplication: nil
        )

        XCTAssertEqual(staged.fingerprint, direct.fingerprint)
        XCTAssertEqual(staged.payloadData, direct.payloadData)
        XCTAssertEqual(staged.kind, direct.kind)
        XCTAssertEqual(staged.summary, direct.summary)
        XCTAssertEqual(staged.searchableText, direct.searchableText)
        XCTAssertEqual(staged.byteCount, direct.byteCount)
    }

    func testOversizedCaptureDropsImagesAndKeepsTextRepresentations() throws {
        let text = "Bounded caption"
        let payload = ClipboardPayload(items: [
            ClipboardPayloadItem(representations: [
                ClipboardPayloadRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data(text.utf8)
                ),
                ClipboardPayloadRepresentation(
                    typeIdentifier: NSPasteboard.PasteboardType.png.rawValue,
                    data: Data(count: 4_096)
                )
            ])
        ])

        let processed = try XCTUnwrap(ClipboardHistoryCodec.processedCapture(
            from: payload,
            maximumPayloadBytes: 1_024
        ))
        let retainedTypes = processed.payload.items.flatMap {
            $0.representations.map(\.typeIdentifier)
        }
        XCTAssertEqual(retainedTypes, [NSPasteboard.PasteboardType.string.rawValue])
        XCTAssertLessThanOrEqual(processed.payloadData.count, 1_024)
        XCTAssertNil(processed.thumbnailData)

        XCTAssertNil(ClipboardHistoryCodec.processedCapture(
            from: payload,
            maximumPayloadBytes: 8
        ))
    }

    func testStoreDeduplicatesContentAndMovesItToTheTop() throws {
        let store = ClipboardHistoryStore(storeURL: nil, inMemory: true)
        let first = try candidate(text: "Repeated", capturedAt: Date(timeIntervalSince1970: 10))
        let second = try candidate(text: "Repeated", capturedAt: Date(timeIntervalSince1970: 20))

        store.store(first, limit: 200, maximumTotalBytes: 1_000_000)
        store.store(second, limit: 200, maximumTotalBytes: 1_000_000)

        let records = store.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].copyCount, 2)
        XCTAssertEqual(records[0].lastCopiedAt, second.capturedAt)
    }

    func testStorePrunesByCountAndTotalSize() throws {
        let store = ClipboardHistoryStore(storeURL: nil, inMemory: true)
        let older = try candidate(text: "Older", capturedAt: Date(timeIntervalSince1970: 10))
        let newer = try candidate(text: "Newer", capturedAt: Date(timeIntervalSince1970: 20))

        store.store(older, limit: 2, maximumTotalBytes: 1_000_000)
        store.store(newer, limit: 1, maximumTotalBytes: 1_000_000)

        XCTAssertEqual(store.records().map(\.summary), ["Newer"])

        store.prune(limit: 10, maximumTotalBytes: 1)
        XCTAssertTrue(store.records().isEmpty)
    }

    func testPersistentStoreRestoresRecordsAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniDockClipboardTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Clipboard.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyCandidate = try candidate(text: "Persisted", capturedAt: Date())

        let cipher = ClipboardHistoryCipher.ephemeral()
        var store: ClipboardHistoryStore? = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            cipher: cipher
        )
        store?.store(historyCandidate, limit: 200, maximumTotalBytes: 1_000_000)
        XCTAssertEqual(store?.records().count, 1)
        store = nil

        let reloaded = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            cipher: cipher
        )
        XCTAssertEqual(reloaded.records().map(\.summary), ["Persisted"])
    }

    func testPersistentStoreUsesPrivateDirectoryAndFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniDockClipboardPermissions-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Clipboard.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            cipher: .ephemeral()
        )
        store.store(
            try candidate(text: "Private", capturedAt: Date()),
            limit: 200,
            maximumTotalBytes: 1_000_000
        )

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value,
            0o700
        )
        let storeFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(storeURL.lastPathComponent) }
        XCTAssertFalse(storeFiles.isEmpty)
        for file in storeFiles {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let permissions = try XCTUnwrap(
                (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            )
            XCTAssertEqual(permissions & 0o022, 0)
            XCTAssertNotEqual(permissions & 0o600, 0)
        }
    }

    func testPersistentStoreSecuresExternalBinaryDataFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniDockClipboardExternal-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Clipboard.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        try ClipboardStoreFileProtection.prepareDirectory(directory)

        // Core Data promotes clipboard images and large text out of the row
        // into this sibling directory, creating both with the default umask.
        let externalDirectory = directory
            .appendingPathComponent(".Clipboard_SUPPORT", isDirectory: true)
            .appendingPathComponent("_EXTERNAL_DATA", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let blobURL = externalDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Private".utf8).write(to: blobURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: blobURL.path
        )

        ClipboardStoreFileProtection.secureStoreFiles(storeURL: storeURL)

        XCTAssertEqual(try posixPermissions(of: externalDirectory), 0o700)
        XCTAssertEqual(try posixPermissions(of: blobURL), 0o600)
    }

    func testAutoPasteReadinessRejectsMissingTargetAndSecureInput() {
        XCTAssertEqual(
            ClipboardAutoPastePolicy.readiness(
                hasTarget: true,
                isTargetTerminated: false,
                isSecureInputEnabled: false
            ),
            .ready
        )
        XCTAssertEqual(
            ClipboardAutoPastePolicy.readiness(
                hasTarget: false,
                isTargetTerminated: false,
                isSecureInputEnabled: false
            ),
            .targetUnavailable
        )
        XCTAssertEqual(
            ClipboardAutoPastePolicy.readiness(
                hasTarget: true,
                isTargetTerminated: true,
                isSecureInputEnabled: false
            ),
            .targetUnavailable
        )
        XCTAssertEqual(
            ClipboardAutoPastePolicy.readiness(
                hasTarget: true,
                isTargetTerminated: false,
                isSecureInputEnabled: true
            ),
            .secureInputActive
        )
    }

    func testAutoPasteWaitsForTargetInsteadOfPastingIntoAnotherApp() {
        let now = Date()
        let deadline = now.addingTimeInterval(
            ClipboardAutoPastePolicy.activationTimeout
        )

        XCTAssertEqual(
            autoPasteStep(frontmost: 42, now: now, deadline: deadline),
            .wait
        )
        XCTAssertEqual(
            autoPasteStep(frontmost: nil, now: now, deadline: deadline),
            .wait
        )
        XCTAssertEqual(
            autoPasteStep(frontmost: 7, now: now, deadline: deadline),
            .paste
        )
        XCTAssertEqual(
            autoPasteStep(frontmost: 42, now: deadline, deadline: deadline),
            .cancel
        )
        XCTAssertEqual(
            autoPasteStep(
                frontmost: 7,
                now: now,
                deadline: deadline,
                isTargetTerminated: true
            ),
            .cancel
        )
        XCTAssertEqual(
            autoPasteStep(
                frontmost: 7,
                now: now,
                deadline: deadline,
                isSecureInputEnabled: true
            ),
            .cancel
        )
    }

    func testStoredArchiveLeavesNoClipboardTextOnDisk() throws {
        let directory = try makeStoreDirectory()
        let storeURL = directory.appendingPathComponent("Clipboard.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "CorrectHorseBatteryStaple-\(UUID().uuidString)"

        let store = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            cipher: .ephemeral()
        )
        store.store(
            try candidate(text: secret, capturedAt: Date()),
            limit: 200,
            maximumTotalBytes: 1_000_000
        )

        XCTAssertEqual(store.records().map(\.summary), [secret])
        XCTAssertFalse(try directoryContainsPlaintext(directory, needle: secret))
    }

    func testArchiveFromAnIncompatibleSchemaIsDiscardedWithItsPlaintext() throws {
        let directory = try makeStoreDirectory()
        let storeURL = directory.appendingPathComponent("Clipboard.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "LegacyPlaintext-\(UUID().uuidString)"

        try writeLegacySchemaEntry(text: secret, to: storeURL)
        XCTAssertTrue(try directoryContainsPlaintext(directory, needle: secret))

        let store = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            cipher: .ephemeral()
        )

        // The old archive is dropped rather than migrated, and its plaintext
        // goes with it. The store is immediately usable again.
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertNil(store.warning)
        XCTAssertFalse(try directoryContainsPlaintext(directory, needle: secret))

        let fresh = "AfterRebuild-\(UUID().uuidString)"
        store.store(
            try candidate(text: fresh, capturedAt: Date()),
            limit: 200,
            maximumTotalBytes: 1_000_000
        )
        XCTAssertEqual(store.records().map(\.summary), [fresh])
        XCTAssertFalse(try directoryContainsPlaintext(directory, needle: fresh))
    }

    func testEntriesSealedWithALostKeyAreDiscarded() throws {
        let directory = try makeStoreDirectory()
        let storeURL = directory.appendingPathComponent("Clipboard.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            cipher: .ephemeral()
        )
        store.store(
            try candidate(text: "Unrecoverable", capturedAt: Date()),
            limit: 200,
            maximumTotalBytes: 1_000_000
        )
        XCTAssertEqual(store.records().count, 1)

        // A restored archive whose Keychain item did not come with it.
        let reopened = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            cipher: .ephemeral()
        )

        XCTAssertTrue(reopened.records().isEmpty)
    }

    func testLocalKeyStoreCreatesAPrivateKeyFileAndReusesIt() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("ClipboardHistoryKey")
        let keyStore = ClipboardHistoryLocalKeyStore(keyURL: keyURL)

        let first = try keyStore.loadOrCreateKey()

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertEqual(try posixPermissions(of: keyURL), 0o600)
        XCTAssertEqual(try Data(contentsOf: keyURL).count, 32)

        // A second read must return the same key, or every relaunch would
        // strand the archive written by the previous one.
        let second = try ClipboardHistoryLocalKeyStore(keyURL: keyURL).loadOrCreateKey()
        XCTAssertEqual(
            first.withUnsafeBytes { Data($0) },
            second.withUnsafeBytes { Data($0) }
        )
    }

    func testLocalKeyStoreRestoresTightPermissionsOnRead() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("ClipboardHistoryKey")
        let keyStore = ClipboardHistoryLocalKeyStore(keyURL: keyURL)
        _ = try keyStore.loadOrCreateKey()

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: keyURL.path
        )
        _ = try keyStore.loadOrCreateKey()

        XCTAssertEqual(try posixPermissions(of: keyURL), 0o600)
    }

    func testLocalKeyStoreRejectsATruncatedKeyFile() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("ClipboardHistoryKey")
        try Data(repeating: 0, count: 8).write(to: keyURL)

        XCTAssertThrowsError(
            try ClipboardHistoryLocalKeyStore(keyURL: keyURL).loadOrCreateKey()
        ) { error in
            XCTAssertEqual(error as? ClipboardHistoryKeyError, .malformedKey)
        }
    }

    func testArchiveSurvivesReopeningWithTheLocalKeyStore() throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Clipboard.sqlite")
        let keyStore = ClipboardHistoryLocalKeyStore(
            keyURL: directory.appendingPathComponent("ClipboardHistoryKey")
        )
        let secret = "LocalKeyPersistence-\(UUID().uuidString)"

        var store: ClipboardHistoryStore? = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            keyStore: keyStore
        )
        store?.store(
            try candidate(text: secret, capturedAt: Date()),
            limit: 200,
            maximumTotalBytes: 1_000_000
        )
        XCTAssertNil(store?.warning)
        store = nil

        let reopened = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            keyStore: keyStore
        )

        XCTAssertEqual(reopened.records().map(\.summary), [secret])
        // The key lives beside the archive, but the archive itself still holds
        // no readable content.
        XCTAssertFalse(try directoryContainsPlaintext(directory, needle: secret))
    }

    func testUnavailableKeyKeepsHistoryOutOfTheStoreFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OmniDockClipboardUnavailable-\(UUID().uuidString)",
                isDirectory: true
            )
        let storeURL = directory.appendingPathComponent("Clipboard.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ClipboardHistoryStore(
            storeURL: storeURL,
            inMemory: false,
            keyStore: FailingClipboardKeyStore(error: .storageUnavailable(EACCES))
        )
        store.store(
            try candidate(text: "Session only", capturedAt: Date()),
            limit: 200,
            maximumTotalBytes: 1_000_000
        )

        // Usable for this session, but nothing reaches the disk unprotected.
        XCTAssertEqual(store.records().count, 1)
        XCTAssertEqual(store.warning, AppStrings.text(.clipboardStorageUnavailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnexpectedKeyFailureUsesGenericMemoryOnlyWarning() {
        let store = ClipboardHistoryStore(
            storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Clipboard-\(UUID().uuidString).sqlite"),
            inMemory: false,
            keyStore: FailingClipboardKeyStore(error: .malformedKey)
        )

        XCTAssertEqual(
            store.warning,
            AppStrings.text(.clipboardStorageUnavailable)
        )
    }

    func testCipherRoundTripsAndBlindsTheDeduplicationIndex() throws {
        let cipher = ClipboardHistoryCipher.ephemeral()
        let plaintext = Data("clipboard secret".utf8)

        let sealed = try XCTUnwrap(cipher.seal(plaintext))
        XCTAssertNil(sealed.range(of: Data("secret".utf8)))
        XCTAssertEqual(cipher.open(sealed), plaintext)

        let sealedText = try XCTUnwrap(cipher.seal(text: "clipboard secret"))
        XCTAssertEqual(cipher.openText(sealedText), "clipboard secret")

        // Another key cannot open it, and neither can a tampered box.
        XCTAssertNil(ClipboardHistoryCipher.ephemeral().open(sealed))
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertNil(cipher.open(tampered))
        XCTAssertNil(cipher.open(Data("not a sealed box".utf8)))

        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(cipher.blindIndex(for: digest), cipher.blindIndex(for: digest))
        XCTAssertNotEqual(cipher.blindIndex(for: digest), digest)
        XCTAssertNotEqual(
            cipher.blindIndex(for: digest),
            ClipboardHistoryCipher.ephemeral().blindIndex(for: digest)
        )
    }

    func testSearchIsCaseAndDiacriticInsensitive() throws {
        let record = try storedRecord(text: "Résumé from Browser")

        XCTAssertEqual(
            ClipboardArchiveSearch.filter([record], query: "resume").map(\.id),
            [record.id]
        )
        XCTAssertTrue(ClipboardArchiveSearch.filter([record], query: "missing").isEmpty)
    }

    func testReservedClipboardShortcutIsRejectedByAppHotkeyRecorder() {
        XCTAssertEqual(
            ShortcutRecorderValidation.rejectionReason(
                for: ClipboardHistoryShortcut.defaultShortcut,
                systemShortcuts: [],
                reservedShortcuts: [ClipboardHistoryShortcut.defaultShortcut]
            ),
            AppStrings.text(.hotkeyReservedForClipboardHistory)
        )
    }

    func testDisabledFeatureDoesNotRegisterAndEnablingRegistersImmediately() {
        let settings = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        let registry = ClipboardHistoryHotkeyRegistrySpy()
        let service = makeService(settings: settings, registry: registry)

        service.start()
        XCTAssertEqual(registry.registerCount, 0)
        XCTAssertFalse(service.isMonitoring)

        settings.clipboardHistoryEnabled = true
        XCTAssertEqual(registry.registerCount, 1)
        XCTAssertTrue(service.isMonitoring)

        settings.clipboardHistoryEnabled = false
        XCTAssertEqual(registry.unregisterCount, 1)
        XCTAssertFalse(service.isMonitoring)
        service.stop()
    }

    func testHotkeyTogglesHistoryPanel() {
        let settings = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        settings.clipboardHistoryEnabled = true
        let registry = ClipboardHistoryHotkeyRegistrySpy()
        let service = makeService(settings: settings, registry: registry)
        service.start()

        registry.trigger()
        XCTAssertTrue(service.isPanelVisible)

        registry.trigger()
        XCTAssertFalse(service.isPanelVisible)
        service.stop()
    }

    func testClipboardPanelAppearsBelowCursor() {
        let origin = ClipboardPalettePlacement.origin(
            cursor: NSPoint(x: 420, y: 760),
            panelSize: NSSize(width: 300, height: 240),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_200, height: 800)
        )

        XCTAssertEqual(origin, NSPoint(x: 420, y: 520))
    }

    func testClipboardPanelStaysInsideCurrentScreen() {
        let visibleFrame = NSRect(x: 1_440, y: 40, width: 1_280, height: 760)
        let panelSize = ClipboardPaletteLayout.historySize(in: visibleFrame)

        let nearRightEdge = ClipboardPalettePlacement.origin(
            cursor: NSPoint(x: 2_690, y: 760),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(nearRightEdge, NSPoint(x: 2_270, y: 220))

        let nearBottomEdge = ClipboardPalettePlacement.origin(
            cursor: NSPoint(x: 1_500, y: 80),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(nearBottomEdge, NSPoint(x: 1_500, y: 40))
    }

    func testClipboardPanelUsesScreenOriginWhenPanelIsLargerThanVisibleArea() {
        let origin = ClipboardPalettePlacement.origin(
            cursor: NSPoint(x: -900, y: 400),
            panelSize: NSSize(width: 900, height: 700),
            visibleFrame: NSRect(x: -1_200, y: 24, width: 800, height: 600)
        )

        XCTAssertEqual(origin, NSPoint(x: -1_200, y: 24))
    }

    func testClipboardDetailPanelUsesAvailableSideOfHistoryPanel() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 1_440, height: 876)
        let detailSize = NSSize(width: 400, height: 540)

        let rightOrigin = ClipboardInspectorPlacement.origin(
            beside: NSRect(x: 100, y: 200, width: 450, height: 540),
            detailSize: detailSize,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(rightOrigin, NSPoint(x: 558, y: 200))

        let leftOrigin = ClipboardInspectorPlacement.origin(
            beside: NSRect(x: 760, y: 200, width: 450, height: 540),
            detailSize: detailSize,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(leftOrigin, NSPoint(x: 352, y: 200))
    }

    func testClipboardDetailPanelRemainsInsideSmallVisibleFrame() {
        let origin = ClipboardInspectorPlacement.origin(
            beside: NSRect(x: 200, y: 100, width: 450, height: 540),
            detailSize: ClipboardPaletteLayout.detailSize(
                beside: NSRect(x: 200, y: 100, width: 450, height: 540),
                in: NSRect(x: 0, y: 24, width: 1_024, height: 700)
            ),
            visibleFrame: NSRect(x: 0, y: 24, width: 1_024, height: 700)
        )

        let detailSize = ClipboardPaletteLayout.detailSize(
            beside: NSRect(x: 200, y: 100, width: 450, height: 540),
            in: NSRect(x: 0, y: 24, width: 1_024, height: 700)
        )
        XCTAssertGreaterThanOrEqual(origin.x, 0)
        XCTAssertLessThanOrEqual(origin.x + detailSize.width, 1_024)
        XCTAssertGreaterThanOrEqual(origin.y, 24)
        XCTAssertLessThanOrEqual(origin.y + detailSize.height, 724)
    }

    func testClipboardPanelsUseCompactMaximumWidths() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 1_440, height: 876)
        let historySize = ClipboardPaletteLayout.historySize(in: visibleFrame)
        let detailSize = ClipboardPaletteLayout.detailSize(
            beside: NSRect(origin: .zero, size: historySize),
            in: visibleFrame
        )

        XCTAssertEqual(historySize.width, 450)
        XCTAssertEqual(detailSize.width, 400)
    }

    func testClipboardPanelsShrinkOnNarrowScreens() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 700, height: 576)
        let historySize = ClipboardPaletteLayout.historySize(in: visibleFrame)
        let detailSize = ClipboardPaletteLayout.detailSize(
            beside: NSRect(x: 0, y: 24, width: historySize.width, height: historySize.height),
            in: visibleFrame
        )

        XCTAssertLessThanOrEqual(historySize.width, 450)
        XCTAssertLessThan(detailSize.width, 400)
        XCTAssertLessThanOrEqual(
            historySize.width + ClipboardPaletteLayout.panelGap + detailSize.width,
            visibleFrame.width
        )
    }

    func testLongClipboardTextCannotExpandHistoryPanel() {
        let controller = ClipboardPaletteController()
        let record = ClipboardHistoryRecord(
            id: UUID(),
            capturedAt: Date(),
            lastCopiedAt: Date(),
            sourceApplicationName: "Example",
            sourceBundleIdentifier: nil,
            kind: .text,
            summary: String(repeating: "Very long clipboard content ", count: 100),
            searchableText: "",
            copyCount: 1,
            byteCount: 1,
            thumbnailData: nil
        )

        controller.show(records: [record], warning: nil, sourceApplication: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertLessThanOrEqual(
            controller.currentPanelSize?.width ?? .greatestFiniteMagnitude,
            ClipboardPaletteLayout.preferredHistorySize.width
        )
        controller.hide()
    }

    func testClipboardPaletteShowsBeforeAllRowsAreBuilt() async {
        let controller = ClipboardPaletteController()
        let records = paletteRecords(count: 200)

        controller.show(records: records, warning: nil, sourceApplication: nil)

        XCTAssertTrue(controller.isVisible)
        XCTAssertLessThan(controller.renderedRowCount, records.count)
        await waitUntil {
            controller.renderedRowCount == records.count
        }
        controller.hide()
    }

    func testClipboardPaletteStopsQueuedRowBatchesWhenHidden() async {
        let controller = ClipboardPaletteController()
        let records = paletteRecords(count: 200)

        controller.show(records: records, warning: nil, sourceApplication: nil)
        controller.hide()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertLessThan(controller.renderedRowCount, records.count)
    }

    func testWideImageAndLongMetadataCannotExpandDetailPanel() throws {
        let image = NSImage(size: NSSize(width: 4_000, height: 120))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: image.size))
        image.unlockFocus()
        let imageData = try XCTUnwrap(image.tiffRepresentation)
        let record = ClipboardHistoryRecord(
            id: UUID(),
            capturedAt: Date(),
            lastCopiedAt: Date(),
            sourceApplicationName: String(repeating: "Very Long Application Name ", count: 20),
            sourceBundleIdentifier: nil,
            kind: .image,
            summary: String(repeating: "Extra wide image description ", count: 40),
            searchableText: "",
            copyCount: 1,
            byteCount: imageData.count,
            thumbnailData: nil
        )
        let content = ClipboardHistoryPreviewContent(
            record: record,
            text: nil,
            imageData: imageData,
            filePaths: []
        )
        let sourcePanel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 450, height: 540),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let detailPanel = ClipboardInspectorPanel()

        detailPanel.present(content, beside: sourcePanel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertLessThanOrEqual(
            detailPanel.frame.width,
            ClipboardPaletteLayout.preferredDetailSize.width
        )
        XCTAssertLessThanOrEqual(
            detailPanel.frame.height,
            ClipboardPaletteLayout.preferredDetailSize.height
        )
        if let visibleFrame = detailPanel.screen?.visibleFrame {
            XCTAssertTrue(visibleFrame.contains(detailPanel.frame))
        }
        detailPanel.dismiss()
    }

    func testPreviewContentKeepsFullTextBeyondListSummary() throws {
        let fullText = String(repeating: "Complete clipboard text ", count: 30)
        let store = ClipboardHistoryStore(storeURL: nil, inMemory: true)
        let historyCandidate = try candidate(text: fullText, capturedAt: Date())
        let record = try XCTUnwrap(store.store(
            historyCandidate,
            limit: 200,
            maximumTotalBytes: 1_000_000
        ))
        let payload = try XCTUnwrap(store.payload(for: record.id))

        let preview = ClipboardHistoryCodec.previewContent(
            record: record,
            payload: payload
        )

        XCTAssertEqual(preview.text, fullText)
        XCTAssertGreaterThan(fullText.count, record.summary.count)
        XCTAssertNil(preview.imageData)
        XCTAssertTrue(preview.filePaths.isEmpty)
    }

    func testPreviewContentIncludesEverySelectedFilePath() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let paths = ["/tmp/One.txt", "/tmp/Two.md", "/tmp/Three.pdf"]
        let items = paths.map { path -> NSPasteboardItem in
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setString(
                URL(fileURLWithPath: path).absoluteString,
                forType: .fileURL
            ))
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
        let historyCandidate = try XCTUnwrap(makeCandidate(from: pasteboard))
        let store = ClipboardHistoryStore(storeURL: nil, inMemory: true)
        let record = try XCTUnwrap(store.store(
            historyCandidate,
            limit: 200,
            maximumTotalBytes: 1_000_000
        ))
        let payload = try XCTUnwrap(store.payload(for: record.id))

        let preview = ClipboardHistoryCodec.previewContent(
            record: record,
            payload: payload
        )

        XCTAssertEqual(preview.filePaths, paths)
    }

    func testOwnPasteboardWriteDoesNotCreateAnotherHistoryEntry() async throws {
        let settings = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        settings.clipboardHistoryEnabled = true
        let registry = ClipboardHistoryHotkeyRegistrySpy()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = makeService(
            settings: settings,
            registry: registry,
            pasteboard: pasteboard
        )
        service.start()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Single entry", forType: .string))

        await waitUntil {
            !service.snapshot().records.isEmpty
        }
        let firstSnapshot = service.snapshot()
        let record = try XCTUnwrap(firstSnapshot.records.first)
        XCTAssertEqual(firstSnapshot.records.count, 1)
        XCTAssertEqual(record.copyCount, 1)

        service.copy(id: record.id)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let finalSnapshot = service.snapshot()
        XCTAssertEqual(finalSnapshot.records.count, 1)
        XCTAssertEqual(finalSnapshot.records.first?.copyCount, 2)
        service.stop()
    }

    func testRegistrationConflictRollsBackEnabledSetting() {
        let settings = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        settings.clipboardHistoryEnabled = true
        let registry = ClipboardHistoryHotkeyRegistrySpy()
        registry.registrationResult = OSStatus(eventHotKeyExistsErr)
        let status = ClipboardHistoryRegistrationStatus()
        let service = makeService(settings: settings, registry: registry, status: status)

        service.start()

        XCTAssertFalse(settings.clipboardHistoryEnabled)
        XCTAssertEqual(status.warning, AppStrings.text(.clipboardShortcutConflict))
        service.stop()
    }

    func testExistingAppBindingYieldsToClipboardShortcut() {
        let settings = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        settings.appHotkeyBindings = [
            AppHotkeyBinding(
                appName: "Sample",
                bundleURLString: "file:///Applications/Sample.app",
                bundleIdentifier: "com.example.Sample",
                keyCode: ClipboardHistoryShortcut.defaultShortcut.keyCode,
                modifierFlags: ClipboardHistoryShortcut.defaultShortcut.modifierFlags
            )
        ]
        settings.clipboardHistoryEnabled = true
        let registry = ClipboardHistoryHotkeyRegistrySpy()
        let service = makeService(settings: settings, registry: registry)

        service.start()

        XCTAssertTrue(settings.clipboardHistoryEnabled)
        XCTAssertEqual(registry.registerCount, 1)
        service.stop()
    }

    private func makeService(
        settings: SettingsStore,
        registry: ClipboardHistoryHotkeyRegistrySpy,
        status: ClipboardHistoryRegistrationStatus? = nil,
        pasteboard: NSPasteboard = .general
    ) -> ClipboardHistoryService {
        ClipboardHistoryService(
            settings: settings,
            permissionService: PermissionService(),
            store: ClipboardHistoryStore(storeURL: nil, inMemory: true),
            panelController: ClipboardPaletteController(),
            registrationStatus: status ?? ClipboardHistoryRegistrationStatus(),
            hotkeyRegistry: registry,
            pasteboard: pasteboard
        )
    }

    private func storedRecord(text: String) throws -> ClipboardHistoryRecord {
        let store = ClipboardHistoryStore(storeURL: nil, inMemory: true)
        let candidate = try candidate(text: text, capturedAt: Date())
        return try XCTUnwrap(store.store(
            candidate,
            limit: 200,
            maximumTotalBytes: 1_000_000
        ))
    }

    private func paletteRecords(count: Int) -> [ClipboardHistoryRecord] {
        (0..<count).map { index in
            ClipboardHistoryRecord(
                id: UUID(),
                capturedAt: Date(),
                lastCopiedAt: Date(),
                sourceApplicationName: "Source \(index)",
                sourceBundleIdentifier: nil,
                kind: .text,
                summary: "Clipboard entry \(index)",
                searchableText: "Clipboard entry \(index)",
                copyCount: 1,
                byteCount: 32,
                thumbnailData: nil
            )
        }
    }

    private func candidate(text: String, capturedAt: Date) throws -> ClipboardHistoryCandidate {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        return try XCTUnwrap(makeCandidate(from: pasteboard, capturedAt: capturedAt))
    }

    private func makeCandidate(
        from pasteboard: NSPasteboard,
        capturedAt: Date = Date()
    ) -> ClipboardHistoryCandidate? {
        ClipboardHistoryCodec.candidate(
            from: pasteboard,
            sourceApplication: nil,
            capturedAt: capturedAt,
            maximumPayloadBytes: ClipboardHistoryService.maximumEntryBytes
        )
    }

    private func makeStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniDockClipboardCrypto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // Scans the SQLite file, its journal siblings, and any externally stored
    // blob for the clipboard text, which is where plaintext used to survive.
    private func directoryContainsPlaintext(
        _ directory: URL,
        needle: String
    ) throws -> Bool {
        let needleData = Data(needle.utf8)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ))
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let contents = try? Data(contentsOf: url)
            else {
                continue
            }
            if contents.range(of: needleData) != nil {
                return true
            }
        }
        return false
    }

    // Reproduces the plaintext schema a build without encryption wrote, so the
    // discard path is exercised against a real incompatible file.
    private func writeLegacySchemaEntry(text: String, to storeURL: URL) throws {
        let entity = NSEntityDescription()
        entity.name = "ClipboardHistoryEntry"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            legacyAttribute("id", type: .UUIDAttributeType, optional: false),
            legacyAttribute("capturedAt", type: .dateAttributeType, optional: false),
            legacyAttribute("summary", type: .stringAttributeType, optional: false),
            legacyAttribute("payloadData", type: .binaryDataAttributeType, optional: false)
        ]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        model.versionIdentifiers = ["1"]

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: nil
        )
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        let object = NSEntityDescription.insertNewObject(
            forEntityName: "ClipboardHistoryEntry",
            into: context
        )
        object.setValue(UUID(), forKey: "id")
        object.setValue(Date(), forKey: "capturedAt")
        object.setValue(text, forKey: "summary")
        object.setValue(Data(text.utf8), forKey: "payloadData")
        try context.save()

        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    private func legacyAttribute(
        _ name: String,
        type: NSAttributeType,
        optional: Bool
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }

    private func posixPermissions(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.uint16Value)
    }

    private func autoPasteStep(
        frontmost: pid_t?,
        now: Date,
        deadline: Date,
        isTargetTerminated: Bool = false,
        isSecureInputEnabled: Bool = false
    ) -> ClipboardAutoPasteStep {
        ClipboardAutoPastePolicy.step(
            frontmostProcessIdentifier: frontmost,
            targetProcessIdentifier: 7,
            isTargetTerminated: isTargetTerminated,
            isSecureInputEnabled: isSecureInputEnabled,
            now: now,
            deadline: deadline
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "OmniDockClipboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<60 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    private func tinyPNGData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func descendantTextFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in
            let current = (subview as? NSTextField).map { [$0] } ?? []
            return current + descendantTextFields(in: subview)
        }
    }

    private func descendantImageViews(in view: NSView) -> [NSImageView] {
        view.subviews.flatMap { subview in
            let current = (subview as? NSImageView).map { [$0] } ?? []
            return current + descendantImageViews(in: subview)
        }
    }
}

private struct FailingClipboardKeyStore: ClipboardHistoryKeyStoring {
    var error: ClipboardHistoryKeyError = .storageUnavailable(EACCES)

    func loadOrCreateKey() throws -> SymmetricKey {
        throw error
    }
}

private final class ClipboardHistoryKeyStoreSpy: ClipboardHistoryKeyStoring {
    private let failure: ClipboardHistoryKeyError?
    private(set) var loadCount = 0

    init(failure: ClipboardHistoryKeyError? = nil) {
        self.failure = failure
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        loadCount += 1
        if let failure {
            throw failure
        }
        return SymmetricKey(size: .bits256)
    }
}

@MainActor
private final class ClipboardHistoryHotkeyRegistrySpy: ClipboardHistoryHotkeyRegistering {
    var onTrigger: (() -> Void)?
    var registrationResult: OSStatus?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var stopCount = 0

    func register(_ shortcut: RecordedShortcut) -> OSStatus? {
        registerCount += 1
        return registrationResult
    }

    func unregister() {
        unregisterCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func trigger() {
        onTrigger?()
    }
}
