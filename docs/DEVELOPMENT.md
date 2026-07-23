# Development Notes

This document summarizes the project structure and the behavior that should stay stable when changing OmniDock.

## Project Structure

- `Sources/OmniDockCore/AppDelegate.swift` wires the menu bar app, settings window, Dock interaction, previews, permissions, and hotkeys.
- `Sources/OmniDockCore/Models` contains value types shared across services and UI.
- `Sources/OmniDockCore/Services` contains system-facing logic: Dock hit testing, click interception, window control, preview capture, settings, permissions, and shortcut registration.
- `Sources/OmniDockCore/UI` contains AppKit views and controllers for settings, application selection, preview panels, and thumbnail interaction.
- `Tests/OmniDockCoreTests` covers policy logic, settings migration, preview filtering, shortcut validation, and UI interaction helpers.

## Change Map

Use this map before editing so changes stay narrow:

| Area | Main Files | Notes |
| --- | --- | --- |
| Dock click detection | `DockClickEventTap`, `DockHitTester`, `DockInteractionCoordinator` | Keep short click handling separate from long press and drag passthrough. |
| Dock target identity | `DockAppTarget`, `DockProxyTargetResolver` | Preserve Dock icon identity when routing work to another process. |
| Window hide/show | `WindowControlService`, `WindowFiltering` | Prefer one central toggle path for Dock clicks and shortcuts. |
| Window inventory | `WindowInventoryService`, `PreviewWindowSnapshot`, `PreviewWindowCatalog` | Maintain a public-API window fact cache keyed by `owner PID + CGWindowID`; invalid events make records unavailable until reconciliation, rather than guessing. |
| Window previews | `ScreenCapturePreviewService`, `PreviewWindowSnapshot`, `PreviewCaptureSessionRegistry`, `PreviewWindowCatalog`, `PreviewPanelController` | Reuse streams by stable window identity and stop them as soon as previews close or switch target. |
| Window cycling | `WindowCycleService`, `WindowInventoryService`, `PreviewPanelController` | Option-Tab opens OmniDock's window-level cycle. It owns its Carbon registration and a short-lived input monitor, and uses static images only. |
| Finder right-click extension | `FinderSync`, `FinderExtensionCommandService`, `FinderExtensionShared` | Keep menu construction lightweight and read the Finder target synchronously. The extension queues only explicit New File requests; it never scans directories. |
| Settings and persistence | `SettingsStore`, `SettingsWindowController` | Keep stored keys compatible with existing users. |
| Shortcuts | `AppHotkeyService`, `AppHotkeyBinding`, `ShortcutRecorderView`, `HotkeyShortcutPolicy` | Global shortcuts use Apple system APIs and should remain dependency-free. |
| App selection | `ApplicationSelectionCatalog`, `ApplicationPickerWindowController` | System apps such as Finder should remain selectable. |

## Core Flows

