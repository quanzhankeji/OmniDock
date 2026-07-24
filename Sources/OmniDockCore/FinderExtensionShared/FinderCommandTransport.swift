import Foundation

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
    case openSelection(
        shortcut: FinderLaunchShortcut,
        selectedDisplayPaths: [String]
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
        try data.write(to: fileURL(for: request.id, in: directory), options: .withoutOverwriting)
    }

    func take(id: UUID) -> FinderCommandEnvelope? {
        guard let directory = try? requestDirectory() else {
            return nil
        }

        let url = fileURL(for: id, in: directory)
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode(FinderCommandEnvelope.self, from: data)
        else {
            return nil
        }

        try? fileManager.removeItem(at: url)
        guard request.createdAt.addingTimeInterval(Self.requestLifetime) > Date() else {
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
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
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
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(FinderCommandEnvelope.self, from: data),
                  request.createdAt.addingTimeInterval(Self.requestLifetime) <= Date()
            else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
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
