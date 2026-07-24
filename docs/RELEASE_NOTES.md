# OmniDock 1.1.1

- Fix Finder extension App Group configuration for direct installations.
- Keep Finder actions independent from Accessibility permission.
- Restore enabled features automatically after their permissions return.
- Preserve settings when moving from sandboxed builds to direct downloads.
- Install the complete app with its Finder extension in local builds.

Finder actions remain available only in locations that Finder Sync can monitor. macOS does not expose third-party Finder Sync menus in File Provider-managed locations, including Desktop and Documents when those folders are managed by iCloud Drive.
