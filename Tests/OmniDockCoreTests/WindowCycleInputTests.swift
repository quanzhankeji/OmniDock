import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import OmniDockCore

final class WindowCycleInputTests: XCTestCase {
    func testCancellationReleaseAndInterruptedMonitoringFinishExactlyOnce() {
        let endings: [(CGEventType, Int64, CGEventFlags, WindowCycleInputAction)] = [
            (.keyDown, Int64(kVK_Escape), [.maskAlternate, .maskShift], .cancel),
            (.flagsChanged, 0, [], .confirm),
            (.tapDisabledByTimeout, 0, .maskAlternate, .cancel),
            (.tapDisabledByUserInput, 0, .maskAlternate, .cancel)
        ]
        for (type, code, flags, expected) in endings {
            var state = WindowCycleInputState()
            state.begin()
            let oldGeneration = state.generation
            XCTAssertEqual(state.action(type: type, keyCode: code, flags: flags), expected)
            XCTAssertTrue(state.accepts(generation: oldGeneration), "The queued final action may finish this session")
            XCTAssertNil(state.action(type: .keyDown, keyCode: Int64(kVK_Tab), flags: .maskAlternate))
            XCTAssertNil(state.action(type: .flagsChanged, keyCode: 0, flags: []))
            state.end()
            XCTAssertFalse(state.accepts(generation: oldGeneration))
            state.begin()
            XCTAssertFalse(state.accepts(generation: oldGeneration), "Queued input must not affect a new session")
            XCTAssertTrue(state.accepts(generation: state.generation))
            XCTAssertEqual(state.action(type: .keyDown, keyCode: Int64(kVK_Tab), flags: .maskAlternate), .advance(.forward))
        }
    }

    func testNavigationKeysDoNotTakeOverTextOrOtherShortcuts() {
        var state = WindowCycleInputState()
        state.begin()
        for (code, direction) in [(kVK_LeftArrow, WindowCycleNavigation.left), (kVK_RightArrow, .right),
                                  (kVK_UpArrow, .up), (kVK_DownArrow, .down)] {
            XCTAssertEqual(state.action(type: .keyDown, keyCode: Int64(code),
                                        flags: [.maskAlternate, .maskNumericPad, .maskSecondaryFn]), .move(direction))
            for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskShift] {
                XCTAssertNil(state.action(type: .keyDown, keyCode: Int64(code), flags: [.maskAlternate, modifier]))
            }
            XCTAssertNil(state.action(type: .keyDown, keyCode: Int64(code), flags: []))
            XCTAssertNil(state.action(type: .keyUp, keyCode: Int64(code), flags: .maskAlternate))
        }
        XCTAssertEqual(state.action(type: .keyDown, keyCode: Int64(kVK_Tab), flags: .maskAlternate), .advance(.forward))
        XCTAssertEqual(state.action(type: .keyDown, keyCode: Int64(kVK_Tab),
                                    flags: [.maskAlternate, .maskShift]), .advance(.backward))
        for code in [kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_M, kVK_ANSI_H, kVK_Space, kVK_Delete] {
            XCTAssertNil(state.action(type: .keyDown, keyCode: Int64(code), flags: .maskAlternate))
        }
        for modifier: CGEventFlags in [.maskCommand, .maskControl] {
            for code in [kVK_Tab, kVK_Return, kVK_Escape] {
                XCTAssertNil(state.action(type: .keyDown, keyCode: Int64(code), flags: [.maskAlternate, modifier]))
            }
        }
        XCTAssertEqual(state.action(type: .keyDown, keyCode: Int64(kVK_ANSI_KeypadEnter),
                                    flags: [.maskAlternate, .maskAlphaShift]), .confirm)
    }

    func testReturnConfirmsOnlyTheActiveSwitcher() {
        var state = WindowCycleInputState()
        XCTAssertNil(state.action(type: .keyDown, keyCode: Int64(kVK_Return), flags: .maskAlternate))
        state.begin()
        XCTAssertEqual(state.action(type: .keyDown, keyCode: Int64(kVK_Return), flags: .maskAlternate), .confirm)
        XCTAssertNil(state.action(type: .flagsChanged, keyCode: 0, flags: []))
        state.end()
        XCTAssertNil(state.action(type: .keyDown, keyCode: Int64(kVK_Return), flags: .maskAlternate))
    }
}
