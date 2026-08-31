**English** | [简体中文](README.zh-CN.md)

# OmniDock

OmniDock is a local-first macOS utility for faster window switching, app control, Finder workflows, clipboard history, window layouts, and menu bar organization.

## Features

- Hover over a Dock app icon to preview its open windows.
- Click a running Dock app icon to bring it forward, then click again to hide it without creating minimized Dock window icons.
- Optionally use minimize/restore instead of hide/show for repeated Dock clicks.
- Click a preview thumbnail to focus that exact window.
- Drag a file over a preview thumbnail to raise that window and continue dropping the file.
- Optionally show static previews for the selected app while using the native Command-Tab switcher.
- Optionally switch between individual windows with Alt-Tab (Option-Tab), using static previews and the same close and quit controls.
- Assign per-app global shortcuts to launch, bring forward, or hide apps with the same toggle behavior.
- Resize and position the frontmost window with global shortcuts, a green-button layout menu, or configurable drag zones.
- Optionally add configurable Finder right-click commands for copying paths, creating empty files, showing or hiding hidden files, and opening selected items—or the current folder when nothing is selected—with chosen applications.
- Optionally keep a local, searchable clipboard history for text, formatted content, links, images, and files, opened with `Command-Shift-C`.
- Organize less-used menu bar icons behind an expandable divider, with manual reveal and optional automatic hiding.
- Optionally launch OmniDock automatically when you log in on macOS 13 or later.
- Choose English, Simplified Chinese, or the system language, with light, dark, or system appearance.
- Check for official updates and verify their GitHub digest and Developer ID signature before installation.
- Avoid browser tab navigation shortcuts so those shortcuts stay with the browser.

OmniDock does not include analytics, advertising SDKs, or third-party packages. It uses Apple system frameworks only.

## Requirements

- macOS 12.3 or later
- Accessibility permission for Dock hit testing, app and window control, per-app hotkeys, and optional window layouts
- Input Monitoring permission for Dock click detection, the optional Alt-Tab window switcher, and optional window drag zones
- Screen Recording permission for window thumbnails, including live images and one-time static snapshots
- Finder extension access and one-time destination-folder access for optional Finder commands

## Download

