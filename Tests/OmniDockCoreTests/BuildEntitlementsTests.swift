import Foundation
import XCTest

final class BuildEntitlementsTests: XCTestCase {
    func testLocalMainAppAndStoreBuildUseDifferentSandboxPolicies() throws {
        let resources = repositoryRoot().appendingPathComponent("Resources", isDirectory: true)
        let development = try entitlements(
            at: resources.appendingPathComponent("OmniDock-Development.entitlements")
        )
        let appStore = try entitlements(
            at: resources.appendingPathComponent("OmniDock-AppStore.entitlements")
        )
        let finderExtension = try entitlements(
            at: resources.appendingPathComponent("OmniDockFinderSync.entitlements")
        )

        XCTAssertNil(development["com.apple.security.app-sandbox"])
        XCTAssertEqual(appStore["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(finderExtension["com.apple.security.app-sandbox"] as? Bool, true)

        let expectedGroup = ["$(TeamIdentifierPrefix)com.quanzhankeji.OmniDock"]
        XCTAssertEqual(
            development["com.apple.security.application-groups"] as? [String],
            expectedGroup
        )
        XCTAssertEqual(
            finderExtension["com.apple.security.application-groups"] as? [String],
            expectedGroup
        )
    }

    func testFinderExtensionPrincipalClassMatchesItsImplementation() throws {
        let root = repositoryRoot()
        let info = try propertyList(
            at: root
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("OmniDockFinderSync-Info.plist")
        )
        let extensionInfo = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(
            extensionInfo["NSExtensionPrincipalClass"] as? String,
            "$(PRODUCT_MODULE_NAME).FinderMenuExtension"
        )

        let implementation = try String(
            contentsOf: root
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("OmniDockFinderSync", isDirectory: true)
                .appendingPathComponent("FinderMenuExtension.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(implementation.contains("final class FinderMenuExtension: FIFinderSync"))
    }

    private func entitlements(at url: URL) throws -> [String: Any] {
        try propertyList(at: url)
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
