import Foundation

final class FinderDirectoryGrantStore {
    private struct BookmarkRecord: Codable {
        let path: String
        let bookmark: Data
    }

    private enum Key {
        static let bookmarks = "finderExtensionDirectoryBookmarks"
    }

    private let defaults: UserDefaults
    private let observationRootUpdater: ([String]) -> Void
    private let now: () -> Date
    private let cacheLock = NSLock()
    private var cachedUsability: (value: Bool, capturedAt: Date)?
    private static let usabilityCacheLifetime: TimeInterval = 10

    convenience init() {
        let preferencesStore = FinderMenuPreferencesStore()
        self.init(
            defaults: .standard,
            observationRootUpdater: { paths in
                preferencesStore.updateObservationRootPaths(paths)
            }
        )
    }

    init(
        defaults: UserDefaults,
        observationRootUpdater: @escaping ([String]) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.observationRootUpdater = observationRootUpdater
        self.now = now
    }

    func performWithSavedAccess<T>(
        to targetDirectory: URL,
        operation: (URL) throws -> T
    ) throws -> T? {
        let target = targetDirectory.standardizedFileURL
        var records = savedRecords()
        var changed = false

        for index in records.indices.reversed() {
            let record = records[index]
            let recordedURL = URL(fileURLWithPath: record.path, isDirectory: true)
            guard Self.contains(target, in: recordedURL) else {
                continue
            }

            let authorizedURL: URL
            let isStale: Bool
            do {
                var resolvedBookmarkIsStale = false
                authorizedURL = try URL(
                    resolvingBookmarkData: record.bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &resolvedBookmarkIsStale
                )
                isStale = resolvedBookmarkIsStale
            } catch {
                records.remove(at: index)
                changed = true
                continue
            }

            guard Self.contains(target, in: authorizedURL) else {
                records.remove(at: index)
                changed = true
                continue
            }
            let didStartAccess = authorizedURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    authorizedURL.stopAccessingSecurityScopedResource()
                }
            }

            if isStale {
                do {
                    records[index] = try bookmarkRecord(for: authorizedURL)
                    changed = true
                } catch {
                    records.remove(at: index)
                    changed = true
                    continue
                }
            }
            if changed {
                save(records)
            }
            return try operation(target)
        }

        if changed {
            save(records)
        }
        return nil
    }

    // Authorization is derived from the bookmarks the user actually granted
    // through the open panel. The mirrored path list in the shared app-group
    // defaults exists so the Finder extension can register its observation
    // roots, and any process running as this user can write to it; a
    // security-scoped bookmark cannot be forged the same way.
    func authorizedDirectoryPaths() -> [String] {
        savedRecords().compactMap { record in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            return url.standardizedFileURL.path
        }
    }

    func remember(directory: URL) throws {
        invalidateUsabilityCache()
        let record = try bookmarkRecord(for: directory.standardizedFileURL)
        var records = savedRecords().filter { $0.path != record.path }
        records.append(record)
        save(records)
    }

    func hasUsableGrant() -> Bool {
        let currentDate = now()
        cacheLock.lock()
        if let cachedUsability,
           currentDate.timeIntervalSince(cachedUsability.capturedAt)
                < Self.usabilityCacheLifetime {
            cacheLock.unlock()
            return cachedUsability.value
        }
        cacheLock.unlock()

        var records = savedRecords()
        var changed = false
        var foundUsableGrant = false

        for index in records.indices.reversed() {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: records[index].bookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let didStartAccess = url.startAccessingSecurityScopedResource()
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    records.remove(at: index)
                    changed = true
                    continue
                }
                foundUsableGrant = true

                if isStale {
                    records[index] = try bookmarkRecord(for: url)
                    changed = true
                }
            } catch {
                records.remove(at: index)
                changed = true
            }
        }

        if changed {
            save(records)
        } else {
            publishObservationRoots(from: records)
        }
        cacheLock.lock()
        cachedUsability = (foundUsableGrant, currentDate)
        cacheLock.unlock()
        return foundUsableGrant
    }

    static func contains(_ targetDirectory: URL, in authorizedDirectory: URL) -> Bool {
        let targetPath = targetDirectory.standardizedFileURL.path
        let authorizedPath = authorizedDirectory.standardizedFileURL.path
        return targetPath == authorizedPath
            || targetPath.hasPrefix(authorizedPath.hasSuffix("/") ? authorizedPath : authorizedPath + "/")
    }

    private func bookmarkRecord(for directory: URL) throws -> BookmarkRecord {
        BookmarkRecord(
            path: directory.standardizedFileURL.path,
            bookmark: try directory.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        )
    }

    private func savedRecords() -> [BookmarkRecord] {
        guard let data = defaults.data(forKey: Key.bookmarks),
              let records = try? JSONDecoder().decode([BookmarkRecord].self, from: data)
        else {
            return []
        }
        return records
    }

    private func save(_ records: [BookmarkRecord]) {
        invalidateUsabilityCache()
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: Key.bookmarks)
        publishObservationRoots(from: records)
    }

    private func invalidateUsabilityCache() {
        cacheLock.lock()
        cachedUsability = nil
        cacheLock.unlock()
    }

    private func publishObservationRoots(from records: [BookmarkRecord]) {
        observationRootUpdater(records.map(\.path))
    }
}
