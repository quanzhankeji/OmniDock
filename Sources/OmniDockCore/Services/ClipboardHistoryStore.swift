import CoreData
import Darwin
import Foundation
import os.log

enum ClipboardStoreFileProtection {
    static func prepareDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try? (directory as NSURL).setResourceValue(
            FileProtectionType.complete,
            forKey: .fileProtectionKey
        )
    }

    static func secureStoreFiles(
        storeURL: URL,
        fileManager: FileManager = .default
    ) {
        let directory = storeURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: nil
        ) else {
            return
        }

        let directoryPrefix = directory.path.hasSuffix("/")
            ? directory.path
            : directory.path + "/"
        let storePrefixes = securedPathPrefixes(for: storeURL)
        for case let url as URL in enumerator {
            // The enumerator reports symlink-resolved paths ("/private/var"
            // for a store under "/var"), so both sides are resolved before the
            // store directory is trimmed off. Comparing unresolved paths
            // silently mismatches and skips every file.
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedURL.path.hasPrefix(directoryPrefix) else {
                continue
            }
            let relativePath = resolvedURL.path.dropFirst(directoryPrefix.count)
            guard storePrefixes.contains(where: relativePath.hasPrefix) else {
                continue
            }
            let isDirectory = (try? resolvedURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true
            let permissions = isDirectory ? 0o700 : 0o600
            try? (resolvedURL as NSURL).setResourceValue(
                FileProtectionType.complete,
                forKey: .fileProtectionKey
            )
            try? fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: resolvedURL.path
            )
            resolvedURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                _ = chmod(path, mode_t(permissions))
            }
        }
    }

    // The SQLite file and its -wal/-shm siblings all start with the store file
    // name, but Core Data keeps blobs promoted out of the row (any clipboard
    // image or large text, because payloadData allows external storage) in a
    // sibling ".<store name without extension>_SUPPORT" directory. Those files
    // are created with the default umask, so they must be listed here or the
    // largest clipboard entries stay group- and world-readable.
    static func securedPathPrefixes(for storeURL: URL) -> [String] {
        let fileName = storeURL.lastPathComponent
        let baseName = storeURL.deletingPathExtension().lastPathComponent
        return [
            fileName,
            ".\(baseName)_SUPPORT",
            ".\(fileName)_SUPPORT"
        ]
    }
}

protocol ClipboardHistoryPersisting: AnyObject {
    var warning: String? { get }
    func records() -> [ClipboardHistoryRecord]
    func payload(for id: UUID) -> ClipboardPayload?
    @discardableResult
    func store(
        _ candidate: ClipboardHistoryCandidate,
        limit: Int,
        maximumTotalBytes: Int
    ) -> ClipboardHistoryRecord?
    func delete(id: UUID)
    func removeAll()
    func markCopied(id: UUID, at date: Date)
    func prune(limit: Int, maximumTotalBytes: Int)
}


final class ClipboardHistoryStore: ClipboardHistoryPersisting {
    private static let log = OSLog(
        subsystem: "com.quanzhankeji.OmniDock",
        category: "ClipboardHistory"
    )

    // Only structural columns stay readable. They order, deduplicate, and prune
    // the archive without revealing anything about what was copied; everything
    // carrying content or provenance is stored as an AES-GCM box.
    private enum Field {
        static let id = "id"
        static let capturedAt = "capturedAt"
        static let lastCopiedAt = "lastCopiedAt"
        static let kind = "kind"
        static let copyCount = "copyCount"
        static let byteCount = "byteCount"
        static let fingerprint = "fingerprint"
        static let sealedSummary = "sealedSummary"
        static let sealedSearchableText = "sealedSearchableText"
        static let sealedSourceName = "sealedSourceName"
        static let sealedSourceBundleIdentifier = "sealedSourceBundleIdentifier"
        static let sealedPayload = "sealedPayload"
        static let sealedThumbnail = "sealedThumbnail"
    }

    private static let entityName = "ClipboardHistoryEntry"

    // Bump this whenever the layout changes. Clipboard history is a
    // convenience cache, not a document, so an incompatible or unreadable file
    // is discarded and rebuilt instead of migrated: there is no migration code
    // to go wrong, and a schema change can never strand someone's install.
    private static let schemaVersion = "2-local"

