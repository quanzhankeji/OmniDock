# OmniDock Support

OmniDock is a macOS menu bar utility for faster Dock window switching.

OmniDock is currently distributed as source code only. No official signed app download is published from this repository; build the app from source using the repository instructions.

## Getting Started

Launch OmniDock and open the menu bar item labeled `OD`.

The settings window includes controls for:

- Dock hide/bring-forward toggle
- Optional minimize/restore behavior
- Live Dock previews
- Finder right-click extension
- Per-app keyboard shortcuts
- Permission status for macOS features

## Permissions

OmniDock may request these macOS permissions:

- Accessibility: Dock item detection and window control.
- Input Monitoring: Dock click detection.
- Screen Recording: window thumbnails, including live images and one-time static snapshots.

You can review or change permissions in System Settings > Privacy & Security.

## Troubleshooting

If Dock click toggling or previews stop working:

1. Quit and reopen OmniDock.
2. Confirm Accessibility, Input Monitoring, and Screen Recording are enabled for OmniDock.
3. Remove and re-add OmniDock in the affected permission section if macOS still blocks the feature.
4. Make sure you are running the installed app from `/Applications/OmniDock.app`.

If a per-app shortcut does not register:

1. Choose a shortcut that includes Command, Control, or Option.
2. Avoid browser tab navigation shortcuts and common system shortcuts.
3. Remove duplicate shortcuts inside OmniDock.
4. Reopen OmniDock after changing permissions.

If Finder right-click commands do not appear:

1. Open `OD` > `Settings` > `Finder Extension` and turn on `Enable`.
2. In the macOS extension management page, enable OmniDock Finder Extension.
3. Quit and reopen Finder if macOS has not yet refreshed its extension menu.
4. Right-click an empty area in a local Finder folder for Copy Path and the New File submenu, or select one or more items for Copy Path.

Finder Sync menus do not appear in File Provider-managed locations, including Desktop and Documents when those folders are managed by iCloud Drive. This is a macOS limitation.

## Reporting Issues

Potential security vulnerabilities must follow [SECURITY.md](SECURITY.md) and must not be described in a public issue.

Open a report through [GitHub Issues](https://github.com/quanzhankeji/OmniDock/issues).

When reporting a bug, include:

- macOS version
- OmniDock version
- Dock position and whether Dock auto-hide is enabled
- The affected app name
- Steps that reproduce the behavior

Please avoid sharing private screenshots, file names, window contents, or personal data unless they are necessary to explain the issue.

For commercial licensing or trademark permission, open an issue asking for a private contact route. Do not post confidential agreement terms, credentials, or personal contact details in a public issue.

OmniDock does not require a user account and does not collect personal data. One-time preview snapshot cache entries expire 45 seconds after capture; an open cached preview releases its displayed image references during the next preview validation pass. Configured shortcut bindings and their selected-app metadata remain in local settings until you remove or change them.