- Dock hover and click follow one route: `DockHitTester` produces the original `DockAppTarget`, `DockProxyTargetResolver` resolves its application owner, and preview or toggle services consume that same application-level target.
- Dock click handling uses `DockClickEventTap` only for short unmodified clicks. Long press and drag still pass through so the system Dock can handle icon movement.
- Running app toggles go through `WindowControlService`. Keep hide/show, minimize/restore, and single-window focus on the same central path.
- Global shortcuts go through `AppHotkeyService`. If an app is not running, the shortcut launches it; if it is running without normal windows, it tries to create a new window.
- Finder right-click commands are provided only through `FIFinderSync`. The extension reads a fresh App Group settings snapshot when Finder asks for a menu, copies paths directly to the local pasteboard, and hands New File to the containing app through a short-lived request. The containing app asks the user for a security-scoped directory bookmark only when direct access is unavailable. Do not add Accessibility, event-tap, or simulated-input fallbacks for Finder menus.
- Finder Sync does not receive native contextual-menu requests for File Provider-managed locations, including Desktop and Documents when iCloud Drive manages those folders. Keep that limitation explicit; do not bypass it with global mouse interception or broad home-relative temporary file entitlements.
- Preview capture uses live ScreenCaptureKit streams when enabled. A delayed static capture may provide a provisional first image, but it must not terminate the live stream; later complete stream frames replace it. Stop streams promptly when the pointer leaves the retained preview area.
- Preview capture identity is `owner PID + CGWindowID`. Title, frame, AX order, and raw AX counts are presentation or validation metadata, not stable stream identity. Confirm an identity-set change twice before applying it; keep sessions in the intersection and start or stop only the difference.
- `WindowInventoryService` is the shared window-fact layer for Dock previews, Command-Tab previews, and future window navigation. It observes only public workspace and Accessibility events, tracks metadata and MRU history, and never owns panels or capture sessions. Its short-lived ScreenCaptureKit mapping is reused only while fresh; AX/workspace invalidation falls back to the existing AX + ScreenCaptureKit reconciliation path without starting a capture stream.
- Window Cycle is a separate OmniDock interaction, not a replacement for the system Command-Tab switcher. It reads the MRU window list from `WindowInventoryService`, starts on the previous window, and owns its Carbon registration and input monitor only while the chooser is open. Releasing Option confirms the selected window; Escape cancels. Keep its transient selection state out of inventory and out of Command-Tab observation.
- Window Cycle paints cached images first, then requests up to three static images concurrently: the selected card and its immediate neighbors are first, followed by the remaining windows in MRU order. It never starts live ScreenCaptureKit streams, and ending the cycle cancels every pending static capture before the panel is hidden.
- Keep window event handling separate from image capture. Create, destroy, minimize, restore, focus, and Space changes invalidate immediately; move, resize, and title changes are coalesced for 100ms. Do not add private WindowServer APIs or turn inventory events into background screenshot work.
- Preview window actions use conservative identity matching. Thumbnail focus and close operations prefer exact window IDs, use unique titles only when AX does not expose IDs, and never guess among ambiguous windows.
- Command-Tab preview is an adapter over the shared preview UI. Keep its system-switcher observation, event handling, and coordinate conversion inside its own service; do not change shared panel configuration or Dock thumbnail interaction to support Command-Tab behavior. Command-Tab and Window Cycle must remain separate presentation contexts.
- Treat AX windows as the current interaction truth for offscreen capture rows. WindowServer may retain closed ScreenCaptureKit surfaces, so sample AX after shareable content arrives and require one-to-one AX support before accepting an offscreen surface.
- Removing a window through a preview tile must also remove its cached hidden snapshot. A running application with no current normal windows must not show historical thumbnails or an empty preview panel.

## Dock Tile Rules

Dock targets should be resolved through normal application identity from the system Dock element and running application list. Do not infer child window scopes from auxiliary process names or other app-specific naming patterns.

Some apps expose more than one Dock icon even though a secondary icon may not own the real user-facing window. In that case, use the proxy Dock icon rule: if the hit process has no valid ordinary windows and exactly one other process owns a valid ordinary window whose title exactly matches the Dock icon title, route preview and click handling to that window owner while keeping the original Dock icon position for panel placement. Do not use third-party app names, bundle identifiers, or naming suffixes for this decision.

A remembered proxy owner may keep the route stable while its windows are hidden, but only while that process is still running. Clear the remembered owner and fail open to the original target when the original process owns a valid ordinary window again, the owner exits, or current evidence is ambiguous or conflicts with the remembered owner.

Proxying changes only the application identity used for preview and toggle operations. Preserve the original Dock frame, hit point, explicit tile identifier override, and per-icon tile identity so panel placement and hover transitions still refer to the icon that was actually hit.

## Code Style

- Keep system-facing decisions in small policy types when they can be tested without launching apps.
- Keep AppKit view code focused on layout and event handling; move reusable rules into `Services`.
- Prefer neutral sample names in tests and docs.
- Add comments only for non-obvious system behavior, such as Dock event replay, Accessibility fallbacks, or ScreenCaptureKit limits.
- Avoid app-specific branches. When an app behaves differently, look for an observable system fact such as process ownership, window title, AX role, CG window layer, or Dock item frame.
- Do not add third-party packages without a deliberate product decision. OmniDock currently depends only on Apple frameworks.
- Use `WindowCycle` for OmniDock's Option-Tab implementation. Do not import names, panel architecture, private APIs, or event-routing assumptions from other window-switching tools.