    private static let storeOptions: [String: Any] = [
        // Zero freed cells instead of leaving them in the file, so a pruned or
        // deleted entry does not linger in the store's free pages.
        NSSQLitePragmasOption: ["secure_delete": "TRUE"]
    ]

    private let context: NSManagedObjectContext
    private let storeURL: URL?
    private let cipher: ClipboardHistoryCipher
    private(set) var warning: String?

    convenience init() {
        self.init(storeURL: Self.defaultStoreURL(), inMemory: false)
    }

    init(
        storeURL: URL?,
        inMemory: Bool,
        cipher: ClipboardHistoryCipher? = nil,
        keyStore: ClipboardHistoryKeyStoring = ClipboardHistoryLocalKeyStore()
    ) {
        let coordinator = NSPersistentStoreCoordinator(
            managedObjectModel: Self.makeModel()
        )
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.undoManager = nil
        self.context = context

        // Without a key there is no safe way to persist: writing plaintext
        // instead would quietly hand back the exposure encryption is here to
        // remove. The archive then stays in memory for the session, and the
        // file on disk is left untouched for a later launch that can read it.
        var keyWarning: String?
        var resolvedCipher = cipher
        if resolvedCipher == nil {
            if inMemory {
                resolvedCipher = .ephemeral()
            } else {
                do {
                    resolvedCipher = ClipboardHistoryCipher(
                        key: try keyStore.loadOrCreateKey()
                    )
                } catch let error as ClipboardHistoryKeyError {
                    resolvedCipher = .ephemeral()
                    switch error {
                    case let .storageUnavailable(code):
                        os_log(
                            "Clipboard history is memory-only because its key file is unavailable (errno %{public}d).",
                            log: Self.log,
                            type: .error,
                            code
                        )
                    case .malformedKey:
                        os_log(
                            "Clipboard history key file is malformed.",
                            log: Self.log,
                            type: .error
                        )
                    }
                    keyWarning = AppStrings.text(.clipboardStorageUnavailable)
                } catch {
                    os_log(
                        "Clipboard history key loading failed unexpectedly.",
                        log: Self.log,
                        type: .error
                    )
                    resolvedCipher = .ephemeral()
                    keyWarning = AppStrings.text(.clipboardStorageUnavailable)
                }
            }
        }
        self.cipher = resolvedCipher ?? .ephemeral()
        var resolvedStoreURL = (inMemory || keyWarning != nil) ? nil : storeURL

        do {
            if let resolvedStoreURL {
                try Self.openStore(coordinator: coordinator, at: resolvedStoreURL)
                ClipboardStoreFileProtection.secureStoreFiles(storeURL: resolvedStoreURL)
            } else {
                try coordinator.addPersistentStore(
                    ofType: NSInMemoryStoreType,
                    configurationName: nil,
                    at: nil
                )
            }
        } catch {
            keyWarning = AppStrings.text(.clipboardStorageUnavailable)
            resolvedStoreURL = nil
            do {
                try coordinator.addPersistentStore(
                    ofType: NSInMemoryStoreType,
                    configurationName: nil,
                    at: nil
                )
            } catch {
                NSLog("OmniDock clipboard history store failed: \(error.localizedDescription)")
            }
        }
        self.storeURL = resolvedStoreURL
        warning = keyWarning
    }

    func records() -> [ClipboardHistoryRecord] {
        // Dictionary fetches read only the listed attributes straight from the
        // store. This deliberately excludes the payload, which can be tens of
        // megabytes per row and would otherwise be faulted in for every record
        // on every refresh even though the list UI never needs it.
        //
        // Invariant: dictionary fetches do not see unsaved pending changes, so
        // every mutation in this class must save() before returning (they all
        // do). Keep that in mind when adding new mutation paths.
        let request = NSFetchRequest<NSDictionary>(entityName: Self.entityName)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = [
            Field.id,
            Field.capturedAt,
            Field.lastCopiedAt,
            Field.kind,
            Field.copyCount,
            Field.byteCount,
            Field.sealedSummary,
            Field.sealedSearchableText,
            Field.sealedSourceName,
            Field.sealedSourceBundleIdentifier,
            Field.sealedThumbnail
        ]
        request.sortDescriptors = [
            NSSortDescriptor(key: Field.lastCopiedAt, ascending: false)
        ]
        let rows = (try? context.fetch(request)) ?? []
        return rows.compactMap { row in
            record { row.value(forKey: $0) }
        }
    }

