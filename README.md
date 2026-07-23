# OmniDock

OmniDock is a local macOS menu bar utility that makes Dock window switching faster while staying out of the way.

## Features

- Hover over a Dock app icon to preview its open windows.
- Click a running Dock app icon to bring it forward, then click again to hide it without creating minimized Dock window icons.
- Optionally use minimize/restore instead of hide/show for repeated Dock clicks.
- Click a preview thumbnail to focus that exact window.
- Drag a file over a preview thumbnail to raise that window and continue dropping the file.
- Optionally switch between individual windows with Alt-Tab (Option-Tab), using static previews and the same close and quit controls.
- Assign per-app global shortcuts to launch, bring forward, or hide apps with the same toggle behavior.
- Optionally add Finder right-click commands for creating an empty text file and copying the current or selected paths.
- Avoid browser tab navigation shortcuts so those shortcuts stay with the browser.

OmniDock does not include analytics, advertising SDKs, or third-party packages. It uses Apple system frameworks only.

## Requirements

- macOS 12.3 or later
- Accessibility permission for Dock hit testing and window control
- Input Monitoring permission for Dock click detection and the optional Alt-Tab window switcher
- Screen Recording permission for window thumbnails, including live images and one-time static snapshots

## Download

Official releases are available from [GitHub Releases](https://github.com/quanzhankeji/OmniDock/releases/latest). Download `OmniDock-<version>.dmg` for the standard drag-to-Applications installer, or `OmniDock-<version>.zip` for a portable app archive. Both contain the same Universal app for Apple silicon and Intel Macs, signed with Developer ID and notarized by Apple. GitHub also provides ZIP and TAR.GZ archives of the corresponding source code for each release.

To install with Homebrew:

```bash
brew tap quanzhankeji/tap
brew install --cask omnidock
```

## Build And Run

```bash
./script/build_and_run.sh
```

The script builds a stripped release executable by default, stages an `OmniDock.app` bundle, signs it with a local Apple Development signing identity, installs it to `/Applications/OmniDock.app`, and launches it.

Building requires Xcode Command Line Tools or Xcode with a Swift 5.9-compatible toolchain. If no Apple Development identity is available, the script uses ad-hoc signing and warns that macOS permission grants may reset after rebuilding. If more than one development identity is available, set `OMNIDOCK_SIGN_IDENTITY` explicitly.

Set `OMNIDOCK_APP_DIR` to change the staging directory. Set `OMNIDOCK_BUILD_CONFIGURATION=debug` to force a debug build.

To install a local copy into Applications:

```bash
./script/build_and_run.sh --install
```

For a local build that includes the Finder right-click extension, use:

```bash
./script/build_and_run.sh --install-finder-extension
```

## Finder Right-Click Extension

The Finder extension is off by default. Open `OD` > `Settings` > `Finder Extension`, then turn on `Enable`. macOS may open its extension management page; enable OmniDock there to let Finder load the menu.

When enabled, right-clicking an empty area in a Finder Sync-monitored local folder offers **Copy Path** and a **New File** submenu with text and Markdown file choices. Right-clicking selected items offers **Copy Path** and copies every selected path on a separate line. New files are created in the selected folder as `NewFile.txt` or `NewFile.md`, with a number added when needed to avoid conflicts.

Finder Sync menus are available only in locations that macOS lets third-party Finder Sync extensions monitor. They do not appear in File Provider-managed locations, including Desktop and Documents when those folders are managed by iCloud Drive.

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

OmniDock runs locally on your Mac. Preferences and shortcut bindings are stored locally. A shortcut binding includes the selected app's name, bundle identifier, application URL or path, shortcut keys, and enabled state.

One-time preview snapshot cache entries expire 45 seconds after capture so hidden-window previews can be shown briefly. If a cached preview is open when its entry expires, OmniDock releases its displayed image references during the next preview validation pass. Preview images are not written to disk. OmniDock does not collect or transmit personal data.

For Finder's New File command, OmniDock temporarily passes only the user-selected destination folder to its containing app and removes the request after it is consumed or expires. It does not scan Finder folders or request broad file-system access.

See [PRIVACY.md](PRIVACY.md) for the full privacy policy.

## Support

See [SUPPORT.md](SUPPORT.md) for setup notes, troubleshooting, and support guidance.

Report potential vulnerabilities through the private process in [SECURITY.md](SECURITY.md), not through a public bug report.

## Licensing

The public source code is licensed under GNU GPL version 3 only (`GPL-3.0-only`). Official GitHub release binaries are also distributed under GPL v3. App Store and other Developer ID binaries may be offered under separate end-user terms by Chengdu Quanzhan Technology Co., Ltd. See [LICENSING.md](LICENSING.md) for the dual-licensing model and treatment of earlier MIT-licensed versions.

The GPL source license does not grant rights to the OmniDock name, logo, or app icon. See [TRADEMARKS.md](TRADEMARKS.md).