## Appearance

- `AppAppearance` stores the user choice: follow system, light, or dark. `SettingsStore` owns persistence and applies changes immediately.
- `OmniDockTheme` is the shared public palette for OmniDock views and downstream adapters. Use its semantic colors rather than adding calibrated RGB values to individual views.
- Apply the selected appearance to every OmniDock-owned `NSWindow`. Views that cache `CGColor` values in layers must refresh them from `viewDidChangeEffectiveAppearance()`.
- The theme changes presentation only. It must not own input monitors, preview capture sessions, Dock interaction state, or window-control behavior.

## Contribution and Licensing Boundaries

- Public source is licensed under `GPL-3.0-only`; do not add incompatible source or assets.
- External code and documentation contributions require acceptance of the repository CLA so official binary editions can continue to use separate distribution terms.
- Keep commercial EULAs, signing credentials, account data, and notarization profiles outside the repository.
- Do not replace or weaken copyright, source-license, attribution, or trademark notices as part of an unrelated change.
- Forks may exercise their GPL rights but must use distinct branding as described in `TRADEMARKS.md`.

## Permissions

- Accessibility is used for Dock hit testing, raising windows, closing windows, and menu fallbacks.
- Input Monitoring may be required for Dock click interception and is required only while a Window Cycle session is active.
- Screen Recording is only required for live or static window previews.
- Global shortcuts use Apple system APIs and do not require an additional permission prompt.

## Verification

Run these checks before considering a change complete:

```bash
swift test
./script/build_and_run.sh --verify
```

Manual smoke tests should cover:

- Hover previews for Finder, a browser, and a multi-window app.
- Dock click hide/show and optional minimize/restore.
- Preview thumbnail click, first-click close button behavior, horizontal drag scrolling, and drag-to-raise.
- A visibly changing window, such as playing video, continues to update while its live preview remains open.
- Global shortcuts for closed, running, hidden, frontmost, and no-window apps.
- Window Cycle: forward, backward, repeated cycling, Option-release confirmation, Escape cancellation, card click, close/quit buttons, and immediate shutdown when the setting is disabled.
- Multi-Dock-tile apps: visiting secondary Dock icons should not break previews or click handling for other apps.
- Settings changes for preview enablement, live preview count, Dock click mode, and shortcut enablement.
- Finder right-click extension disabled/enabled gating, multi-item path copying, a writable temporary directory, and a non-writable directory failure.
- Finder right-click commands in an ordinary local directory, plus the expected absence of those commands in File Provider-managed Desktop or Documents locations.

## Review Checklist

Before finishing a change, check:

- Does the change keep Dock short click, long press, and drag behavior distinct?
- Does preview cleanup stop live streams and snapshot streams?
- Does an unchanged `owner PID + CGWindowID` retain its existing capture session across title, frame, and ordering updates?
- Does a stale inventory record fall back to AX + ScreenCaptureKit reconciliation instead of exposing a closed or ambiguous window?
- Are identity-set changes confirmed before adding or removing sessions, except for explicit user actions and process exit?
- Can a provisional static frame appear without stopping its continuous live stream?
- Does the preview close action target only a uniquely identified AX window and avoid keyboard fallbacks?
- Can closed offscreen WindowServer surfaces be rejected without removing valid minimized or hidden windows?
- Does closing a preview tile evict the same window from the hidden snapshot cache?
- Does any new window filtering still exclude dialogs, menu bars, tiny windows, and floating utility panels?
- Does a hidden app with cached snapshots still show useful static previews?
- Does a no-window running app still allow shortcuts to open a new window?
- Does Window Cycle leave Command-Tab and Dock preview event handling untouched, and does its input monitor stop at the end of every session?
- Are tests using neutral app names rather than real third-party product names?
- Are public files free of private workflow notes and local-only paths?
- Is every new dependency or copied asset compatible with GPL v3 and clearly attributed?
- Has every external contributor accepted the CLA before merge?

Public project files should use neutral sample names in tests and examples. Keep private workflow notes out of the repository.