    func payload(for id: UUID) -> ClipboardPayload? {
        guard let object = fetchObject(id: id),
              let sealed = object.value(forKey: Field.sealedPayload) as? Data,
              let data = cipher.open(sealed)
        else {
            return nil
        }
        return ClipboardHistoryCodec.decode(data)
    }

    @discardableResult
    func store(
        _ candidate: ClipboardHistoryCandidate,
        limit: Int,
        maximumTotalBytes: Int
    ) -> ClipboardHistoryRecord? {
        guard let sealedSummary = cipher.seal(text: candidate.summary),
              let sealedSearchableText = cipher.seal(text: candidate.searchableText),
              let sealedSourceName = cipher.seal(text: candidate.sourceApplicationName),
              let sealedPayload = cipher.seal(candidate.payloadData)
        else {
            warning = AppStrings.text(.clipboardStorageUnavailable)
            return nil
        }
        let sealedThumbnail = candidate.thumbnailData.flatMap(cipher.seal)
        let sealedSourceBundleIdentifier = candidate.sourceBundleIdentifier
            .flatMap(cipher.seal(text:))
        let fingerprint = cipher.blindIndex(for: candidate.fingerprint)

        let existingObject = fetchObject(fingerprint: fingerprint)
        let object = existingObject
            ?? NSEntityDescription.insertNewObject(
                forEntityName: Self.entityName,
                into: context
            )
        let existingCopyCount = existingObject?.value(forKey: Field.copyCount) as? Int64 ?? 0
        let existingCapturedAt = object.value(forKey: Field.capturedAt) as? Date

        object.setValue(
            (object.value(forKey: Field.id) as? UUID) ?? candidate.id,
            forKey: Field.id
        )
        object.setValue(existingCapturedAt ?? candidate.capturedAt, forKey: Field.capturedAt)
        object.setValue(candidate.capturedAt, forKey: Field.lastCopiedAt)
        object.setValue(candidate.kind.rawValue, forKey: Field.kind)
        object.setValue(fingerprint, forKey: Field.fingerprint)
        object.setValue(sealedSummary, forKey: Field.sealedSummary)
        object.setValue(sealedSearchableText, forKey: Field.sealedSearchableText)
        object.setValue(sealedSourceName, forKey: Field.sealedSourceName)
        object.setValue(
            sealedSourceBundleIdentifier,
            forKey: Field.sealedSourceBundleIdentifier
        )
        object.setValue(sealedPayload, forKey: Field.sealedPayload)
        object.setValue(sealedThumbnail, forKey: Field.sealedThumbnail)
        object.setValue(max(existingCopyCount + 1, 1), forKey: Field.copyCount)
        object.setValue(Int64(candidate.byteCount), forKey: Field.byteCount)

        save()
        prune(limit: limit, maximumTotalBytes: maximumTotalBytes)
        guard let id = object.value(forKey: Field.id) as? UUID else {
            return nil
        }
        return fetchObject(id: id).flatMap(record(from:))
    }

    func delete(id: UUID) {
        guard let object = fetchObject(id: id) else {
            return
        }
        context.delete(object)
        save()
    }

    func removeAll() {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        // Deleting does not need attribute values; skip faulting payload blobs.
        request.includesPropertyValues = false
        ((try? context.fetch(request)) ?? []).forEach(context.delete)
        save()
    }

    func markCopied(id: UUID, at date: Date) {
        guard let object = fetchObject(id: id) else {
            return
        }
        let copyCount = object.value(forKey: Field.copyCount) as? Int64 ?? 1
        object.setValue(date, forKey: Field.lastCopiedAt)
        object.setValue(copyCount + 1, forKey: Field.copyCount)
        save()
    }

