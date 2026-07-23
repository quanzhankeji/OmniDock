# OmniDock Privacy Policy

Effective date: July 15, 2026

OmniDock is a local macOS utility for Dock window previews, Dock click window toggling, Finder right-click commands, and per-app keyboard shortcuts. OmniDock is currently distributed as source code only. This policy explains what data the app handles and how it is used.

## Data Collection

OmniDock does not collect, sell, share, or transmit personal data.

OmniDock does not require an account, does not include analytics, does not use advertising SDKs, and does not send usage data to a server.

## Local Data

OmniDock stores settings locally on your Mac, including feature toggles, language and permission-onboarding state, and configured app shortcut bindings. Each shortcut binding stores the selected app's display name, bundle identifier, application URL or path, shortcut key code and modifiers, enabled state, and an internal binding identifier. This data remains on your device and is used only to provide the app's features.

When OmniDock captures one-time snapshots before hiding an app, eligible preview images are cached only in the app's memory and expire 45 seconds after capture. If a cached preview is open at expiration, its displayed image references are released during the next preview validation pass. Entries are also removed when the corresponding window or app cache is cleared. Preview images are not persisted to disk.

The optional Finder extension reads only the current right-click target or the items selected in Finder to build its menu. Copy commands place the requested paths on the local pasteboard. New File sends a short-lived request identifying the Finder-selected destination folder to OmniDock's containing app; the request is removed when consumed and expires after five minutes. If macOS requires additional access, OmniDock asks the user to approve that folder or one of its parents and stores only the resulting security-scoped bookmark. OmniDock does not scan folders, index files, or retain the contents of those folders.

## System Permissions

OmniDock may request the following macOS permissions:

- Accessibility: used to identify Dock items, raise windows, focus windows, and close previewed windows when requested.
- Input Monitoring: used to detect Dock icon click gestures.
- Screen Recording: used to generate window thumbnails, including live images and one-time static snapshots.

These permissions are used locally for OmniDock features. OmniDock does not upload screen contents, keyboard input, window contents, file contents, shortcut bindings, or application usage data.

## Third-Party Services

OmniDock does not use third-party analytics, advertising, crash reporting, or tracking services.

The public source repository may be hosted by a third party. That hosting provider has its own privacy practices for visitors who access the repository or submit issues.

## Changes

This policy may be updated when OmniDock changes. Updates will be published in this repository.

## Contact

For support or privacy questions, see [SUPPORT.md](SUPPORT.md) or use the public repository's issue tracker.
