import XCTest
@testable import OmniDockCore

final class ApplicationUpdateModelsTests: XCTestCase {
    func testSemanticVersionsCompareNumericComponentsAndPrereleases() throws {
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.2.9")), try XCTUnwrap(SemanticVersion("1.3.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("v2.0.0-beta.2")), try XCTUnwrap(SemanticVersion("2.0.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("2.0.0-beta.2")), try XCTUnwrap(SemanticVersion("2.0.0-beta.11")))
        XCTAssertEqual(SemanticVersion("1.2")?.displayValue, "1.2.0")
        XCTAssertNil(SemanticVersion("1..2"))
    }

    func testReleaseSelectsOnlyExactUploadedAssetsWithValidDigest() throws {
        let digest = String(repeating: "a", count: 64)
        let release = try decodeRelease(
            tag: "1.2.2",
            assets: [
                assetJSON(name: "OmniDock-1.2.2.zip", state: "uploaded", digest: "sha256:\(digest)"),
                assetJSON(name: "OmniDock-1.2.2.dmg", state: "uploaded", digest: "sha256:\(digest)"),
                assetJSON(name: "OmniDock-latest.zip", state: "uploaded", digest: "sha256:\(digest)")
            ]
        )

        XCTAssertEqual(release.installableZIPAsset?.name, "OmniDock-1.2.2.zip")
        XCTAssertEqual(release.manualDMGAsset?.name, "OmniDock-1.2.2.dmg")
        XCTAssertEqual(release.installableZIPAsset?.sha256Digest, digest)
    }

    func testDraftAndPrereleaseAreNotInstallable() throws {
        let draft = try decodeRelease(tag: "1.3.0", draft: true)
        let prerelease = try decodeRelease(tag: "1.3.0-beta.1", prerelease: true)

        XCTAssertNil(draft.version)
        XCTAssertNil(prerelease.version)
        XCTAssertNil(draft.installableZIPAsset)
        XCTAssertNil(prerelease.installableZIPAsset)
    }

    func testInvalidDigestAndProcessingAssetAreRejected() throws {
        let invalidDigest = try decodeRelease(
            tag: "1.2.2",
            assets: [assetJSON(name: "OmniDock-1.2.2.zip", state: "uploaded", digest: "sha256:abc")]
        )
        let processing = try decodeRelease(
            tag: "1.2.2",
            assets: [
                assetJSON(
                    name: "OmniDock-1.2.2.zip",
                    state: "new",
                    digest: "sha256:\(String(repeating: "a", count: 64))"
                )
            ]
        )

        XCTAssertNil(invalidDigest.installableZIPAsset)
        XCTAssertNil(processing.installableZIPAsset)
    }

    func testInstallationPolicyFallsBackForReadOnlyAndTranslocatedApps() {
        XCTAssertEqual(
            UpdateInstallationPolicy.mode(
                appURL: URL(fileURLWithPath: "/Applications/OmniDock.app"),
                isParentDirectoryWritable: true,
                isVolumeReadOnly: false
            ),
            .automatic
        )
        XCTAssertEqual(
            UpdateInstallationPolicy.mode(
                appURL: URL(fileURLWithPath: "/Volumes/OmniDock/OmniDock.app"),
                isParentDirectoryWritable: false,
                isVolumeReadOnly: true
            ),
            .manual
        )
        XCTAssertEqual(
            UpdateInstallationPolicy.mode(
                appURL: URL(
                    fileURLWithPath: "/private/var/folders/AppTranslocation/ABC/d/OmniDock.app"
                ),
                isParentDirectoryWritable: true,
                isVolumeReadOnly: false
            ),
            .manual
        )
    }

    func testArtifactDigestUsesLowercaseSHA256() {
        XCTAssertEqual(
            UpdateArtifactIntegrity.sha256Hex(
                for: Data("OmniDock".utf8)
            ),
            "2d615fab22b744fd9f90bb1f893c9c4b611c7b69f0b85138c93a7fc74fe60fa0"
        )
    }

    func testAtomicReplacementMovesNewAppAndRemovesOldApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let target = root.appendingPathComponent("OmniDock.app")
        let incoming = root.appendingPathComponent("Incoming.app")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: incoming,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: target.appendingPathComponent("marker")
        )
        try Data("new".utf8).write(
            to: incoming.appendingPathComponent("marker")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try UpdateAtomicReplacement.perform(
            targetURL: target,
            incomingURL: incoming,
            launchAndConfirm: { true }
        )

        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("marker")),
            "new"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
    }

    func testAtomicReplacementRestoresOldAppWhenRelaunchFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let target = root.appendingPathComponent("OmniDock.app")
        let incoming = root.appendingPathComponent("Incoming.app")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: incoming,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(
            to: target.appendingPathComponent("marker")
        )
        try Data("new".utf8).write(
            to: incoming.appendingPathComponent("marker")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try UpdateAtomicReplacement.perform(
                targetURL: target,
                incomingURL: incoming,
                launchAndConfirm: { false }
            )
        ) {
            XCTAssertEqual(
                $0 as? UpdatePackageError,
                .relaunchFailed
            )
        }
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("marker")),
            "old"
        )
    }

    private func decodeRelease(
        tag: String,
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [[String: Any]] = []
    ) throws -> GitHubRelease {
        let object: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/quanzhankeji/OmniDock/releases/tag/\(tag)",
            "draft": draft,
            "prerelease": prerelease,
            "assets": assets
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func assetJSON(
        name: String,
        state: String,
        digest: String
    ) -> [String: Any] {
        [
            "name": name,
            "browser_download_url": "https://example.com/\(name)",
            "size": 1024,
            "digest": digest,
            "state": state
        ]
    }
}