    func prune(limit: Int, maximumTotalBytes: Int) {
        // Read only id and byteCount to decide what expires, so pruning never
        // faults full rows (and their payload blobs) into memory.
        let request = NSFetchRequest<NSDictionary>(entityName: Self.entityName)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = [Field.id, Field.byteCount]
        request.sortDescriptors = [
            NSSortDescriptor(key: Field.lastCopiedAt, ascending: false)
        ]
        let rows = (try? context.fetch(request)) ?? []

        let boundedLimit = max(1, limit)
        var retainedBytes = 0
        var expiredIDs: [UUID] = []
        for (index, row) in rows.enumerated() {
            guard let id = row.value(forKey: Field.id) as? UUID else {
                continue
            }
            let bytes = Int(row.value(forKey: Field.byteCount) as? Int64 ?? 0)
            if index >= boundedLimit || retainedBytes + bytes > maximumTotalBytes {
                expiredIDs.append(id)
            } else {
                retainedBytes += bytes
            }
        }
        guard !expiredIDs.isEmpty else {
            return
        }

        let deleteRequest = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        deleteRequest.predicate = NSPredicate(format: "%K IN %@", Field.id, expiredIDs)
        deleteRequest.includesPropertyValues = false
        ((try? context.fetch(deleteRequest)) ?? []).forEach(context.delete)
        save()
    }

