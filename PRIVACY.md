# OmniDock Privacy Policy

Effective date: July 25, 2026

OmniDock is a local macOS utility for Dock window previews, Dock click window toggling, Finder right-click commands, per-app keyboard shortcuts, and optional clipboard history. This policy explains what data the app handles and how it is used.

## Data Collection

OmniDock does not collect, sell, share, or transmit personal data.

OmniDock does not require an account, does not include analytics, does not use advertising SDKs, and does not send usage data to a server.

Shortly after launch, OmniDock makes an asynchronous HTTPS request to GitHub's public Releases API to check for a newer version. The request contains no OmniDock settings, clipboard contents, file paths, window information, or usage history. Manual update checks use the same endpoint. If the user accepts an update, OmniDock downloads the selected release asset from GitHub.

## Local Data

OmniDock stores settings locally on your Mac, including feature toggles, language and permission-onboarding state, and configured app shortcut bindings. Each shortcut binding stores the selected app's display name, bundle identifier, application URL or path, shortcut key code and modifiers, enabled state, and an internal binding identifier. This data remains on your device and is used only to provide the app's features.

When OmniDock captures one-time snapshots before hiding an app, eligible preview images are cached only in the app's memory and expire 45 seconds after capture. If a cached preview is open at expiration, its displayed image references are released during the next preview validation pass. Entries are also removed when the corresponding window or app cache is cleared. Preview images are not persisted to disk.

The optional Finder extension reads only the current right-click target or the items selected in Finder to build its menu. Copy commands place the requested paths on the local pasteboard. New File sends a short-lived request identifying the Finder-selected destination folder to OmniDock's containing app; the request is removed when consumed and expires after five minutes. If macOS requires additional access, OmniDock asks the user to approve that folder or one of its parents and stores only the resulting security-scoped bookmark. OmniDock does not scan folders, index files, or retain the contents of those folders.

Clipboard History is disabled by default. When the user enables it, OmniDock stores supported clipboard entries in the app's local Application Support directory. A history entry may contain copied text, rich text, HTML, links, image data, or file URLs, along with the source app's name and bundle identifier, the copy time, and a content fingerprint used for deduplication. Temporary, concealed, and automatically generated pasteboard entries are ignored. Clipboard history is not uploaded, can be limited from 1 to 999 entries, and can be deleted individually or cleared completely from the app.

## System Permissions

OmniDock may request the following macOS permissions:

- Accessibility: used to identify Dock items, raise windows, focus windows, close previewed windows when requested, and perform automatic paste only when the user explicitly chooses that clipboard action.
- Input Monitoring: used to detect Dock icon click gestures.
- Screen Recording: used to generate window thumbnails, including live images and one-time static snapshots.

These permissions are used locally for OmniDock features. OmniDock does not upload screen contents, keyboard input, window contents, file contents, shortcut bindings, or application usage data.

## Third-Party Services

OmniDock does not use third-party analytics, advertising, crash reporting, or tracking services.

The public source repository and release downloads are hosted by GitHub. GitHub has its own privacy practices for API requests, downloads, repository visitors, and issue submissions.

## Changes

This policy may be updated when OmniDock changes. Updates will be published in this repository.

## Contact

For support or privacy questions, see [SUPPORT.md](SUPPORT.md) or use the public repository's issue tracker.
