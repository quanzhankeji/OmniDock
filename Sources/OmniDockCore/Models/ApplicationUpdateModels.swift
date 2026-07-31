import Foundation

struct SemanticVersion: Codable, Comparable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }

        let versionAndMetadata = normalized.split(separator: "+", maxSplits: 1)
        let versionAndPrerelease = versionAndMetadata[0].split(
            separator: "-",
            maxSplits: 1
        )
        let components = versionAndPrerelease[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (1...3).contains(components.count),
              let major = Int(components[0]),
              major >= 0
        else {
            return nil
        }

        let minor = components.count > 1 ? Int(components[1]) : 0
        let patch = components.count > 2 ? Int(components[2]) : 0
        guard let minor, let patch, minor >= 0, patch >= 0 else {
            return nil
        }

        let prerelease = versionAndPrerelease.count == 2
            ? versionAndPrerelease[1].split(separator: ".").map(String.init)
            : []
        guard prerelease.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var displayValue: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            value += "-\(prerelease.joined(separator: "."))"
        }
        return value
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        if lhsCore != rhsCore {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }
        if lhs.prerelease.isEmpty {
            return false
        }
        if rhs.prerelease.isEmpty {
            return true
        }

        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right {
                continue
            }
            switch (Int(left), Int(right)) {
            case let (.some(leftNumber), .some(rightNumber)):
                return leftNumber < rightNumber
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct GitHubReleaseAsset: Codable, Equatable, Sendable {
    let name: String
    let downloadURL: URL
    let size: Int64
    let digest: String?
    let state: String

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
        case digest
        case state
    }

    var sha256Digest: String? {
        guard state == "uploaded",
              let digest,
              digest.hasPrefix("sha256:")
        else {
            return nil
        }
        let value = String(digest.dropFirst("sha256:".count)).lowercased()
        guard value.count == 64,
              value.allSatisfy({ $0.isHexDigit })
        else {
            return nil
        }
        return value
    }
}

struct GitHubRelease: Codable, Equatable, Sendable {
    let tagName: String
    let pageURL: URL
    let isDraft: Bool
    let isPrerelease: Bool
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }

    var version: SemanticVersion? {
        guard !isDraft, !isPrerelease else {
            return nil
        }
        return SemanticVersion(tagName)
    }

    func asset(extension fileExtension: String) -> GitHubReleaseAsset? {
        guard let version else {
            return nil
        }
        let expectedName = "OmniDock-\(version.displayValue).\(fileExtension)"
        return assets.first {
            $0.name == expectedName && $0.state == "uploaded"
        }
    }

    var installableZIPAsset: GitHubReleaseAsset? {
        guard let asset = asset(extension: "zip"),
              asset.sha256Digest != nil
        else {
            return nil
        }
        return asset
    }

    var manualDMGAsset: GitHubReleaseAsset? {
        guard let asset = asset(extension: "dmg"),
              asset.sha256Digest != nil
        else {
            return nil
        }
        return asset
    }
}

enum UpdateCheckOrigin: Sendable {
    case automatic
    case manual
}

enum ApplicationUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case current
    case available(version: String, canInstallAutomatically: Bool)
    case downloading(progress: Double)
    case installing
    case failed(message: String)
}

struct ApplicationUpdateSnapshot: Equatable, Sendable {
    let currentVersion: String
    let currentBuild: String
    let lastCheckedAt: Date?
    let status: ApplicationUpdateStatus
}

enum UpdateInstallationMode: Equatable {
    case automatic
    case manual
}

enum UpdateInstallationPolicy {
    static func mode(
        appURL: URL,
        isParentDirectoryWritable: Bool,
        isVolumeReadOnly: Bool
    ) -> UpdateInstallationMode {
        let path = appURL.resolvingSymlinksInPath().path
        guard isParentDirectoryWritable,
              !isVolumeReadOnly,
              !path.contains("/AppTranslocation/")
        else {
            return .manual
        }
        return .automatic
    }
}
