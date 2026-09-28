import AppKit

struct PreviewDisplay {
    let name: String
    let frame: CGRect
}

enum PreviewWindowStatus {
    static func currentDisplays() -> [PreviewDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return PreviewDisplay(name: screen.localizedName, frame: CGDisplayBounds(number.uint32Value))
        }
    }

    static func displayName(for frame: CGRect, in displays: [PreviewDisplay]) -> String? {
        guard isValid(frame) else { return nil }
        let overlaps = displays.compactMap { display -> (String, CGFloat)? in
            guard isValid(display.frame) else { return nil }
            let intersection = frame.intersection(display.frame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
            return (display.name, intersection.width * intersection.height)
        }
        guard let largestArea = overlaps.map({ $0.1 }).max() else { return nil }
        let matches = overlaps.filter { $0.1 == largestArea }
        guard matches.count == 1, let name = matches.first?.0, !name.isEmpty else { return nil }
        return name
    }

    static func text(for window: PreviewWindowInfo, displays: [PreviewDisplay]) -> String {
        var states: [String] = []
        if window.isMinimized { states.append(AppStrings.text(.previewStateMinimized)) }
        if window.isApplicationHidden == true { states.append(AppStrings.text(.previewStateHidden)) }
        if window.isFullScreen == true { states.append(AppStrings.text(.previewStateFullScreen)) }
        if let display = displayName(for: window.frame, in: displays) {
            states.append(AppStrings.format(.previewDisplay, display))
        } else {
            states.append(AppStrings.text(.previewDisplayUnknown))
        }
        return states.joined(separator: ", ")
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }
}
