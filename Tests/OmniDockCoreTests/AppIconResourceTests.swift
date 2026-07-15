import AppKit
import XCTest

final class AppIconResourceTests: XCTestCase {
    func testBundleIconImagesHaveTransparentRoundedCorners() throws {
        let iconset = repositoryRoot()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("AppIcon.iconset", isDirectory: true)

        let expectedIcons: [(name: String, size: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        for expectedIcon in expectedIcons {
            let url = iconset.appendingPathComponent(expectedIcon.name)
            let data = try Data(contentsOf: url)
            let image = try XCTUnwrap(NSBitmapImageRep(data: data), expectedIcon.name)

            XCTAssertTrue(image.hasAlpha, expectedIcon.name)
            XCTAssertEqual(image.pixelsWide, expectedIcon.size, expectedIcon.name)
            XCTAssertEqual(image.pixelsHigh, expectedIcon.size, expectedIcon.name)
            XCTAssertLessThanOrEqual(image.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0.01, expectedIcon.name)
            XCTAssertGreaterThanOrEqual(
                image.colorAt(x: expectedIcon.size / 2, y: expectedIcon.size / 2)?.alphaComponent ?? 0,
                0.99,
                expectedIcon.name
            )
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