Official releases are available from [GitHub Releases](https://github.com/quanzhankeji/OmniDock/releases/latest). Download `OmniDock-<version>.dmg` for the standard drag-to-Applications installer, or `OmniDock-<version>.zip` for a portable app archive. Both contain the same Universal app for Apple silicon and Intel Macs, signed with Developer ID and notarized by Apple. GitHub also provides ZIP and TAR.GZ archives of the corresponding source code for each release.

OmniDock checks GitHub Releases asynchronously shortly after launch. When a newer signed release is available, OmniDock can download, verify, replace, and restart a writable installation. Apps running from a read-only disk image, App Translocation, or another non-writable location use the DMG-based manual installation flow instead. Updates can also be checked manually from the Settings tab.

To install with Homebrew:

```bash
brew tap quanzhankeji/tap
brew install --cask omnidock
```

## Build And Run

```bash
./script/build_and_run.sh
```

The script builds the complete `OmniDock.app`, including its Finder Sync extension, installs it to `/Applications`, and launches it. When one Developer ID Application identity is available, the local Release build is re-signed with that stable identity so existing macOS privacy permissions remain attached across rebuilds.

Building the complete app requires Xcode, an Apple Development team, and a Swift 5.9-compatible toolchain. If no Developer ID identity is available, the installation keeps its Apple Development signature. Once a Developer ID build is installed, the script refuses to replace it with a development-signed build unless `OMNIDOCK_ALLOW_SIGNING_IDENTITY_CHANGE=1` is explicitly set, because changing identities detaches macOS privacy permissions. If more than one Developer ID identity is available, set `OMNIDOCK_LOCAL_DEVELOPER_IDENTITY` explicitly.

Set `OMNIDOCK_APP_DIR` to change the staging directory. Set `OMNIDOCK_BUILD_CONFIGURATION=debug` to force a debug build.

To install the complete local app into Applications:

```bash
./script/build_and_run.sh --install
```

The explicit Finder extension command remains available as an alias:

```bash
./script/build_and_run.sh --install-finder-extension
```

## Window Previews And App Control

Dock previews show the normal windows that macOS makes available to OmniDock. Preview cards can focus the exact window, close that window, quit its application, or raise it while a file is being dragged. Live previews can be disabled to use static snapshots and reduce resource use. Hidden and minimized windows may use a recent static image or a text-only state when macOS cannot provide a current frame.

Dock click toggling applies only to running applications. A short click brings a background application forward, while a second click on the frontmost visible application hides it. Unlaunched apps, long presses, and Dock icon rearrangement remain under macOS control. Minimize/restore can be selected instead of hide/show.

The optional Command-Tab preview augments the native macOS application switcher without replacing it. The separate Alt-Tab window switcher uses Option-Tab to navigate individual windows with static previews. Per-app hotkeys can launch an app that is not running, bring it forward, or hide it when it is already frontmost.

## Finder Right-Click Extension

The Finder extension is off by default. Open `OD` > `Settings` > `Finder Extension`, then turn on `Enable`. macOS may open its extension management page; enable OmniDock there to let Finder load the menu.

When enabled, right-clicking an empty area in a Finder Sync-monitored local folder offers **Copy Path**, a configurable **New File** submenu, commands for showing or hiding hidden files, and optional shortcuts for opening the current folder with chosen applications. Text and Markdown are included by default, and additional file types can be added in OmniDock settings. Right-clicking selected items offers **Copy Path** and optional shortcuts for opening the selection with chosen applications; hidden-file commands remain on folder-background menus. Copied selections place every path on a separate line, and new files use an available `NewFile.<extension>` name without overwriting existing files before entering inline rename.

OmniDock registers the local Desktop, Documents, Downloads, their iCloud Drive counterparts when present, and other local folders that you explicitly authorize. Finder ultimately controls menu availability in provider-managed locations, so some cloud folders may not expose these commands.

## Clipboard History

Clipboard History is off by default. Enable it from `OD` > `Settings` > `Clipboard History`. While enabled, OmniDock checks the system pasteboard for changes and stores supported entries locally on this Mac. Press `Command-Shift-C` to search the history, use the arrow keys to select an entry, and press Return to copy it back. Hold Option while confirming to paste into the app that was active before the history panel opened.

Pasteboard entries explicitly marked as temporary, concealed, or automatically generated are ignored. The history limit can be set from 1 to 999 entries, and individual entries or the entire history can be deleted from settings.

## Window Layout

Window Layout is optional. Enable it from `OD` > `Settings` > `Window Layout` to resize and position the frontmost resizable window with global shortcuts, a layout menu shown by hovering over the green window button, or drag zones that apply a layout when the window is released.

Built-in layouts include halves, corners, thirds, two-thirds, maximize, center, restore, and moving a window between displays. Custom layouts can define their own size and position, keyboard shortcut, and drag activation zone. Full-screen windows, system panels, and windows whose apps restrict movement or resizing remain subject to macOS and app behavior.

## Menu Bar Icon Organizer

Enable Hidden Bar from `OD` > `Settings` > `Hidden Bar` to place less-used menu bar icons behind an expandable divider. Hold Command while dragging menu bar icons across the divider to arrange them, then reveal them manually or let OmniDock hide them again after a configurable delay.

This feature needs no additional privacy permission. Some system-controlled menu bar items cannot be moved because macOS owns their placement.

To launch only the staged bundle:

```bash
./script/build_and_run.sh --stage
```

To run the test suite:

```bash
swift test
```

To assemble, sign, and verify a staged app without installing or launching it:

```bash
./script/build_and_run.sh --verify
```

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the project structure, core interaction flows, and regression checklist.

Maintainers can find generic signing and distribution guidance in [docs/RELEASING.md](docs/RELEASING.md).

Contributions are welcome under the process in [CONTRIBUTING.md](CONTRIBUTING.md). Code and documentation contributions require acceptance of the [Contributor License Agreement](CLA.md).

## Privacy

OmniDock runs locally on your Mac. Preferences, shortcut bindings, and optional clipboard history are stored locally. A shortcut binding includes the selected app's name, bundle identifier, application URL or path, shortcut keys, and enabled state. Clipboard History remains disabled until the user turns it on and can be cleared at any time.

One-time preview snapshot cache entries expire 45 seconds after capture so hidden-window previews can be shown briefly. If a cached preview is open when its entry expires, OmniDock releases its displayed image references during the next preview validation pass. Preview images are not written to disk. OmniDock does not collect or transmit personal data.

For Finder's New File command, OmniDock temporarily passes only the user-selected destination folder to its containing app and removes the request after it is consumed or expires. It does not scan Finder folders or request broad file-system access.

The update checker sends a standard HTTPS request to GitHub's public Releases API containing no OmniDock settings, clipboard contents, window information, or other user data. Downloaded updates must match GitHub's SHA-256 digest and OmniDock's existing code-signing identity before installation.

See [PRIVACY.md](PRIVACY.md) for the full privacy policy.

## Support

See [SUPPORT.md](SUPPORT.md) for setup notes, troubleshooting, and support guidance.

Report potential vulnerabilities through the private process in [SECURITY.md](SECURITY.md), not through a public bug report.

## Licensing

The public source code is licensed under GNU GPL version 3 only (`GPL-3.0-only`). Official GitHub release binaries are also distributed under GPL v3. App Store and other Developer ID binaries may be offered under separate end-user terms by Chengdu Quanzhan Technology Co., Ltd. See [LICENSING.md](LICENSING.md) for the dual-licensing model and treatment of earlier MIT-licensed versions.

The GPL source license does not grant rights to the OmniDock name, logo, or app icon. See [TRADEMARKS.md](TRADEMARKS.md).
