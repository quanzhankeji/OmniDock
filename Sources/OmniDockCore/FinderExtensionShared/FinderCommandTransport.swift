import Foundation
import Darwin

enum BlankDocumentFactory {
    static func create(
        in directory: URL,
        fileExtension: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let fileExtension = FinderDocumentPreset.normalizedFileExtension(fileExtension) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        for sequence in 1...10_000 {
            let suffix = sequence == 1 ? "" : " \(sequence)"
            let fileName = "NewFile\(suffix).\(fileExtension)"
            let destination = directory.appendingPathComponent(fileName, isDirectory: false)

            do {
                try Data().write(to: destination, options: .withoutOverwriting)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }

        throw CocoaError(.fileWriteUnknown)
    }
}

enum FinderCommand: Codable, Equatable {
    case createDocument(
        fileExtension: String,
        directoryDisplayPath: String
    )
    case setHiddenFilesVisible(Bool)
    case openDirectory(
        shortcut: FinderLaunchShortcut,
        directoryDisplayPath: String
    )
}

struct FinderCommandEnvelope: Codable, Equatable, Identifiable {
    let id: UUID
    let command: FinderCommand
    let createdAt: Date

    init(
        id: UUID = UUID(),
        command: FinderCommand,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.command = command
        self.createdAt = createdAt
    }
}

final class FinderCommandMailbox {
    private static let directoryName = "FinderExtensionCommands"
    private static let requestLifetime: TimeInterval = 300
    private static let maximumRequestBytes = 64 * 1_024

    private let directoryProvider: () -> URL?
    private let fileManager: FileManager

    convenience init() {
        self.init(
            directoryProvider: {
                guard let identifier = FinderMenuPreferencesStore.appGroupIdentifier else {
                    return nil
                }
                return FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: identifier
                )
            }
        )
    }

    init(directoryProvider: @escaping () -> URL?, fileManager: FileManager = .default) {
        self.directoryProvider = directoryProvider
        self.fileManager = fileManager
    }

    func enqueue(_ request: FinderCommandEnvelope) throws {
        let directory = try requestDirectory()
        removeExpiredRequests(in: directory)
        let data = try JSONEncoder().encode(request)
        guard data.count <= Self.maximumRequestBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let url = fileURL(for: request.id, in: directory)
        try data.write(to: url, options: .withoutOverwriting)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    func take(id: UUID) -> FinderCommandEnvelope? {
        guard let directory = try? requestDirectory() else {
            return nil
        }

        let url = fileURL(for: id, in: directory)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        defer { try? fileManager.removeItem(at: url) }
        guard let request = validatedRequest(at: url, expectedID: id) else {
            return nil
        }
        return request
    }

    func discard(id: UUID) {
        guard let directory = try? requestDirectory() else {
            return
        }
        try? fileManager.removeItem(at: fileURL(for: id, in: directory))
    }

    private func requestDirectory() throws -> URL {
        guard let root = directoryProvider() else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = root.appendingPathComponent(Self.directoryName, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension("json")
    }

    private func removeExpiredRequests(in directory: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in contents {
            guard url.pathExtension == "json" else {
                continue
            }
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            guard let id,
                  let request = validatedRequest(at: url, expectedID: id),
                  isFresh(request, now: Date())
            else {
                try? fileManager.removeItem(at: url)
                continue
            }
        }
    }

    private func validatedRequest(
        at url: URL,
        expectedID: UUID
    ) -> FinderCommandEnvelope? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o077 == 0,
              let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              byteCount > 0,
              byteCount <= Self.maximumRequestBytes,
              let data = try? Data(contentsOf: url),
              data.count == byteCount,
              let request = try? JSONDecoder().decode(FinderCommandEnvelope.self, from: data),
              request.id == expectedID,
              isFresh(request, now: Date())
        else {
            return nil
        }
        return request
    }

    private func isFresh(_ request: FinderCommandEnvelope, now: Date) -> Bool {
        let age = now.timeIntervalSince(request.createdAt)
        return age >= -30 && age <= Self.requestLifetime
    }
}

enum FinderCommandSignal {
    static let notificationName = Notification.Name(
        "com.quanzhankeji.OmniDock.finderCommandPending"
    )

    static func post(
        requestID: UUID,
        center: DistributedNotificationCenter = DistributedNotificationCenter.default()
    ) {
        center.postNotificationName(
            notificationName,
            object: requestID.uuidString,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func requestID(from notification: Notification) -> UUID? {
        guard notification.name == notificationName,
              let value = notification.object as? String
        else {
            return nil
        }
        return UUID(uuidString: value)
    }
}

enum FinderActionRoute {
    static let scheme = "omnidock"
    private static let host = "finder-command"

    static func url(for requestID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "id", value: requestID.uuidString)]
        return components.url!
    }

    static func requestID(from url: URL) -> UUID? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame,
              url.host?.caseInsensitiveCompare(host) == .orderedSame,
              let identifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "id" })?
                .value
        else {
            return nil
        }
        return UUID(uuidString: identifier)
    }
}
