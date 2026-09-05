import AppKit
import XCTest

final class AppIconResourceTests: XCTestCase {
    func testBundleIconImagesHaveBalancedTransparentInsets() throws {
        let resources = repositoryRoot().appendingPathComponent("Resources", isDirectory: true)
        let iconsets = [
            resources.appendingPathComponent("AppIcon.iconset", isDirectory: true),
            resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
        ]
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

        for iconset in iconsets {
            for expectedIcon in expectedIcons {
                let url = iconset.appendingPathComponent(expectedIcon.name)
                let data = try Data(contentsOf: url)
                let image = try XCTUnwrap(NSBitmapImageRep(data: data), url.path)
                let size = expectedIcon.size
                let center = size / 2

                XCTAssertTrue(image.hasAlpha, url.path)
                XCTAssertEqual(image.pixelsWide, size, url.path)
                XCTAssertEqual(image.pixelsHigh, size, url.path)
                XCTAssertLessThanOrEqual(image.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0.01, url.path)
                XCTAssertGreaterThanOrEqual(image.colorAt(x: center, y: center)?.alphaComponent ?? 0, 0.99, url.path)

                let expectedInset = (Double(size) * 100 / 1024).rounded()
                let edgeSamples: [(Int) -> (Int, Int)] = [
                    { ($0, center) }, { (size - 1 - $0, center) },
                    { (center, $0) }, { (center, size - 1 - $0) }
                ]
                for sample in edgeSamples {
                    let inset = try XCTUnwrap((0..<center).first { offset in
                        let (x, y) = sample(offset)
                        return (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5
                    }, url.path)
                    XCTAssertEqual(Double(inset), expectedInset, accuracy: 1, url.path)
                }
            }
        }

        for expectedIcon in expectedIcons {
            let localIcon = try Data(contentsOf: iconsets[0].appendingPathComponent(expectedIcon.name))
            let catalogIcon = try Data(contentsOf: iconsets[1].appendingPathComponent(expectedIcon.name))
            XCTAssertEqual(localIcon, catalogIcon, expectedIcon.name)
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
