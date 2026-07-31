import Foundation

enum GitHubReleaseClientError: LocalizedError, Equatable {
    case invalidResponse
    case serviceUnavailable
    case rateLimited
    case noPublishedRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .serviceUnavailable:
            return "GitHub is temporarily unavailable."
        case .rateLimited:
            return "GitHub's request limit has been reached."
        case .noPublishedRelease:
            return "No published release is available."
        }
    }
}

struct GitHubReleaseResponse: Equatable, Sendable {
    let release: GitHubRelease
    let checkedAt: Date
    let wasNotModified: Bool
}

final class GitHubReleaseCache: @unchecked Sendable {
    private enum Key {
        static let eTag = "update.github.eTag"
        static let release = "update.github.release"
        static let checkedAt = "update.github.checkedAt"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var eTag: String? {
        lock.withLock {
            defaults.string(forKey: Key.eTag)
        }
    }

    var release: GitHubRelease? {
        lock.withLock {
            guard let data = defaults.data(forKey: Key.release) else {
                return nil
            }
            return try? JSONDecoder().decode(GitHubRelease.self, from: data)
        }
    }

    var checkedAt: Date? {
        lock.withLock {
            defaults.object(forKey: Key.checkedAt) as? Date
        }
    }

    func save(release: GitHubRelease, eTag: String?, checkedAt: Date) {
        lock.withLock {
            if let data = try? JSONEncoder().encode(release) {
                defaults.set(data, forKey: Key.release)
            }
            if let eTag {
                defaults.set(eTag, forKey: Key.eTag)
            } else {
                defaults.removeObject(forKey: Key.eTag)
            }
            defaults.set(checkedAt, forKey: Key.checkedAt)
        }
    }

    func recordCheck(at date: Date) {
        lock.withLock {
            defaults.set(date, forKey: Key.checkedAt)
        }
    }
}

struct GitHubReleaseClient: Sendable {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/quanzhankeji/OmniDock/releases/latest"
    )!

    private let session: URLSession
    private let cache: GitHubReleaseCache
    private let now: @Sendable () -> Date

    init(
        session: URLSession = .shared,
        cache: GitHubReleaseCache = GitHubReleaseCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.cache = cache
        self.now = now
    }

    func fetchLatestRelease() async throws -> GitHubReleaseResponse {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("OmniDock-Update-Checker", forHTTPHeaderField: "User-Agent")
        if let eTag = cache.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GitHubReleaseClientError.invalidResponse
        }

        let checkedAt = now()
        switch response.statusCode {
        case 200:
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard release.version != nil else {
                throw GitHubReleaseClientError.noPublishedRelease
            }
            cache.save(
                release: release,
                eTag: response.value(forHTTPHeaderField: "ETag"),
                checkedAt: checkedAt
            )
            return GitHubReleaseResponse(
                release: release,
                checkedAt: checkedAt,
                wasNotModified: false
            )
        case 304:
            guard let release = cache.release,
                  release.version != nil
            else {
                throw GitHubReleaseClientError.invalidResponse
            }
            cache.recordCheck(at: checkedAt)
            return GitHubReleaseResponse(
                release: release,
                checkedAt: checkedAt,
                wasNotModified: true
            )
        case 403, 429:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || response.statusCode == 429 {
                throw GitHubReleaseClientError.rateLimited
            }
            throw GitHubReleaseClientError.serviceUnavailable
        case 500...599:
            throw GitHubReleaseClientError.serviceUnavailable
        default:
            throw GitHubReleaseClientError.invalidResponse
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
