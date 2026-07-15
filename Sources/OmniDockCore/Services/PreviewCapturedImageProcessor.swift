import AppKit
import CoreGraphics

struct PreviewContinuousFrameProcessor {
    private var generation: UInt64?
    private var cropRect: CGRect?

    mutating func image(from cgImage: CGImage, generation: UInt64) -> NSImage? {
        guard PreviewCapturedImageProcessor.hasVisibleContent(in: cgImage) else {
            return nil
        }

        let imageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        if self.generation != generation {
            self.generation = generation
            cropRect = PreviewCapturedImageProcessor.nonContentCropRect(from: cgImage) ?? imageBounds
        }

        guard let cropRect else {
            return nil
        }
        let validCropRect = cropRect.intersection(imageBounds).integral
        guard !validCropRect.isNull,
              validCropRect.width > 0,
              validCropRect.height > 0,
              let processedImage = validCropRect == imageBounds
                ? cgImage
                : cgImage.cropping(to: validCropRect)
        else {
            return nil
        }

        return NSImage(
            cgImage: processedImage,
            size: NSSize(width: processedImage.width, height: processedImage.height)
        )
    }
}

enum PreviewCapturedImageProcessor {
    static func image(from cgImage: CGImage) -> NSImage {
        let processedImage = cropNonContentPadding(from: cgImage) ?? cgImage
        return NSImage(
            cgImage: processedImage,
            size: NSSize(width: processedImage.width, height: processedImage.height)
        )
    }

    static func cropNonContentPadding(from cgImage: CGImage) -> CGImage? {
        guard let cropRect = nonContentCropRect(from: cgImage) else {
            return nil
        }
        return cgImage.cropping(to: cropRect)
    }

    static func cropTransparentPadding(from cgImage: CGImage) -> CGImage? {
        guard let cropRect = cropTransparentPaddingRect(from: cgImage) else {
            return nil
        }
        return cgImage.cropping(to: cropRect)
    }

    static func nonContentCropRect(from cgImage: CGImage) -> CGRect? {
        let fullRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        var cropRect = cropTransparentPaddingRect(from: cgImage) ?? fullRect
        let transparentCroppedImage = cgImage.cropping(to: cropRect) ?? cgImage
        if let paddingWidth = opaqueLowInformationRightPaddingWidth(from: transparentCroppedImage) {
            cropRect.size.width -= CGFloat(paddingWidth)
        }
        return cropRect == fullRect ? nil : cropRect
    }

    static func hasVisibleContent(in cgImage: CGImage) -> Bool {
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return false
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return false
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let alphaThreshold: UInt8 = 8
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > alphaThreshold }
    }

    private static func cropTransparentPaddingRect(from cgImage: CGImage) -> CGRect? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let alphaThreshold: UInt8 = 8
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * 4 + 3]
                guard alpha > alphaThreshold else {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard minX <= maxX, minY <= maxY else {
            return nil
        }

        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard cropRect.width < CGFloat(width) || cropRect.height < CGFloat(height) else {
            return nil
        }

        return cropRect
    }

    private static func opaqueLowInformationRightPaddingWidth(from cgImage: CGImage) -> Int? {
        guard let buffer = PixelBuffer(image: cgImage), buffer.width > 24, buffer.height > 24 else {
            return nil
        }

        let maxCrop = min(max(Int(Double(buffer.width) * 0.20), 2), 80)
        var cropWidth = 0
        var firstAverage: RGB?

        for offset in 0..<maxCrop {
            guard let stats = buffer.verticalLineStats(
                x: buffer.width - 1 - offset,
                yRange: buffer.middleSampleRange
            ) else {
                break
            }

            if offset == 0 {
                guard stats.isNeutralVisiblePadding else {
                    break
                }
                firstAverage = stats.average
            }

            guard stats.isNeutralVisiblePadding,
                  stats.isLowInformationPadding,
                  firstAverage.map({ stats.average.distance(to: $0) < 18 }) == true
            else {
                break
            }

            cropWidth = offset + 1
        }

        guard cropWidth >= 2,
              cropWidth < buffer.width / 3,
              let firstAverage,
              let boundary = buffer.verticalLineStats(
                x: max(0, buffer.width - cropWidth - 1),
                yRange: buffer.middleSampleRange
              ),
              boundary.isVisuallyDistinctContent(from: firstAverage)
        else {
            return nil
        }

        return cropWidth
    }

    private struct PixelBuffer {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(image: CGImage) {
            width = image.width
            height = image.height
            guard width > 0, height > 0 else {
                return nil
            }

            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return nil
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.pixels = pixels
        }

        var middleSampleRange: Range<Int> {
            let inset = max(1, Int(Double(height) * 0.12))
            return inset..<max(inset + 1, height - inset)
        }

        func verticalLineStats(x: Int, yRange: Range<Int>) -> LineStats? {
            guard x >= 0, x < width, !yRange.isEmpty else {
                return nil
            }

            let step = max(1, yRange.count / 96)
            var colors: [RGB] = []
            colors.reserveCapacity(yRange.count / step + 1)

            for y in stride(from: yRange.lowerBound, to: yRange.upperBound, by: step) {
                let index = (y * width + x) * 4
                let alpha = pixels[index + 3]
                guard alpha > 245 else {
                    continue
                }
                colors.append(RGB(
                    red: Double(pixels[index]),
                    green: Double(pixels[index + 1]),
                    blue: Double(pixels[index + 2])
                ))
            }

            guard colors.count >= max(4, yRange.count / max(step * 3, 1)) else {
                return nil
            }

            let average = colors.reduce(RGB.zero, +) / Double(colors.count)
            let averageDeviation = colors
                .map { $0.distance(to: average) }
                .reduce(0, +) / Double(colors.count)

            return LineStats(average: average, averageDeviation: averageDeviation)
        }
    }

    private struct LineStats {
        let average: RGB
        let averageDeviation: Double

        var isNeutralVisiblePadding: Bool {
            average.saturation < 0.11 && average.luminance > 38 && average.luminance < 232
        }

        var isLowInformationPadding: Bool {
            averageDeviation < 7.5
        }

        func isVisuallyDistinctContent(from paddingColor: RGB) -> Bool {
            averageDeviation > 10 || average.distance(to: paddingColor) > 26
        }
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        static let zero = RGB(red: 0, green: 0, blue: 0)

        var luminance: Double {
            0.2126 * red + 0.7152 * green + 0.0722 * blue
        }

        var saturation: Double {
            let maxValue = max(red, green, blue)
            let minValue = min(red, green, blue)
            guard maxValue > 0 else {
                return 0
            }
            return (maxValue - minValue) / maxValue
        }

        func distance(to other: RGB) -> Double {
            let redDelta = red - other.red
            let greenDelta = green - other.green
            let blueDelta = blue - other.blue
            return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
        }

        static func + (lhs: RGB, rhs: RGB) -> RGB {
            RGB(
                red: lhs.red + rhs.red,
                green: lhs.green + rhs.green,
                blue: lhs.blue + rhs.blue
            )
        }

        static func / (lhs: RGB, rhs: Double) -> RGB {
            RGB(red: lhs.red / rhs, green: lhs.green / rhs, blue: lhs.blue / rhs)
        }
    }
}
