import CoreData
import Foundation

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
    private enum Field {
        static let id = "id"
        static let capturedAt = "capturedAt"
        static let lastCopiedAt = "lastCopiedAt"
        static let sourceApplicationName = "sourceApplicationName"
        static let sourceBundleIdentifier = "sourceBundleIdentifier"
        static let kind = "kind"
        static let summary = "summary"
        static let searchableText = "searchableText"
        static let fingerprint = "fingerprint"
        static let payloadData = "payloadData"
        static let thumbnailData = "thumbnailData"
        static let copyCount = "copyCount"
        static let byteCount = "byteCount"
    }

    private static let entityName = "ClipboardHistoryEntry"

    private let context: NSManagedObjectContext
    private(set) var warning: String?

    convenience init() {
        self.init(storeURL: Self.defaultStoreURL(), inMemory: false)
    }

    init(storeURL: URL?, inMemory: Bool) {
        let model = Self.makeModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.undoManager = nil
        self.context = context

        do {
            if inMemory {
                try coordinator.addPersistentStore(
                    ofType: NSInMemoryStoreType,
                    configurationName: nil,
                    at: nil
                )
            } else if let storeURL {
                try FileManager.default.createDirectory(
                    at: storeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try coordinator.addPersistentStore(
                    ofType: NSSQLiteStoreType,
                    configurationName: nil,
                    at: storeURL,
                    options: [
                        NSMigratePersistentStoresAutomaticallyOption: true,
                        NSInferMappingModelAutomaticallyOption: true
                    ]
                )
            }
        } catch {
            warning = AppStrings.text(.clipboardStorageUnavailable)
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
    }

    func records() -> [ClipboardHistoryRecord] {
        fetchObjects().compactMap(record(from:))
    }

    func payload(for id: UUID) -> ClipboardPayload? {
        guard let object = fetchObject(id: id),
              let data = object.value(forKey: Field.payloadData) as? Data
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
        let existingObject = fetchObject(fingerprint: candidate.fingerprint)
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
        object.setValue(candidate.sourceApplicationName, forKey: Field.sourceApplicationName)
        object.setValue(candidate.sourceBundleIdentifier, forKey: Field.sourceBundleIdentifier)
        object.setValue(candidate.kind.rawValue, forKey: Field.kind)
        object.setValue(candidate.summary, forKey: Field.summary)
        object.setValue(candidate.searchableText, forKey: Field.searchableText)
        object.setValue(candidate.fingerprint, forKey: Field.fingerprint)
        object.setValue(candidate.payloadData, forKey: Field.payloadData)
        object.setValue(candidate.thumbnailData, forKey: Field.thumbnailData)
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
        fetchObjects().forEach(context.delete)
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
        let boundedLimit = max(1, limit)
        var retainedBytes = 0
        for (index, object) in fetchObjects().enumerated() {
            let bytes = Int(object.value(forKey: Field.byteCount) as? Int64 ?? 0)
            if index >= boundedLimit || retainedBytes + bytes > maximumTotalBytes {
                context.delete(object)
            } else {
                retainedBytes += bytes
            }
        }
        save()
    }

    private func fetchObjects() -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.entityName)
        request.sortDescriptors = [
            NSSortDescriptor(key: Field.lastCopiedAt, ascending: false)
        ]
        return (try? context.fetch(request)) ?? []
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
        } catch {
            warning = AppStrings.text(.clipboardStorageUnavailable)
            context.rollback()
        }
    }

    private func record(from object: NSManagedObject) -> ClipboardHistoryRecord? {
        guard let id = object.value(forKey: Field.id) as? UUID,
              let capturedAt = object.value(forKey: Field.capturedAt) as? Date,
              let lastCopiedAt = object.value(forKey: Field.lastCopiedAt) as? Date,
              let sourceApplicationName = object.value(forKey: Field.sourceApplicationName) as? String,
              let kindValue = object.value(forKey: Field.kind) as? String,
              let kind = ClipboardContentKind(rawValue: kindValue),
              let summary = object.value(forKey: Field.summary) as? String,
              let searchableText = object.value(forKey: Field.searchableText) as? String
        else {
            return nil
        }

        return ClipboardHistoryRecord(
            id: id,
            capturedAt: capturedAt,
            lastCopiedAt: lastCopiedAt,
            sourceApplicationName: sourceApplicationName,
            sourceBundleIdentifier: object.value(forKey: Field.sourceBundleIdentifier) as? String,
            kind: kind,
            summary: summary,
            searchableText: searchableText,
            copyCount: Int(object.value(forKey: Field.copyCount) as? Int64 ?? 1),
            byteCount: Int(object.value(forKey: Field.byteCount) as? Int64 ?? 0),
            thumbnailData: object.value(forKey: Field.thumbnailData) as? Data
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

    private static func makeModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = entityName
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        let id = attribute(Field.id, type: .UUIDAttributeType, optional: false)
        let capturedAt = attribute(Field.capturedAt, type: .dateAttributeType, optional: false)
        let lastCopiedAt = attribute(Field.lastCopiedAt, type: .dateAttributeType, optional: false)
        let sourceName = attribute(
            Field.sourceApplicationName,
            type: .stringAttributeType,
            optional: false
        )
        let sourceBundle = attribute(
            Field.sourceBundleIdentifier,
            type: .stringAttributeType,
            optional: true
        )
        let kind = attribute(Field.kind, type: .stringAttributeType, optional: false)
        let summary = attribute(Field.summary, type: .stringAttributeType, optional: false)
        let searchableText = attribute(
            Field.searchableText,
            type: .stringAttributeType,
            optional: false
        )
        let fingerprint = attribute(Field.fingerprint, type: .stringAttributeType, optional: false)
        let payload = attribute(Field.payloadData, type: .binaryDataAttributeType, optional: false)
        payload.allowsExternalBinaryDataStorage = true
        let thumbnail = attribute(
            Field.thumbnailData,
            type: .binaryDataAttributeType,
            optional: true
        )
        thumbnail.allowsExternalBinaryDataStorage = true
        let copyCount = attribute(Field.copyCount, type: .integer64AttributeType, optional: false)
        copyCount.defaultValue = 1
        let byteCount = attribute(Field.byteCount, type: .integer64AttributeType, optional: false)
        byteCount.defaultValue = 0

        entity.properties = [
            id,
            capturedAt,
            lastCopiedAt,
            sourceName,
            sourceBundle,
            kind,
            summary,
            searchableText,
            fingerprint,
            payload,
            thumbnail,
            copyCount,
            byteCount
        ]
        entity.uniquenessConstraints = [[Field.fingerprint]]

        let model = NSManagedObjectModel()
        model.entities = [entity]
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
