**English** | [简体中文](README.zh-CN.md)

# OmniDock

Bring everyday Dock and window tasks together in one Mac app. Preview and switch windows, hide or show apps from the Dock, arrange windows, and add clipboard, Finder, or menu bar tools when they fit your workflow.

Coming from Windows? Keep familiar habits like choosing a window from a thumbnail or dragging it into a layout.

[Download](https://github.com/quanzhankeji/OmniDock/releases/latest) · [Website](https://omnidock.app/en/) · [Support](SUPPORT.md)

Free and open source · macOS 12.3+ · Apple silicon and Intel

## Start with one task

- **See the window before switching:** [Dock window previews](https://omnidock.app/en/features/dock-previews/)
- **Click a Dock icon again to hide an app:** [Dock click controls](https://omnidock.app/en/features/dock-click/)
- **Want fewer utilities without giving up your favorite tools?** [One app or separate Mac utilities?](https://omnidock.app/en/guides/one-app-or-separate-mac-utilities/)

## See It in Action

### 01 · Dock window previews

See a window before switching to it. Hover over a running app's Dock icon, then select or close a window from its preview. Drag a file over a thumbnail to bring that window forward.

[Dock preview details](https://omnidock.app/en/features/dock-previews/)

https://github.com/user-attachments/assets/5033facb-ec33-4f57-8e00-a177198431e7

### 02 · App hotkeys

Give each app a shortcut to launch it or bring it forward. Turn on repeated-trigger hiding to put the app away with the same keys. The combinations in the demo are examples, not fixed defaults.

[App hotkey details](https://omnidock.app/en/features/app-hotkeys/)

https://github.com/user-attachments/assets/38aa4f77-c2ba-4e10-bcc8-c480344b7681

### 03 · Window layouts

Drag a window into a screen zone to snap it into place. Use shortcuts or the green-button layout menu too, with halves, corners, thirds, multiple displays, and custom layouts.

[Window layout details](https://omnidock.app/en/features/window-layouts/)

https://github.com/user-attachments/assets/3713f313-0cb9-4976-926e-99d441bc82ae

### 04 · Clipboard history

Find something you copied earlier. Enable local history, then press `Command-Shift-C` to search saved text, formatted content, links, images, and files. Delete individual entries or clear the history whenever you like.

[Clipboard history details](https://omnidock.app/en/features/clipboard-history/)

https://github.com/user-attachments/assets/ea674a12-7c00-4d44-a994-a9bd7fadf6aa

### 05 · Finder right-click actions

Create a blank file, copy one or more paths, reveal hidden items, or open a selection with an app you've chosen—all from a supported Finder folder.

[Finder action details](https://omnidock.app/en/features/finder-actions/)

https://github.com/user-attachments/assets/85807a3b-611c-4151-946e-8ae6f29318cd

### 06 · Menu bar organization

Hold `Command` and drag less-used icons behind the divider. Click to reveal them, then close the section yourself or let it close after 5–60 seconds. You choose the icons; OmniDock doesn't sort them automatically.

[Menu bar details](https://omnidock.app/en/features/menu-bar/)

https://github.com/user-attachments/assets/7f29d5c2-4206-4151-9332-691f6e9a89df

### More window controls

- **Click again to hide the app:** click a running app's Dock icon to bring it forward, then click again to hide it. Hiding removes the whole app from view; it is different from minimizing one window to the Dock. Optional minimize/restore mode acts on the app's controllable normal windows.
- **Switch between windows:** use `Option-Tab` for individual windows, or add window previews to the native `Command-Tab` app switcher.

Choose English or Simplified Chinese, light or dark appearance, or follow your system settings. Launch at login is available on macOS 13 and later.

Some windows can't be captured or resized. Hidden or minimized windows may show recent static images or a text-only state. Finder Sync commands may be unavailable in File Provider-managed cloud folders. See [Support](SUPPORT.md) for setup and limits.

## Install

1. Download the latest **DMG** from [GitHub Releases](https://github.com/quanzhankeji/OmniDock/releases/latest) and drag OmniDock into Applications. A ZIP app archive is also available.
2. Launch OmniDock, click `OD` in the menu bar, and enable the tools you want.

Official GitHub downloads are Universal apps, signed with Developer ID and notarized by Apple. Updates check GitHub's digest and the app's signing identity before installation. Read-only or non-writable installations use the manual DMG update flow.

## Permissions and Privacy

Grant only the permissions needed for the features you enable.

| Permission | Used for |
| --- | --- |
| Accessibility | Dock and window control, app hotkeys, window layouts, and optional clipboard auto-paste |
| Input Monitoring | Dock clicks, Option-Tab, and window drag zones |
| Screen Recording | Live and static window thumbnails |
| Finder Extension and folder access | Finder commands and creating files in a folder you approve |

No account, analytics, or advertising SDKs. Settings and optional clipboard history stay on your Mac; preview images stay in memory. OmniDock contacts GitHub for update checks and downloads you approve, without uploading those contents.

Clipboard history is off by default. Items explicitly marked by their source app as temporary, concealed, or automatically generated are skipped, but this won't catch every sensitive item. Read the [privacy policy](PRIVACY.md) for storage details and limits.

## Build and Contribute

The project uses Swift 5.9-compatible tools and Apple system frameworks, with no third-party package dependencies. Building the complete app also requires Xcode and an Apple Development signing team.

From the repository root:

```bash
swift test
./script/build_and_run.sh
```

The second command builds the app with its Finder Sync extension, installs it to `/Applications`, and launches it. Staging, verification, signing options, and the project structure are in [Development](docs/DEVELOPMENT.md); official distribution steps are in [Releasing](docs/RELEASING.md).

See [Contributing](CONTRIBUTING.md) before submitting changes. Code and documentation contributions require acceptance of the [Contributor License Agreement](CLA.md).

For help, see [Support](SUPPORT.md). Report security vulnerabilities through the private process in [SECURITY.md](SECURITY.md), not a public issue.

## License

Source code and documentation are licensed under GNU GPL version 3 only (`GPL-3.0-only`), unless a file states otherwise. Official GitHub release binaries are also distributed under GPL v3. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

App Store and other Developer ID distributions may use separate end-user terms from Chengdu Quanzhan Technology Co., Ltd. The terms bundled with the exact artifact apply; see [LICENSING.md](LICENSING.md) for dual licensing and earlier MIT-licensed versions.

The source license does not grant rights to the OmniDock name, logo, or app icon. See [TRADEMARKS.md](TRADEMARKS.md).
