# OmniDock Support

OmniDock is a local-first macOS utility for window switching, app control, Finder workflows, clipboard history, window layouts, and menu bar organization.

Official Universal releases for Apple silicon and Intel Macs are available from [GitHub Releases](https://github.com/quanzhankeji/OmniDock/releases/latest). The DMG and ZIP are signed with Developer ID and notarized by Apple. Source builds remain available through the repository instructions.

## Getting Started

Launch OmniDock and open the menu bar item labeled `OD`.

The settings window includes controls for:

- Dock and Command-Tab window previews
- Dock hide/show and optional minimize/restore behavior
- Alt-Tab window switching and per-app keyboard shortcuts
- Finder right-click commands
- Local clipboard history
- Window layouts and drag zones
- Hidden Bar menu bar organization
- Language, appearance, permissions, version information, and update checks

OmniDock checks GitHub Releases asynchronously after launch. You can also use **Settings > Check for Updates**. Automatic replacement is available only when the installed application is writable; otherwise OmniDock opens the DMG workflow for manual replacement.

## Permissions

OmniDock may request these macOS permissions:

- Accessibility: Dock item detection, app and window control, per-app hotkeys, optional window layouts, and optional clipboard auto-paste.
- Input Monitoring: Dock click detection, the optional Alt-Tab switcher, and pointer gestures used by optional window drag zones.
- Screen Recording: optional for window thumbnails, including live images and one-time static snapshots. Without it, Dock, Command-Tab, and Option-Tab can still display accessible window titles, app icons, and minimized state, and switch to those windows. Accessibility remains required; Option-Tab also requires Input Monitoring. Apps that do not expose their windows through Accessibility cannot be listed in this mode.
- Finder Extension: adds OmniDock commands to Finder contextual menus.
- Folder Access: grants New File access only to a folder selected by the user or one of its approved parents.

You can review or change permissions in System Settings > Privacy & Security.

Missing permissions do not turn off your feature switches. The affected settings show a temporary-unavailable message and a permission button. Enabled features refresh when permissions change; a feature you turn off while permission is missing stays off after permission is granted. Granting or revoking Screen Recording changes thumbnail availability without restarting OmniDock in the normal case. macOS may still request a restart for a privacy-permission change or a stale signed-app registration.

Hidden Bar, ordinary clipboard-history search and copy, language selection, and appearance selection do not require additional privacy permissions.

## Preview Window Status

Dock, Command-Tab, and Option-Tab previews share the same status line. Minimized and app-hidden are separate states and can appear together, including when a recent thumbnail is available. Full screen is shown only when the owning application's Accessibility interface reports it; a maximized window is not assumed to be full screen.

The display label uses the screen with the largest overlap with the latest known window frame. Equal overlaps, invalid frames, or windows outside the current screens show an unknown display. Cached frames and full-screen state may describe the last observation until the window inventory refreshes; the application-hidden state is refreshed when cached snapshots are read. A continuously open switcher can retain its last observed state until its next inventory refresh or reopening. Screen changes refresh display labels on an open panel, but this does not establish Space membership or add display/Space filtering.

## Window Switcher Keyboard Controls

Enable Alt-Tab Preview, then press Option-Tab and keep holding Option:

| Key | Action |
| --- | --- |
| Tab / Shift-Tab | Cycle forward / backward, wrapping at the ends |
| Arrow keys | Move between grid cells; stop at edges rather than wrapping |
| Return or keypad Enter | Confirm the selected window and dismiss the switcher |
| Escape | Cancel without activating the selection |
| Release Option | Confirm the current selection |

Up/down use the visible grid's column count. A short final row selects the nearest available cell, and the selected row scrolls into view. Command/Control combinations and ordinary text keys are not assigned switcher actions. There is no W/Q/M/H action-key mapping or title-search mode. Native Command-Tab and Dock keyboard behavior are unchanged.

If macOS disables the switcher's input event tap, the current session cancels without focusing a window. Invoke Option-Tab again to start a new session. Queued input from an ended session is discarded.

## Interrupted Previews

During system sleep, display sleep, or switching away from the current user session, OmniDock cancels its active previews and pauses their input monitoring. Returning to the desktop enables new interactions according to the current settings and permissions; it does not restore an old selection or focus a previously selected window. Overlapping interruptions must all end before monitoring resumes. Feature switches are not changed, and intentional pauses do not trigger permission-recovery relaunches.

Connecting or disconnecting a display, or changing its resolution or scaling, also closes active previews without confirming their selection. Hover a Dock icon or invoke the switcher again to read the current window list and screen bounds. Pending results and Dock clicks from before the change are discarded instead of using obsolete coordinates. Display changes do not override disabled features, missing permissions or an ongoing workspace suspension.

Sleep and user-session handling use workspace notifications, not a universal lock-screen detector. Lock/unlock behavior and launching in an already inactive user session still require system-specific verification.

## Troubleshooting

If Dock click toggling or previews stop working:

1. Quit and reopen OmniDock.
2. Confirm Accessibility is enabled. Dock click toggling also needs Input Monitoring. Screen Recording is needed only for thumbnails, not title/icon navigation.
3. Remove and re-add OmniDock in the affected permission section if macOS still blocks the feature.
4. Make sure you are running the installed app from `/Applications/OmniDock.app`.

If a per-app shortcut does not register:

1. Choose a shortcut that includes Command, Control, or Option.
2. Avoid browser tab navigation shortcuts and common system shortcuts.
3. Remove duplicate shortcuts inside OmniDock.
4. Check the permission status in Settings. Accessibility is required; granting it refreshes registrations without changing your preferences.

If Alt-Tab does not open the window switcher:

1. Confirm Alt-Tab Preview is enabled under `OD` > `Window Preview`.
2. Confirm Accessibility and Input Monitoring are granted. Screen Recording is optional and only adds thumbnails.
3. Check whether another app has already registered Option-Tab.

If Finder right-click commands do not appear:

1. Open `OD` > `Settings` > `Finder Extension` and turn on `Enable`.
2. In the macOS extension management page, enable OmniDock Finder Extension.
3. Quit and reopen Finder if macOS has not yet refreshed its extension menu.
4. Right-click an empty area in a local Finder folder for Copy Path and the New File submenu, or select one or more items for Copy Path.

OmniDock registers the local Desktop, Documents, Downloads, their iCloud Drive counterparts when present, and folders that you explicitly authorize. Finder ultimately controls menu availability in provider-managed locations, so some third-party cloud folders may not expose Finder Sync commands.

If New File appears but cannot create a document, approve the destination folder or one of its parent folders when OmniDock asks. Copy Path does not require that write permission.

## Clipboard History

Clipboard History is disabled by default. Enable it under `OD` > `Clipboard History`, then press `Command-Shift-C` to open or close the search panel. Pasteboard entries explicitly marked as temporary, concealed, or automatically generated are intentionally ignored.

If the shortcut does not register, remove any conflicting macOS, third-party, or OmniDock shortcut. Automatic paste requires Accessibility; selecting a history item without Option still copies it back without automatic paste.

## Window Layout And Hidden Bar

Window Layout requires Accessibility and Input Monitoring. It applies only to normal windows that the owning app allows macOS to move or resize. Full-screen windows, system panels, and app-enforced size limits may not accept a requested layout.

Hidden Bar requires no additional privacy permission. Hold Command while dragging movable menu bar icons across OmniDock's divider. Some system-owned menu bar items cannot be moved.

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
