# OmniDock Privacy Policy

Effective date: July 25, 2026

OmniDock is a local macOS utility for window previews and switching, app control, Finder right-click commands, optional clipboard history, window layouts, and menu bar organization. This policy explains what data the app handles and how it is used.

## Data Collection

OmniDock does not collect, sell, share, or transmit personal data.

OmniDock does not require an account, does not include analytics, does not use advertising SDKs, and does not send usage data to a server.

Shortly after launch, OmniDock makes an asynchronous HTTPS request to GitHub's public Releases API to check for a newer version. The request contains no OmniDock settings, clipboard contents, file paths, window information, or usage history. Manual update checks use the same endpoint. If the user accepts an update, OmniDock downloads the selected release asset from GitHub.

## Local Data

OmniDock stores settings locally on your Mac, including feature toggles, language and appearance, permission-onboarding state, window-layout configuration, Hidden Bar timing, Finder menu configuration, and configured app shortcut bindings. Each shortcut binding stores the selected app's display name, bundle identifier, application URL or path, shortcut key code and modifiers, enabled state, and an internal binding identifier. This data remains on your device and is used only to provide the app's features.

When OmniDock captures one-time snapshots before hiding an app, eligible preview images are cached only in the app's memory and expire 45 seconds after capture. If a cached preview is open at expiration, its displayed image references are released during the next preview validation pass. Entries are also removed when the corresponding window or app cache is cleared. Preview images are not persisted to disk.

The optional Finder extension reads only the current right-click target or the items selected in Finder to build its menu. Copy commands place the requested paths on the local pasteboard. New File sends a short-lived request identifying the Finder-selected destination folder to OmniDock's containing app; the request is removed when consumed and expires after five minutes. If macOS requires additional access, OmniDock asks the user to approve that folder or one of its parents and stores only the resulting security-scoped bookmark. OmniDock does not scan folders, index files, or retain the contents of those folders.

Clipboard History is disabled by default. When the user enables it, OmniDock stores supported clipboard entries in the app's local Application Support directory. A history entry may contain copied text, rich text, HTML, links, image data, or file URLs, along with the source app's name and bundle identifier, the copy time, and a content fingerprint used for deduplication. Temporary, concealed, and automatically generated pasteboard entries are ignored. Clipboard history is not uploaded, can be limited from 1 to 999 entries, and can be deleted individually or cleared completely from the app.

Entry contents are encrypted on disk. OmniDock seals the copied content, its preview text, its thumbnail, and the source app name with AES-256-GCM, using a random key generated on first use; the deduplication fingerprint is a keyed value that does not reveal what was copied. The copy time, entry kind, size, and copy count remain readable so the archive can be listed and pruned. The key is stored as a file next to the history database, readable only by the user account that owns it. This means the stored history cannot be read from the database file itself, including from a backup or a copy of the disk, but it is not protected against other software running under the same user account on this Mac. If the key cannot be created or read, OmniDock keeps that session's history in memory only rather than writing it unprotected. History encrypted with a key that is no longer present cannot be recovered and is discarded.

## System Permissions

OmniDock may request the following macOS permissions:

- Accessibility: used to identify Dock items; raise, focus, hide, close, move, or resize windows when requested; operate per-app hotkeys; and perform automatic paste only when the user explicitly chooses that clipboard action.
- Input Monitoring: used to detect Dock icon click gestures, operate the optional Option-Tab window switcher, and recognize pointer gestures used by optional window drag zones. OmniDock does not record or save typed text.
- Screen Recording: used to generate window thumbnails, including live images and one-time static snapshots.
- Finder Extension: used to add the enabled OmniDock commands to Finder contextual menus.
- Folder Access: stores a security-scoped bookmark only for a folder the user explicitly approves, so New File can write to that location without broad file-system access.

These permissions are used locally for OmniDock features. OmniDock does not upload screen contents, keyboard input, window contents, file contents, shortcut bindings, or application usage data.

Hidden Bar uses macOS status-item behavior and does not require an additional privacy permission.

## Third-Party Services

OmniDock does not use third-party analytics, advertising, crash reporting, or tracking services.

The public source repository and release downloads are hosted by GitHub. GitHub has its own privacy practices for API requests, downloads, repository visitors, and issue submissions.

## Changes

This policy may be updated when OmniDock changes. Updates will be published in this repository.

## Contact

For support or privacy questions, see [SUPPORT.md](SUPPORT.md) or use the public repository's issue tracker.
