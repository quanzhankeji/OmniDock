import XCTest
@testable import OmniDockCore

final class FinderItemTransferCommandsTests: XCTestCase {
    func testWithheldCommandsNeverReachTheMenu() {
        let stored = FinderMenuPreferences(
            isEnabled: true,
            showsCopyItemsCommand: true,
            showsCutItemsCommand: true,
            showsPasteItemsCommand: true
        )

        let offered = FinderItemTransferCommands.withheld(from: stored)

        if FinderItemTransferCommands.isAvailable {
            XCTAssertEqual(offered, stored)
        } else {
            XCTAssertFalse(offered.showsCopyItemsCommand)
            XCTAssertFalse(offered.showsCutItemsCommand)
            XCTAssertFalse(offered.showsPasteItemsCommand)
        }
    }

    func testWithholdingLeavesEverySettingAlone() {
        // The stored preferences are untouched, so turning the commands back on
        // restores whatever the user had chosen rather than a default.
        let stored = FinderMenuPreferences(
            isEnabled: true,
            showsCopyPathCommand: false,
            showsCopyItemsCommand: true,
            showsCutItemsCommand: true,
            showsPasteItemsCommand: true,
            showsShowHiddenFilesCommand: false
        )

        let offered = FinderItemTransferCommands.withheld(from: stored)

        XCTAssertEqual(offered.isEnabled, stored.isEnabled)
        XCTAssertEqual(offered.showsCopyPathCommand, stored.showsCopyPathCommand)
        XCTAssertEqual(
            offered.showsShowHiddenFilesCommand,
            stored.showsShowHiddenFilesCommand
        )
    }

    func testNoTransferCommandSurvivesInTheBuiltMenu() {
        let preferences = FinderItemTransferCommands.withheld(
            from: FinderMenuPreferences(
                isEnabled: true,
                showsCopyItemsCommand: true,
                showsCutItemsCommand: true,
                showsPasteItemsCommand: true
            )
        )
        let withheld: [FinderMenuAction] = [
            .copySelectedItems, .cutSelectedItems, .pasteItems
        ]

        for location in [FinderMenuLocation.folderBackground, .selection] {
            let entries = FinderMenuCatalog.entries(
                for: FinderMenuContext(
                    location: location,
                    currentDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                    selectedURLs: [],
                    pasteboardHasFiles: true
                ),
                preferences: preferences,
                resolveApplication: { _ in nil },
                acceptsDirectories: { _ in true }
            )

            for entry in entries {
                switch entry {
                case let .action(action):
                    XCTAssertFalse(withheld.contains(action), "\(location): \(action)")
                case let .commandSubmenu(actions),
                     let .documentSubmenu(actions),
                     let .applicationSubmenu(actions):
                    for action in actions {
                        XCTAssertFalse(
                            withheld.contains(action),
                            "\(location): \(action)"
                        )
                    }
                }
            }
        }
    }
}
