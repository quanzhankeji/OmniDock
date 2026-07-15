import ApplicationServices
import CoreGraphics

public enum DockIconClickAction: Equatable {
    case bringApplicationToFront
    case hideApplication
    case minimizeApplicationWindows
}

public enum WindowFiltering {
    public static func shouldIncludeShareableWindow(
        layer: Int,
        isOnScreen: Bool,
        frame: CGRect,
        allowsOccludedCapture: Bool = false
    ) -> Bool {
        hasNormalWindowGeometry(layer: layer, frame: frame)
            && (isOnScreen || allowsOccludedCapture)
    }

    static func hasNormalWindowGeometry(layer: Int, frame: CGRect) -> Bool {
        layer == 0 && frame.width >= 80 && frame.height >= 60
    }

    public static func shouldIncludeAXPreviewWindow(role: String?, subrole: String?, title: String?) -> Bool {
        isNormalAXWindow(role: role, subrole: subrole)
            && !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func isNormalAXWindow(role: String?, subrole: String?) -> Bool {
        role == kAXWindowRole as String
            && subrole != kAXSystemDialogSubrole as String
            && subrole != kAXFloatingWindowSubrole as String
    }

    public static func dockIconClickAction(
        isTopmost: Bool,
        isHidden: Bool,
        unminimizedNormalWindowCount: Int,
        onscreenNormalWindowCount: Int? = nil,
        prefersMinimizeInsteadOfHide: Bool = false
    ) -> DockIconClickAction {
        let visibleWindowCount = onscreenNormalWindowCount ?? unminimizedNormalWindowCount
        if isTopmost && !isHidden && unminimizedNormalWindowCount > 0 && visibleWindowCount > 0 {
            return prefersMinimizeInsteadOfHide ? .minimizeApplicationWindows : .hideApplication
        }
        return .bringApplicationToFront
    }

    public static func shouldHandleRunningDockClick(
        isHidden: Bool,
        normalWindowCount: Int,
        onscreenNormalWindowCount: Int
    ) -> Bool {
        isHidden || normalWindowCount > 0 || onscreenNormalWindowCount > 0
    }

    public static func shouldInterceptDockClick(
        isTopmost: Bool,
        isHidden: Bool,
        unminimizedNormalWindowCount: Int,
        onscreenNormalWindowCount: Int
    ) -> Bool {
        isTopmost
            && !isHidden
            && unminimizedNormalWindowCount > 0
            && onscreenNormalWindowCount > 0
    }

    public static func shouldFallbackToHideAfterMinimize(
        beforeOnscreenNormalWindowCount: Int,
        afterOnscreenNormalWindowCount: Int
    ) -> Bool {
        beforeOnscreenNormalWindowCount > 0 && afterOnscreenNormalWindowCount > 0
    }

    public static func shouldShowDockPreview(
        isTopmost: Bool,
        isHidden: Bool,
        normalWindowCount: Int,
        unminimizedNormalWindowCount: Int
    ) -> Bool {
        guard normalWindowCount > 0 else {
            return false
        }
        return !(isTopmost && !isHidden && unminimizedNormalWindowCount > 0)
    }
}
