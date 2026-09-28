import Carbon.HIToolbox
import CoreGraphics

enum WindowCycleNavigation: Equatable {
    case left
    case right
    case up
    case down
}

enum WindowCycleInputAction: Equatable {
    case advance(WindowCycleDirection)
    case move(WindowCycleNavigation)
    case confirm
    case cancel
}

protocol WindowCycleInputMonitoring: AnyObject {
    var onEvent: ((WindowCycleInputAction) -> Void)? { get set }
    var isMonitoring: Bool { get }
    func start() -> Bool
    func stop()
}

struct WindowCycleInputState {
    private(set) var generation: UInt64 = 0
    private var isActive = false
    private var isEnding = false

    mutating func begin() {
        generation &+= 1
        isActive = true
        isEnding = false
    }

    mutating func end() {
        generation &+= 1
        isActive = false
        isEnding = false
    }

    func accepts(generation: UInt64) -> Bool {
        isActive && self.generation == generation
    }

    mutating func action(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> WindowCycleInputAction? {
        guard isActive, !isEnding else { return nil }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            isEnding = true
            return .cancel
        }
        if type == .flagsChanged, !flags.contains(.maskAlternate) {
            isEnding = true
            return .confirm
        }
        guard type == .keyDown, flags.contains(.maskAlternate),
              flags.intersection([.maskCommand, .maskControl]).isEmpty else { return nil }
        if keyCode == Int64(kVK_Escape) {
            isEnding = true
            return .cancel
        }
        if keyCode == Int64(kVK_Tab) {
            return .advance(flags.contains(.maskShift) ? .backward : .forward)
        }
        guard !flags.contains(.maskShift) else { return nil }
        switch Int(keyCode) {
        case kVK_LeftArrow: return .move(.left)
        case kVK_RightArrow: return .move(.right)
        case kVK_UpArrow: return .move(.up)
        case kVK_DownArrow: return .move(.down)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            isEnding = true
            return .confirm
        default: return nil
        }
    }
}
