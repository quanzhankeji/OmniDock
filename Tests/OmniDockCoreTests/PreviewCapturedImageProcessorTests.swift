import XCTest
@testable import OmniDockCore

final class PreviewCapturedImageProcessorTests: XCTestCase {
    func testTransparentPaddingIsTrimmedFromCapturedPreview() throws {
        let image = try makeImage(
            width: 24,
            height: 12,
            contentRect: CGRect(x: 2, y: 1, width: 18, height: 10)
        )

        let cropped = try XCTUnwrap(PreviewCapturedImageProcessor.cropTransparentPadding(from: image))

        XCTAssertEqual(cropped.width, 18)
        XCTAssertEqual(cropped.height, 10)
    }

    func testOpaqueImageIsLeftUnchanged() throws {
        let image = try makeImage(
            width: 24,
            height: 12,
            contentRect: CGRect(x: 0, y: 0, width: 24, height: 12)
        )

        XCTAssertNil(PreviewCapturedImageProcessor.cropTransparentPadding(from: image))
    }

    func testOpaqueNeutralRightPaddingIsTrimmedWhenContentBoundaryIsDistinct() throws {
        let image = try makeImageWithRightPadding(
            width: 80,
            height: 40,
            contentWidth: 68,
            contentColor: CGColor(red: 0.28, green: 0.52, blue: 0.91, alpha: 1),
            paddingColor: CGColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1)
        )

        let cropped = try XCTUnwrap(PreviewCapturedImageProcessor.cropNonContentPadding(from: image))

        XCTAssertEqual(cropped.width, 68)
        XCTAssertEqual(cropped.height, 40)
    }

    func testUniformOpaqueImageIsNotTrimmedAsPadding() throws {
        let image = try makeImageWithRightPadding(
            width: 80,
            height: 40,
            contentWidth: 80,
            contentColor: CGColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1),
            paddingColor: CGColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1)
        )

        XCTAssertNil(PreviewCapturedImageProcessor.cropNonContentPadding(from: image))
    }

    func testContinuousProcessorRejectsFullyTransparentFrame() throws {
        let transparentImage = try makeImage(
            width: 80,
            height: 40,
            contentRect: .zero
        )
        var processor = PreviewContinuousFrameProcessor()

        XCTAssertNil(processor.image(from: transparentImage, generation: 1))
    }

    func testContinuousProcessorReusesFirstValidCropRect() throws {
        let firstImage = try makeImageWithRightPadding(
            width: 80,
            height: 40,
            contentWidth: 68,
            contentColor: CGColor(red: 0.28, green: 0.52, blue: 0.91, alpha: 1),
            paddingColor: CGColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1)
        )
        let laterImage = try makeImageWithRightPadding(
            width: 80,
            height: 40,
            contentWidth: 80,
            contentColor: CGColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1),
            paddingColor: CGColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        )
        var processor = PreviewContinuousFrameProcessor()

        let first = try XCTUnwrap(processor.image(from: firstImage, generation: 1))
        let later = try XCTUnwrap(processor.image(from: laterImage, generation: 1))

        XCTAssertEqual(first.size.width, 68)
        XCTAssertEqual(later.size.width, 68)
        XCTAssertEqual(later.size.height, 40)
    }

    func testContinuousProcessorRecalculatesCropForNewGeneration() throws {
        let paddedImage = try makeImageWithRightPadding(
            width: 80,
            height: 40,
            contentWidth: 68,
            contentColor: CGColor(red: 0.28, green: 0.52, blue: 0.91, alpha: 1),
            paddingColor: CGColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1)
        )
        let fullImage = try makeImageWithRightPadding(
            width: 80,
            height: 40,
            contentWidth: 80,
            contentColor: CGColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1),
            paddingColor: CGColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        )
        var processor = PreviewContinuousFrameProcessor()

        _ = try XCTUnwrap(processor.image(from: paddedImage, generation: 1))
        let nextGeneration = try XCTUnwrap(processor.image(from: fullImage, generation: 2))

        XCTAssertEqual(nextGeneration.size.width, 80)
        XCTAssertEqual(nextGeneration.size.height, 40)
    }

    private func makeImage(width: Int, height: Int, contentRect: CGRect) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.contextCreationFailed
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.92, green: 0.94, blue: 0.96, alpha: 1))
        context.fill(contentRect)

        guard let image = context.makeImage() else {
            throw TestImageError.imageCreationFailed
        }
        return image
    }

    private func makeImageWithRightPadding(
        width: Int,
        height: Int,
        contentWidth: Int,
        contentColor: CGColor,
        paddingColor: CGColor
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw TestImageError.contextCreationFailed
        }

        context.setFillColor(contentColor)
        context.fill(CGRect(x: 0, y: 0, width: contentWidth, height: height))
        if contentWidth < width {
            context.setFillColor(paddingColor)
            context.fill(CGRect(x: contentWidth, y: 0, width: width - contentWidth, height: height))
        }

        guard let image = context.makeImage() else {
            throw TestImageError.imageCreationFailed
        }
        return image
    }

    private enum TestImageError: Error {
        case contextCreationFailed
        case imageCreationFailed
    }
}
