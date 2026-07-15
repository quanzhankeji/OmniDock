import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class ApplicationMainMenuControllerTests: XCTestCase {
    override func tearDown() {
        AppLocalization.configure(language: .system)
        super.tearDown()
    }

    func testEnglishMenuContainsStandardApplicationEditAndWindowCommands() throws {
        AppLocalization.configure(language: .en)
        let menu = ApplicationMainMenuController(onOpenSettings: {}).makeMainMenu()

        XCTAssertEqual(menu.items.map(\.title), ["OmniDock", "Edit", "Window"])

        let applicationMenu = try XCTUnwrap(menu.items[0].submenu)
        XCTAssertEqual(applicationMenu.items[0].title, "Settings...")
        XCTAssertEqual(applicationMenu.items[0].keyEquivalent, ",")
        XCTAssertEqual(applicationMenu.items[2].title, "Hide OmniDock")
        XCTAssertEqual(applicationMenu.items[2].keyEquivalent, "h")
        XCTAssertEqual(applicationMenu.items[4].title, "Quit OmniDock")
        XCTAssertEqual(applicationMenu.items[4].keyEquivalent, "q")

        let editMenu = try XCTUnwrap(menu.items[1].submenu)
        XCTAssertEqual(editMenu.items[0].title, "Undo")
        XCTAssertEqual(editMenu.items[0].action, NSSelectorFromString("performUndo:"))
        XCTAssertEqual(editMenu.items[1].title, "Redo")
        XCTAssertEqual(editMenu.items[1].action, NSSelectorFromString("performRedo:"))
        XCTAssertEqual(editMenu.items[1].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(editMenu.items[3].keyEquivalent, "x")
        XCTAssertEqual(editMenu.items[4].keyEquivalent, "c")
        XCTAssertEqual(editMenu.items[5].keyEquivalent, "v")
        XCTAssertEqual(editMenu.items[6].keyEquivalent, "a")

        let windowMenu = try XCTUnwrap(menu.items[2].submenu)
        XCTAssertEqual(windowMenu.items[0].title, "Close")
        XCTAssertEqual(windowMenu.items[0].keyEquivalent, "w")
        XCTAssertEqual(windowMenu.items[2].title, "Bring All to Front")
    }

    func testChineseMenuUsesLocalizedTitlesAndSameKeyboardCommands() throws {
        AppLocalization.configure(language: .zhHans)
        let menu = ApplicationMainMenuController(onOpenSettings: {}).makeMainMenu()

        XCTAssertEqual(menu.items.map(\.title), ["OmniDock", "编辑", "窗口"])

        let applicationMenu = try XCTUnwrap(menu.items[0].submenu)
        XCTAssertEqual(applicationMenu.items[0].title, "设置…")
        XCTAssertEqual(applicationMenu.items[2].title, "隐藏 OmniDock")
        XCTAssertEqual(applicationMenu.items[4].title, "退出 OmniDock")

        let editMenu = try XCTUnwrap(menu.items[1].submenu)
        XCTAssertEqual(editMenu.items.map(\.title).filter { !$0.isEmpty }, [
            "撤销", "重做", "剪切", "拷贝", "粘贴", "全选"
        ])

        let windowMenu = try XCTUnwrap(menu.items[2].submenu)
        XCTAssertEqual(windowMenu.items[0].title, "关闭窗口")
        XCTAssertEqual(windowMenu.items[2].title, "前置全部窗口")
        XCTAssertEqual(windowMenu.items[0].keyEquivalent, "w")
    }
}