    // A file written by a different schema, or one that cannot be opened at
    // all, is thrown away and recreated. Losing a clipboard cache is a far
    // better outcome than a migration that half-succeeds, and it keeps future
    // schema changes free of per-version upgrade code.
    private static func openStore(
        coordinator: NSPersistentStoreCoordinator,
        at storeURL: URL
    ) throws {
        try ClipboardStoreFileProtection.prepareDirectory(
            storeURL.deletingLastPathComponent()
        )
        if !isCompatible(storeURL: storeURL, coordinator: coordinator) {
            discardStore(at: storeURL, coordinator: coordinator)
        }
        do {
            try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: storeOptions
            )
        } catch {
            NSLog("OmniDock clipboard history archive is unusable, rebuilding: \(error)")
            discardStore(at: storeURL, coordinator: coordinator)
            try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: storeOptions
            )
        }
    }

    private static func isCompatible(
        storeURL: URL,
        coordinator: NSPersistentStoreCoordinator
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return true
        }
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL
        ) else {
            return false
        }
        guard let versions = metadata[NSStoreModelVersionIdentifiersKey] as? [Any],
              versions.map({ "\($0)" }) == [schemaVersion]
        else {
            return false
        }
        return coordinator.managedObjectModel.isConfiguration(
            withName: nil,
            compatibleWithStoreMetadata: metadata
        )
    }

    private static func discardStore(
        at storeURL: URL,
        coordinator: NSPersistentStoreCoordinator
    ) {
        try? coordinator.destroyPersistentStore(
            at: storeURL,
            ofType: NSSQLiteStoreType,
            options: storeOptions
        )
        // destroyPersistentStore does not always take the journal siblings or
        // the external blob directory with it, and leaving those behind would
        // reattach stale content to a fresh archive.
        let directory = storeURL.deletingLastPathComponent()
        let prefixes = ClipboardStoreFileProtection.securedPathPrefixes(for: storeURL)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where prefixes.contains(where: url.lastPathComponent.hasPrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fetchObject(id: UUID) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.predicate = NSPredicate(format: "%K == %@", Field.id, id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func fetchObject(fingerprint: String) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.predicate = NSPredicate(format: "%K == %@", Field.fingerprint, fingerprint)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func save() {
        guard context.hasChanges else {
            return
        }
        do {
            try context.save()
            if let storeURL {
                ClipboardStoreFileProtection.secureStoreFiles(storeURL: storeURL)
            }
        } catch {
            warning = AppStrings.text(.clipboardStorageUnavailable)
            context.rollback()
        }
    }

    private func record(from object: NSManagedObject) -> ClipboardHistoryRecord? {
        record { object.value(forKey: $0) }
    }

    // An entry that will not open was sealed with a key this install no longer
    // has, so it is skipped rather than shown as a blank row.
    private func record(fieldValue: (String) -> Any?) -> ClipboardHistoryRecord? {
        guard let id = fieldValue(Field.id) as? UUID,
              let capturedAt = fieldValue(Field.capturedAt) as? Date,
              let lastCopiedAt = fieldValue(Field.lastCopiedAt) as? Date,
              let kindValue = fieldValue(Field.kind) as? String,
              let kind = ClipboardContentKind(rawValue: kindValue),
              let sealedSummary = fieldValue(Field.sealedSummary) as? Data,
              let summary = cipher.openText(sealedSummary),
              let sealedSearchableText = fieldValue(Field.sealedSearchableText) as? Data,
              let searchableText = cipher.openText(sealedSearchableText),
              let sealedSourceName = fieldValue(Field.sealedSourceName) as? Data,
              let sourceApplicationName = cipher.openText(sealedSourceName)
        else {
            return nil
        }

        return ClipboardHistoryRecord(
            id: id,
            capturedAt: capturedAt,
            lastCopiedAt: lastCopiedAt,
            sourceApplicationName: sourceApplicationName,
            sourceBundleIdentifier: (
                fieldValue(Field.sealedSourceBundleIdentifier) as? Data
            ).flatMap(cipher.openText),
            kind: kind,
            summary: summary,
            searchableText: searchableText,
            copyCount: Int(fieldValue(Field.copyCount) as? Int64 ?? 1),
            byteCount: Int(fieldValue(Field.byteCount) as? Int64 ?? 0),
            thumbnailData: (fieldValue(Field.sealedThumbnail) as? Data).flatMap(cipher.open)
        )
    }

    private static func defaultStoreURL() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("OmniDock", isDirectory: true)
            .appendingPathComponent("ClipboardHistory.sqlite", isDirectory: false)
    }

    static func makeModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = entityName
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        let id = attribute(Field.id, type: .UUIDAttributeType, optional: false)
        let capturedAt = attribute(Field.capturedAt, type: .dateAttributeType, optional: false)
        let lastCopiedAt = attribute(Field.lastCopiedAt, type: .dateAttributeType, optional: false)
        let kind = attribute(Field.kind, type: .stringAttributeType, optional: false)
        let copyCount = attribute(Field.copyCount, type: .integer64AttributeType, optional: false)
        copyCount.defaultValue = 1
        let byteCount = attribute(Field.byteCount, type: .integer64AttributeType, optional: false)
        byteCount.defaultValue = 0
        let fingerprint = attribute(Field.fingerprint, type: .stringAttributeType, optional: false)

        let sealedSummary = attribute(
            Field.sealedSummary,
            type: .binaryDataAttributeType,
            optional: false
        )
        let sealedSearchableText = attribute(
            Field.sealedSearchableText,
            type: .binaryDataAttributeType,
            optional: false
        )
        let sealedSourceName = attribute(
            Field.sealedSourceName,
            type: .binaryDataAttributeType,
            optional: false
        )
        let sealedSourceBundleIdentifier = attribute(
            Field.sealedSourceBundleIdentifier,
            type: .binaryDataAttributeType,
            optional: true
        )
        let sealedPayload = attribute(
            Field.sealedPayload,
            type: .binaryDataAttributeType,
            optional: false
        )
        sealedPayload.allowsExternalBinaryDataStorage = true
        let sealedThumbnail = attribute(
            Field.sealedThumbnail,
            type: .binaryDataAttributeType,
            optional: true
        )
        sealedThumbnail.allowsExternalBinaryDataStorage = true

        entity.properties = [
            id,
            capturedAt,
            lastCopiedAt,
            kind,
            copyCount,
            byteCount,
            fingerprint,
            sealedSummary,
            sealedSearchableText,
            sealedSourceName,
            sealedSourceBundleIdentifier,
            sealedPayload,
            sealedThumbnail
        ]
        // The fingerprint is a keyed index over the payload, so identical
        // content collapses onto one row without the column revealing content.
        entity.uniquenessConstraints = [[Field.fingerprint]]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        model.versionIdentifiers = [schemaVersion]
        return model
    }

    private static func attribute(
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
}
