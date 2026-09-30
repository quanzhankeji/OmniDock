# Release verification

The automated tests cover logic that can be decided from its inputs. They say
nothing about whether a monitor was left installed after a display was
unplugged, or whether the window list still describes reality after the machine
has been asleep. Those answers come from running the build on a real Mac, and
this is the list of what to ask it.

Run this before a release, and after any change to the window inventory, the
permission gates, or the services that install event taps. Record the outcome —
including what was not tried — in [Evidence](#evidence). A scenario nobody ran
is not a scenario that passed.

## What to record

Every run needs the build, the machine and the screens, because most of what
this list is looking for only goes wrong in one arrangement:

- macOS version and hardware
- Build configuration and signing identity (Developer ID or Apple Development —
  they resolve to different code requirements, and TCC keys its grants to them)
- Display arrangement: built-in only, external only, or both; scaling; whether
  *Displays have separate Spaces* is on
- Which permissions were granted at the start

## Scenarios

### System state

| # | Do this | Expect |
|---|---|---|
| S1 | Sleep and wake | Window list describes the windows that exist now; no monitor stops working |
| S2 | Lock and unlock | As above; nothing re-prompts for permission |
| S3 | Plug in and unplug an external display | Old previews close without confirming a selection; newly invoked previews use an existing screen and fresh geometry |
| S4 | Change resolution or scaling | Old interactions end; reopened panels fit the new visible bounds without clipping or spilling |
| S5 | Enter and leave a full-screen Space | Full-screen windows are listed as such, not as missing |
| S6 | Toggle *Displays have separate Spaces* | Window and display state remain readable; unavailable Space membership is not guessed or used to exclude windows |

The three preview entries now observe system/display sleep and user-session
transitions. They cancel their current interaction and pause input monitoring;
resuming permits new interactions rather than reopening an old selection.
Display-parameter changes also cancel old interactions, invalidate cached
window geometry and capture queries, and rebuild Dock hit testing. New
interactions read the current screens; no old selection is restored or
confirmed. S1-S4 still need physical-device acceptance.

### Display configuration changes

Repeat for Dock hover, enhanced Command-Tab and Option-Tab, with image previews
and metadata-only navigation. Use bottom, left and right Dock placements,
external displays on either side or above the primary screen, and a smaller
remaining display. These notifications use the application notification center,
not the workspace center used for sleep and session changes.

| # | Do this | Expect |
|---|---|---|
| D1 | Disconnect or reconfigure a display while each preview is open | The old panel, captures and active interaction end without focusing the selected window; a new invocation fits the current screen |
| D2 | Change display configuration while the window list, capture query or focus request is pending | Late results cannot restore the old panel, geometry or focus request; a new query does not wait for the old capture query |
| D3 | Change displays while holding Option-Tab, then release Option or press Return | The cancelled selection is not confirmed; the next Option-Tab invocation starts a fresh session |
| D4 | Change displays during a pending short Dock click, then try normal clicks, long press and dragging | The old click is not replayed at its obsolete coordinates; later short clicks use fresh targets, while long press and dragging remain system operations |
| D5 | Change screens while preview monitoring is suspended, disabled or lacks required permission | Display changes do not resume a suspended service, enable a feature, or bypass its permission gate |
| D6 | Repeat hot-plugging, scaling and app restart, then reopen previews | No duplicate observers, stale windows, incorrect display labels, stuck input interception or surviving capture sessions |

Automated tests use isolated notifications, delayed query completions and
synthetic geometry. D1-D6 require real display changes; passing these tests
does not establish hardware notification timing or cross-version behavior.

### Workspace interruptions

Repeat for Dock hover, enhanced Command-Tab and Option-Tab, with and without
Screen Recording. The notifications come from the workspace notification center:
[system sleep](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification),
[display sleep](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification),
and [user-session switching](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification).
User-session switching is not treated as proof of lock-screen detection.

| # | Do this | Expect |
|---|---|---|
| I1 | Sleep with each preview open, then wake | The old panel, captures and interaction input monitoring stop; waking does not confirm or reopen the old selection |
| I2 | Sleep the display while holding Option-Tab, then wake it | The old keyboard interaction is cancelled; a new Option-Tab invocation can start a fresh session |
| I3 | Switch to another user and back | No stale preview or queued input returns; enabled monitoring becomes available again |
| I4 | Combine display sleep, system sleep and user switching | One resume signal does not clear another outstanding suspension |
| I5 | Disable a feature or revoke a required permission before resuming | It remains unavailable, and the saved feature choice is not overwritten |
| I6 | Interrupt while the first window list or a focus request is pending | Late callbacks do not show an old panel or focus the old target |
| I7 | Repeat interruptions, then stop and restart the app | No duplicate callbacks, stuck keyboard interception, or permission-recovery relaunch caused by an intentional pause |

The automated tests deliver synthetic notifications to isolated centers; they
do not sleep the host, switch users, or prove notification ordering on every
supported macOS version. Also record S2 separately and test launch in an
already inactive user session.

### Window lifecycle

| # | Do this | Expect |
|---|---|---|
| W1 | Open and close windows while a preview is showing | The panel follows; closed windows leave it |
| W2 | Quit an application that had windows listed | Its entries go, and nothing else does |
| W3 | Relaunch that application | Its windows come back once, not twice |
| W4 | Minimise, hide, and restore | State is shown accurately and the window is still reachable |
| W5 | Close the final listed window while Option-Tab remains open | The panel dismisses, input monitoring ends, and no window is focused; a temporary AX read failure alone must not clear the panel |
| W6 | Open a first window in an app with no windows, or launch another app, while Option-Tab is open | Its independent windows join the list once, the current selection stays on the same surviving window, and a delayed capture surface can use a metadata card |
| W7 | Trigger a window change, then cancel or disable Option-Tab before the refresh arrives | No delayed panel or focus action appears; reopening the switcher starts a fresh session |

A ghost window — one listed after it is gone — and a lost window — one missing
while it is on screen — are both failures here. Note which.

### Preview window status

Repeat these in Dock, enhanced Command-Tab, and Option-Tab previews, with
both thumbnail capture and metadata-only navigation.

| # | Do this | Expect |
|---|---|---|
| V1 | Keep a preview open and repeatedly minimize/restore a window after capturing a thumbnail | The minimized label updates beside the cached image without replacing the card or selected window; metadata-only placeholder text also follows the state |
| V2 | Hide an app with both minimized and normal windows, then restore it while the preview remains open | App-hidden and minimized are independent; repeated visibility notifications clear stale labels without requiring the panel to reopen |
| V3 | Enter native full screen, leave it, then maximize without entering full screen | Full screen appears only when reported by the owning app's Accessibility interface; maximized size alone does not produce the label |
| V4 | Move windows between screens arranged left, right, above, and below the primary screen | The label follows the largest overlap of the latest known window frame; equal overlap and unknown geometry stay unknown |
| V5 | Disconnect a screen while the panel is open, then reopen the panel | Display labels use the current screen list; record placement and stale-window geometry separately under S3 |
| V6 | Use long app, window and display names in Light and Dark appearance | Status text truncates within its own row, full text is available in the tooltip, and titles, thumbnails and action buttons do not overlap |

These labels do not establish Space membership. No window is removed from the
list based on the new status metadata, and no Space/display filter is added.
Hidden, minimized and cached windows can retain their last observed frame or
full-screen state until a matching Accessibility observation arrives. Visible
cards refresh from coalesced window/workspace events, not a new polling timer.
Ambiguous matches remain unchanged. If a Space/display transition cancels a
preview session, status callbacks must not reopen it. Geometry and synthetic
notification tests do not replace a real multi-display or full-screen acceptance
run.

### Exact window focus

Repeat these through a Dock thumbnail, an enhanced Command-Tab thumbnail,
and an Option-Tab selection. Native Command-Tab release remains a system action.

| # | Do this | Expect |
|---|---|---|
| F1 | Select each of two windows with the same title | Only the selected window becomes focused; an ambiguous identity does not select another window |
| F2 | Select a hidden or minimised window | Its application becomes frontmost, and that exact window is focused and no longer minimised |
| F3 | Start another switch immediately after making a selection | The older retry stops, including when the new switcher is still loading its window list |
| F4 | Close the target between selection and confirmation | No remaining window is substituted for the closed target |
| F5 | Quit and relaunch the target application during selection | No old request acts on the new process instance |
| F6 | Select a stale or unresolvable target | An unconfirmed result is not remembered as success; brief failure feedback disappears without reopening capture sessions |
| F7 | Open a new preview while old failure feedback is pending | The old result cannot replace the new cards, and its expiry cannot hide them |

Focus confirmation reads the application's focused AX window, foreground
process, and minimised state. Accepting an AX raise request is not sufficient.
Retries remain bounded to three attempts; new OmniDock foreground requests or
switcher sessions cancel them. Automated tests use controlled observations and do not establish that
third-party applications expose accurate AX state on every macOS version.

### Teardown

| # | Do this | Expect |
|---|---|---|
| T1 | Open and dismiss the switcher quickly, many times | No capture session survives the last dismissal |
| T2 | Turn each feature off in Settings | Its event tap and its captures stop |
| T3 | Revoke a permission while the app runs | The feature's switch keeps the user's choice. Missing basic permissions stop the affected service; missing Screen Recording stops capture but retains title/icon navigation. Settings shows the missing capability and an authorization action |
| T4 | Grant it again | Enabled features reconcile automatically when the process observes the grant; unrelated choices, such as live capture being off, stay unchanged. Record any system-required relaunch separately |
| T5 | Quit the app with a preview open | Nothing is left behind: no tap, no capture, no panel |

T1 and T2 are looking for a leak the tests cannot see. The teardown paths were
read for this list and are sound on paper; that is not the same as watching
them run.

### Preview permission capabilities

Test all three entries: Dock hover, enhanced Command-Tab, and Option-Tab.
Only windows exposed by the target application's Accessibility interface can
appear without Screen Recording; an empty inventory must not create an empty
preview panel.

| # | Do this | Expect |
|---|---|---|
| P1 | Grant Accessibility, but not Screen Recording or Input Monitoring | Dock hover and enhanced Command-Tab offer window titles, app icons, minimized state and exact-window selection without starting capture. Option-Tab and Dock click toggling remain unavailable |
| P2 | Also grant Input Monitoring, still without Screen Recording | Option-Tab offers the same metadata-only navigation. No cached or newly captured window image appears in any of the three entries |
| P3 | Revoke Screen Recording with each preview open | Captures stop, late image callbacks are ignored, old images are cleared, and metadata remains available after permission reconciliation |
| P4 | Grant Screen Recording again | Image previews resume according to the saved live/static preference when the grant becomes visible to the process. Record a macOS-required restart as such |
| P5 | Revoke a basic permission, then turn the affected feature off before granting it again | Its saved switch stays off; granting permission does not override that choice |
| P6 | Change permissions while enhanced Command-Tab is open and Option-Tab is disabled | The inactive service does not dismiss the other entry's shared panel |

P1-P6 require real permission changes, not only injected snapshots in unit
tests. Include first-launch and upgraded settings with pending permission
intent; upgrading should restore only the feature's own saved choice once.

### Menu bar shelf

| # | Do this | Expect |
|---|---|---|
| M1 | Turn the shelf off and on several times | Both items come back every time |
| M2 | Drag the divider past the arrow, then collapse | The controls return rather than disappearing with the icons |
| M3 | Hold Command and drag icons for longer than the auto-hide delay | The shelf stays open until the dragging stops |

### Dock-to-preview pointer movement

| # | Do this | Expect |
|---|---|---|
| H1 | Move straight or diagonally from a Dock icon to the near and far cards of a wide preview, both slowly and quickly | The preview remains usable along the route |
| H2 | Move into empty desktop space beside the icon and outside the route to the panel | The preview closes after the existing short exit grace; the empty corners of the icon/panel bounding rectangle do not keep capture alive |
| H3 | Move onto another running app, an unopened app, or a non-previewable Dock item while a preview request is pending | The old preview is dismissed; a late response does not reopen it |
| H4 | Drag the preview list horizontally, then drag a file onto a card | Horizontal scrolling does not activate a window; file entry still activates the matched window and dismisses the preview |
| H5 | Repeat H1-H3 with left/right Dock placement, magnification, auto-hide and an external screen | The route follows the actual icon and panel; no stuck panel or inaccessible cards |
| H6 | Stop or disable Dock previews with a visible panel or pending response | Dock-owned content and captures are released; pending responses are invalidated |
| H7 | Stop Dock preview monitoring while enhanced Command-Tab or Option-Tab owns the shared panel | The active switcher's panel remains intact until its own lifecycle ends |

Geometry tests with rotated rectangles and negative coordinates cover the
retention calculation, not real Dock animation or multi-display behavior.
H1-H7 still require pointer-based acceptance on the installed build.

### Window switcher keyboard navigation

These controls apply only while OmniDock's Option-Tab switcher is active.
Repeat with image previews and metadata-only navigation, not just with
injected input in automated tests.

| # | Do this | Expect |
|---|---|---|
| K1 | Hold Option and navigate a multi-row grid with the arrow keys | Movement follows the actual rows/columns; edges do not wrap, and a short last row selects the nearest available cell |
| K2 | Navigate a long list past the visible rows and back to the first row | The selected card stays in view; selection remains valid if the list changes |
| K3 | Use Tab and Shift-Tab, then confirm with Return, keypad Enter, or release Option | Tab retains its wraparound behavior; exactly the selected window is requested, once; panel and input monitoring end |
| K4 | Press Esc, then immediately open another switcher session | The cancelled selection is not focused and queued input from the old session cannot move or confirm the new one |
| K5 | Disable the feature or revoke Input Monitoring with the switcher open | The panel and input monitor stop without focusing the current selection |
| K6 | Use ordinary letters, Command/Control combinations, and normal typing after dismissal | No W/Q/M/H action or search handler consumes them; shortcuts and input outside the active switcher remain system/application operations |
| K7 | Exercise native Command-Tab and Dock previews after Option-Tab closes | No Option-Tab input handler or panel ownership remains |

The input state machine cancels on a disabled event tap rather than confirming
from incomplete modifier state. Synthetic interruption tests do not prove
every system input-monitoring recovery path. Inline keyboard help, action keys
for close/minimize/hide/quit, and title filtering are not part of this batch.

## Known gaps

Found by reading the source for this list, not by reproducing a failure. They
are written down so a run can look for them, not as promises to change
anything.

- **Physical interruption acceptance remains open.** Runtime system/display
  sleep and user-session notifications now pause preview interactions. Lock
  notification delivery, inactive-session startup and real inventory/capture
  recovery still need verification on supported systems.
- **Physical display-change acceptance remains open.**
  `NSApplication.didChangeScreenParametersNotification` now invalidates window
  snapshots and in-flight capture queries, cancels preview interactions and
  rebuilds Dock hit testing. Recovery starts from a new user interaction,
  rather than relocating an old selection. D1-D6 still need verification on
  real displays and supported macOS versions.
- **Space membership is not established.** The app observes
  `activeSpaceDidChangeNotification`, which says when to refresh, not which
  Space a window belongs to. No Space-membership label or filter is offered.

## Evidence

Each run appends an entry. Keep the ones that found nothing: a scenario that
has passed on three machines and fails on a fourth is worth being able to see.

### 2026-09-21 · source audit only

- Verified: 708 automated tests pass; the generated Xcode project matches the
  generator; a Release build succeeds.
- Read and found sound: teardown on disable for the window switcher
  (`reconcileRegistration` ends the session, stops the input monitor, stops
  every capture session, unregisters the hotkey).
- Recorded as gaps: the three above.
- **Not run:** every scenario in this document. No sleep, wake, display change,
  Space change, or lifecycle scenario was exercised on hardware. This entry is
  an audit, not a verification, and does not satisfy the release check.

### 2026-09-21 · local build and installation check

- Source: `2732cea`, including the permission recovery fix `66713c1`;
  version `1.2.9`, build `19`, Release configuration.
- Host: macOS `26.6.2` (`25G83`), Apple silicon (`Mac17,9`), arm64 build.
  Display arrangement and effective permissions were not verified in the UI.
- Passed: 708 tests with warnings treated as errors; strict SwiftPM Release
  and Xcode app/extension builds; generated-project consistency; staged bundle
  validation; installed app and nested extension strict signature checks.
- Replaced the installed `1.2.8` with `1.2.9` after archiving the old bundle.
  Both new signatures satisfy the old bundles' designated requirements and
  retain Developer ID signing. No privacy permissions were reset.
- The new app and Finder extension processes started from the installed
  location. Finder Sync lists one registration for that location. A short
  process sample showed the main run loop processing events and waiting for
  work, with no sustained main-thread stall during that sample.
- Fourteen selected preference keys, including pending permission intent,
  were unchanged across installation. This is not a live permission-revocation
  test and does not establish that every feature currently has permission.
- Packaging note: File Provider metadata on a bundle staged under Documents
  caused strict signature validation to fail. Staging in the system temporary
  directory passed. The local app ZIP passed its archive integrity check.
- **Not run:** all S/W/T/M scenarios above, complete GUI regression, and other
  macOS versions. The UI inspection connection timed out before and after
  installation. No Universal 2 distribution build, notarization, Gatekeeper
  assessment, push, or Release publication was performed. These installation
  checks do not satisfy the full release gate.

### 2026-09-23 · exact-focus implementation and automated regression

- Source: working changes based on `c7be95e`; version `1.2.9`, build `19`.
  Scope is exact focus verification (OD-01) and the regression baseline
  (OD-02). Permission capability redesign is not included.
- Host: macOS `26.6.2` (`25G83`), Apple silicon (`Mac17,9`), arm64 builds.
  Display arrangement and effective privacy grants were not verified.
- Regression-first evidence: two new matching tests failed before the fix,
  showing that a missing named target could select the sole remaining window
  with a different or absent title. Both now pass. A message-panel geometry
  test also reproduced invalid text bounds after dismissal; using the panel's
  actual size corrected the bounds and removed the layout warning.
- Passed: all 729 tests with warnings treated as errors, strict SwiftPM Release
  build, strict Xcode Release app/extension build, generated-project
  consistency, staged resource/signature validation, and diff-format checks.
- New tests cover bounded confirmation attempts, delayed confirmation,
  unavailable or unreadable targets, exact-window rather than application-only
  success, superseded requests, cancellation while a new switcher loads,
  stale UI results, message expiry, and preview-content teardown. The focus
  observations are injected in tests; they are not live AX compatibility tests.
- The SwiftPM staged app passed Developer ID signature validation. The separate
  Xcode app and Finder extension passed strict signature verification with
  Apple Development signing. Both builds stayed in a temporary directory;
  the installed application was not replaced or launched from these artifacts.
- **Not run:** F1-F7 against real application windows, all S/W/T/M hardware
  scenarios, and other macOS versions. Desktop UI inspection timed out, so no
  UI acceptance is claimed. No permission reset, Universal 2 distribution
  build, notarization, Gatekeeper assessment, commit, push, or release was
  performed. OD-01 still needs live application acceptance; OD-02 remains open.

### 2026-09-23 · local installation of exact-focus changes

- After the checks above, rebuilt and installed the working changes through
  the local installer. Version remains `1.2.9`, build `19`; no release version
  was changed. All 729 tests passed again before installation.
- Archived the previous installed bundle and verified the archive before
  replacement. The new installed executable differs from the previous one
  and byte-matches the freshly built installation candidate.
- The main app and Finder extension retain Developer ID signing, pass strict
  signature verification, and satisfy their previous designated requirements.
  Their entitlements are unchanged. The installer did not reset privacy
  permissions or delete Library data.
- The new app and extension processes started from `/Applications/OmniDock.app`.
  Finder Sync lists one registered extension, at the installed path. A
  three-second process sample showed the main run loop waiting for and
  processing events, with no sustained main-thread stall in that sample.
- The installation build succeeded. Xcode emitted the metadata-extraction
  warning for targets without an App Intents dependency; no compiler error
  blocked the build.
- **Not run:** interactive F/S/W/T/M acceptance. The desktop UI inspection
  connection still timed out. This confirms build, installation, signing and
  process startup, not full feature compatibility. No commit, push, remote
  release, notarization, or virtual-machine installation was performed.

### 2026-09-23 · Dock application identity matching

- Reproduced a pre-existing target-selection bug: a running application's
  bundle suffix such as `desktop` could match a word in another Dock tile's
  title. Selection depended on running-application order, so unrelated tiles
  could display the same application's windows. This resolver is shared by
  hover previews and Dock click routing.
- Complete application names now take priority over wrapped names and bundle
  aliases. Bundle suffix fallback requires the whole normalized Dock title;
  ambiguous matches no longer select the first process. No application-specific
  exceptions were added, and capture, cache, and focus behavior are unchanged
  by this fix.
- Added nine regression tests. They failed against the previous resolver;
  after the fix, all 72 focused Dock tests and all 738 tests passed with
  warnings treated as errors. The strict SwiftPM Release build and local
  Xcode app/extension build passed. The Xcode build emitted only the existing
  App Intents metadata-extraction warnings for targets without that dependency.
- Rebuilt, backed up the previous app, and replaced and launched
  `/Applications/OmniDock.app`. Version remains `1.2.9`, build `19`. The new
  executable differs from the previous installation and matches the fresh
  build candidate. Both the main app and extension pass strict signature
  verification and their previous designated requirements; entitlements are
  unchanged. Finder Sync has one registered extension at the installed path.
- **Not run:** live hover/click acceptance and other macOS versions. The
  desktop UI connection timed out. Confirm both affected Dock tiles display
  only their own windows, and that moving onto an app without previewable
  windows dismisses the previous preview. No privacy reset, Library data
  cleanup, commit, push, notarization, or release was performed.

### 2026-09-23 · local preview confirmation

- After installing the Dock identity fix, the local tester reported that
  previews now work correctly. This confirms the reported wrong-application
  preview symptom is resolved in that local check.
- This report does not establish that the complete exact-focus, lifecycle,
  permission, display, or cross-version matrix passed. Those broader
  acceptance items remain open.

### 2026-09-24 · permission capabilities and preference preservation

- Source: working changes based on `58e944b`; version `1.2.9`, build `19`.
  Scope is metadata-only navigation (OD-03) and preserving feature preferences
  while permissions are unavailable (OD-22).
- Host: macOS `26.6.2` (`25G83`), Apple silicon (`Mac17,9`), arm64 builds.
  Display arrangement and effective privacy grants were not verified.
- Passed: all 746 tests with warnings treated as errors, strict SwiftPM
  Release build, Xcode Release app/extension build with compiler warnings
  treated as errors, generated-project consistency, staged SwiftPM bundle
  resource/plist/signature validation, and `git diff --check`.
- Automated coverage includes all 32 permission combinations, preserving
  switches, one-time restoration of older pending intent, a manual off choice
  surviving reauthorization, and no ScreenCaptureKit query or image-cache
  reuse without recording permission. Injected mid-request revocation falls
  back to Accessibility metadata; reauthorization can query capture again on
  the same service instance.
- Regression-first tests also reproduced an inactive switcher dismissing
  another entry's shared panel, metadata cards exceeding their panel height,
  and an old screenshot surviving replacement by a metadata-only card. These
  cases now pass, including first presentation and panel reuse.
- The staged SwiftPM app was ad-hoc signed for local bundle validation. The
  Xcode app/extension build used `CODE_SIGNING_ALLOWED=NO`; this is compilation
  evidence, not distribution-signing or Gatekeeper evidence. Xcode emitted
  its metadata-extraction warning for targets without an App Intents
  dependency; no compiler warnings or errors blocked the build.
- **Not run:** real TCC grant/revocation (P1-P6), complete F/S/W/T/M interactive
  acceptance, or other macOS versions. No installed app replacement, staged
  app launch, privacy reset, Universal 2 distribution build, notarization,
  Gatekeeper assessment, commit, push, or release was performed. OD-03 and
  OD-22 remain open pending real permission-transition acceptance.

### 2026-09-24 · local installation of permission-capability changes

- Rebuilt the current working changes through the complete local installer
  and replaced `/Applications/OmniDock.app`. Version remains `1.2.9`, build
  `19`. All 746 tests passed again with compiler warnings treated as errors.
- Archived the prior app bundle and verified archive integrity before
  replacement. The installed executable differs from the previous executable
  and matches the freshly built installation candidate byte-for-byte.
- Main app and Finder extension retain Developer ID signing, pass strict
  signature validation, and satisfy the prior bundles' designated
  requirements. Both entitlement sets are unchanged. No privacy reset or
  deletion of Library data was performed.
- Both processes started from the installed bundle and remained running after
  one minute. Finder Sync lists one registered extension at the installed
  path. A three-second process sample showed the main thread waiting for and
  processing events, without a sustained main-thread stall during the sample.
- Build and generated-project checks passed. Xcode emitted only the known
  metadata-extraction warnings for targets without an App Intents dependency.
- **Not run:** real permission-transition scenarios P1-P6, complete interactive
  regression, or other macOS versions. This is installation and startup
  evidence, not full feature acceptance. No commit, push, notarization, or
  Release publication was performed.

### 2026-09-24 · Dock preview retention and stop cleanup

- Source: working changes based on `58e944b`; version `1.2.9`, build `19`,
  including the uncommitted permission-capability changes above. This batch
  addresses pointer retention (OD-05) and a related lifecycle case (OD-02).
- Host: macOS `26.6.2` (`25G83`), Apple silicon (`Mac17,9`), arm64 builds.
  Display arrangement and effective privacy grants were not verified.
- Regression-first tests reproduced unrelated desktop corners retaining a
  wide preview, and stopping the Dock service leaving its panel and content
  visible. Retention now follows the convex outline of the icon and preview,
  preserving direct diagonal routes, the 18-point margin, and the existing
  0.22-second exit grace. Stopping the service clears its hover state,
  invalidates pending preview requests, and releases Dock-owned panel content
  without dismissing a panel owned by another switcher.
- Passed: 48 focused tests, all 752 tests with warnings treated as errors,
  strict SwiftPM Release build, Xcode Release app/extension build with compiler
  warnings treated as errors, generated-project consistency, staged SwiftPM
  bundle resource/plist/signature validation, and diff-format checks.
- Geometry tests cover direct diagonal routes, left and right Dock rotations,
  negative screen coordinates, overlapping rectangles, and retention margins.
  Lifecycle tests exercise native panels with injected callbacks; neither
  these tests nor coordinate simulations establish real multi-display or
  pointer-interaction acceptance.
- The staged SwiftPM app used ad-hoc signing; the Xcode build used
  `CODE_SIGNING_ALLOWED=NO`. Xcode emitted the known metadata-extraction
  warnings for targets without an App Intents dependency. These checks are
  compilation and local bundle validation, not distribution-signing evidence.
- **Not run:** live pointer scenarios H1-H7, broader lifecycle and permission
  acceptance, or other macOS versions. The desktop UI inspection connection
  timed out. OD-05 remains open pending live pointer acceptance.
- The installed executable's SHA-256 is unchanged. No installed app replacement,
  staged app launch, privacy reset, commit, push, notarization, or release was
  performed in this batch.

### 2026-09-24 · local installation of preview-retention changes

- Rebuilt and replaced `/Applications/OmniDock.app` through the complete local
  installer. Version remains `1.2.9`, build `19`. All 752 tests passed again
  with compiler warnings treated as errors before installation.
- Archived the previous installed app and verified archive integrity. The new
  installed executable differs from the previous one and byte-matches the
  freshly built installation candidate. The installed Finder extension binary
  also matches the candidate.
- Main app and Finder extension retain Developer ID signing, pass strict
  signature verification, and satisfy their prior designated requirements.
  Both entitlement sets are unchanged. No privacy reset or deletion of
  Library data was performed.
- Both processes started from the installed bundle and remained running after
  one minute. Finder Sync lists one registered extension at the installed
  path. A three-second process sample showed the main run loop processing
  events and waiting for work, without a sustained main-thread stall in that
  sample.
- Build, generated-project consistency, and diff-format checks passed. Xcode
  emitted only the known metadata-extraction warnings for targets without an
  App Intents dependency.
- **Not run:** interactive H1-H7, broader permission and lifecycle regression,
  or other macOS versions. Installation and startup checks do not establish
  full feature acceptance. No commit, push, notarization, or release was
  performed.

### 2026-09-24 · preview window status, first phase

- Source: working changes based on `262b7de`; version `1.2.9`, build `19`.
  The earlier permission-capability and preview-retention changes were saved
  in that local commit before this batch began; it has not been pushed.
- Host: macOS `26.6.2` (`25G83`), Apple silicon (`Mac17,9`), arm64 builds.
  Display arrangement and effective privacy grants were not verified.
- The three preview entries now use a compact status row for minimized,
  app-hidden, reported full-screen state and physical display. Minimized and
  hidden remain independent, and a cached thumbnail no longer replaces the
  minimized label. Window metadata survives capture/AX merging and inventory
  conversion without changing window identity, filtering, ordering or focus.
- Regression-first tests reproduced the missing minimized label with a cached
  image, lost hidden/full-screen metadata during merging and conversion, stale
  cached app visibility, and missing hide/unhide inventory invalidation.
  Workspace notification tests are synthetic, not real app hide/restore runs.
- Display labels use Quartz coordinates and unique greatest overlap with the
  latest known frame. Tests cover screens above/below and left of the primary
  screen, ties, mirrored geometry, offscreen windows and invalid rectangles.
  A full-screen label is never inferred from screen-sized geometry.
- Passed: 67 focused tests and all 765 tests with compiler warnings treated
  as errors; strict SwiftPM Release build; Xcode Release app/extension build
  with compiler warnings treated as errors; generated-project consistency;
  staged bundle resource/plist/signature validation; and diff-format checks.
  Native view tests cover state reuse, stable card sizing and status-row
  bounds/truncation with long display names under Aqua and Dark Aqua.
- The staged SwiftPM app used ad-hoc signing. The separate Xcode build used
  `CODE_SIGNING_ALLOWED=NO` and emitted only the known App Intents metadata
  extraction warnings. Neither is distribution-signing or notarization proof.
- Status updates follow each entry's existing window-inventory refresh path;
  a continuously open switcher can retain the last observed state until its
  next refresh or reopening. Screen changes refresh display labels only.
  Space membership and Space/display filtering remain unimplemented.
- **Not run:** V1-V6 with real applications, multi-display/full-screen hardware
  acceptance, broader lifecycle and permission regression, or other macOS
  versions. These automated checks do not close OD-04's manual acceptance gate.
- The installed executable's SHA-256 is unchanged. This new batch remains
  uncommitted. No installed app replacement, staged app launch, privacy reset,
  push, Universal 2 distribution build, notarization or release was performed.

### 2026-09-24 · window switcher keyboard navigation, first phase

- Source: working changes based on `262b7de`, including the uncommitted
  preview-status batch above; version `1.2.9`, build `19` is unchanged.
- Host: macOS `26.6.2` (`25G83`), Apple silicon (`Mac17,9`), arm64 builds.
  Display arrangement and effective privacy grants were not verified.
- The independent Option-Tab switcher now accepts arrow keys using its actual
  grid columns and Return/keypad Enter to confirm the selected window. Tab and
  Shift-Tab retain wrapping; arrows stop at grid edges. Option release confirms
  and Esc cancels as before. Native Command-Tab and Dock behavior are unchanged.
- Input state rejects callbacks from an earlier session after stop/restart,
  finishes each session only once, and cancels when the system disables its
  event tap. Ordinary letters and Command/Control combinations are not mapped
  to window actions. Destructive action keys, title filtering and inline
  keyboard help remain outside this batch.
- Regression-first tests covered key mapping, grid navigation, cancellation,
  interrupted monitoring and integration with exact-window focus. Service
  tests use injected hotkey/input monitors and window inventory; interruption
  and permission-loss tests are synthetic, not real TCC or hardware events.
  Native panel geometry tests verify scrolling to the first and last selected
  cards in a 70-window grid.
- Passed: 51 focused tests and all 773 tests with compiler warnings treated as
  errors; strict SwiftPM Release build; Xcode Release app/extension build with
  compiler warnings treated as errors; generated-project consistency; staged
  bundle resource/plist/signature validation; and diff-format checks.
- The staged SwiftPM app used ad-hoc signing. The separate Xcode build used
  `CODE_SIGNING_ALLOWED=NO` and emitted only the known App Intents metadata
  extraction warning. These checks are not distribution-signing evidence.
- **Not run:** real keyboard scenarios K1-K7, broader pointer and permission
  regression, or other macOS versions. OD-07's manual acceptance remains open.
- The installed executable's SHA-256 is unchanged. No installed app
  replacement, staged app launch, privacy reset, commit, push, Universal 2
  distribution build, notarization or release was performed.

### 2026-09-24 · local installation of preview status and keyboard navigation

- Rebuilt and replaced `/Applications/OmniDock.app` through the complete local
  installer. Version remains `1.2.9`, build `19`, including both uncommitted
  batches above. All 773 tests passed again with compiler warnings treated as
  errors before installation.
- Archived the previous installed app and verified archive integrity. The
  installed executable differs from the previous one and byte-matches the
  freshly signed installation candidate. The installed Finder extension
  binary also matches the candidate.
- Main app and Finder extension retain Developer ID signing, pass strict
  signature verification, and satisfy their prior designated requirements.
  Their entitlement sets are unchanged. No privacy reset or deletion of
  Library data was performed.
- Both processes started from the installed bundle and remained running for
  over one minute. Finder Sync lists one registered extension at the installed
  path. A three-second sample showed the main run loop waiting for events and
  processing work without a sustained main-thread stall during that sample.
- Build, generated-project consistency, and diff-format checks passed. Xcode
  emitted only the known metadata-extraction warnings for targets without an
  App Intents dependency.
- **Not run:** interactive K1-K7 or V1-V6, broader pointer and permission
  acceptance, or other macOS versions. Installation and startup checks do not
  establish complete feature acceptance. No commit, push, notarization or
  release publication was performed.

### 2026-09-25 · runtime workspace interruption handling

- Source: working changes based on `262b7de`, including the earlier uncommitted
  preview-status and keyboard-navigation batches. Version remains `1.2.9`,
  build `19`; host is macOS `26.6.2` (`25G83`), `Mac17,9`, arm64.
- Regression-first tests reproduced Option-Tab retaining its panel and input
  monitor after a sleep notification, with a late confirmation still requesting
  focus. Separate tests reproduced missing suspension cleanup in Dock and
  enhanced Command-Tab. The permission-recovery policy also incorrectly treated
  intentional monitor suspension as an attachment failure.
- Three preview entries now track overlapping system/display sleep and user
  session interruptions. Suspending cancels the active interaction and pending
  focus, stops its captures/input monitoring and invalidates pending work.
  Resume permits new interactions only after every suspension reason clears,
  respecting current settings and permissions. It does not restore the old
  selection. Intentional suspension no longer requests a recovery relaunch.
- Passed: 55 focused tests and all 780 tests with compiler warnings treated as
  errors; strict SwiftPM Release build; Xcode Release app/extension build with
  compiler warnings treated as errors; generated-project consistency; staged
  bundle resource/plist/signature validation; and diff-format checks.
- Tests use isolated notification centers, injected input/hotkey boundaries,
  a synthetic Command-Tab provider, and native preview panels. They cover
  overlapping and duplicate notifications, stop/restart, disabled preferences,
  revoked input permission, and cancellation while the inventory is pending.
  They do not put the host to sleep or change its privacy grants.
- The staged SwiftPM app uses ad-hoc signing. The Xcode build uses
  `CODE_SIGNING_ALLOWED=NO` and emits the known App Intents metadata-extraction
  warnings. Neither check establishes distribution-signing acceptance.
- **Not run:** physical I1-I7, S1-S4, inactive-session startup, real lock-screen
  notification delivery, capture recovery on other macOS versions, or broader
  pointer regression. OD-02 remains open for these acceptance checks.
- The installed executable's SHA-256 is unchanged. No installed app replacement,
  staged app launch, permission reset, commit, push, notarization or release was
  performed.

### 2026-09-25 · local installation of workspace interruption handling

- Rebuilt and replaced `/Applications/OmniDock.app` with all current working
  changes, including preview status, keyboard navigation and workspace
  interruption handling. Version remains `1.2.9`, build `19`.
- All 780 tests passed again with compiler warnings treated as errors. The
  complete local app/extension build, generated-project consistency and
  diff-format checks passed. Xcode emitted only the known App Intents
  metadata-extraction warnings.
- Archived the previous installation and verified archive integrity. Both
  installed binaries byte-match the freshly signed installation candidate;
  the main executable differs from the previous installation.
- Main app and Finder extension pass strict signature verification for all
  included architectures and satisfy their prior designated requirements.
  Developer ID identity and entitlement sets are unchanged. No privacy reset
  or deletion of Library data was performed.
- Both installed processes remained running for over one minute. Finder Sync
  lists one registered extension at the installed path. A three-second sample
  showed the main run loop mostly waiting for events, without a sustained
  main-thread stall during that sample.
- **Not run:** interactive I1-I7, S1-S4, K1-K7 or V1-V6, multi-display and
  permission acceptance, or other macOS versions. Installation and startup
  checks do not establish complete feature acceptance. No commit, push,
  notarization or release publication was performed.

### 2026-09-27 · display-change invalidation and interaction cancellation

- Source: working changes based on `262b7de`, including the earlier uncommitted
  preview-status, keyboard-navigation and workspace-interruption batches.
  Version remains `1.2.9`, build `19`; host is macOS `26.6.2` (`25G83`),
  `Mac17,9`, arm64.
- Six regression-first tests failed before the fix. They reproduced retained
  Dock/Command-Tab panels, late Option-Tab confirmation and presentation,
  acceptance of old inventory requests, and new capture queries waiting on
  the previous display configuration's query.
- Application-level display notifications now cancel all three preview
  interactions and pending focus. The inventory discards cached snapshots and
  rejects pre-change request revisions, including requests for processes not
  previously listed. Focus recency is preserved when fresh geometry arrives.
- Dock hit testing is recreated with new screen transforms; pending clicks
  are discarded without replaying their old coordinates. Normal click,
  long-press and drag policies are unchanged. Outstanding capture queries are
  invalidated and their callers completed; old replies cannot populate the
  cache or consume a new query's completions.
- Eleven new tests cover these changes, observer start/stop and duplicate
  registration, suspension/permission boundaries, focus-order preservation,
  pending gesture disposal and reopened layouts with stale anchors. Passed:
  128 focused tests and all 791 tests with compiler warnings treated as errors;
  strict SwiftPM Release and Xcode app/extension builds; generated-project
  consistency; staged resource/plist/signature validation; and diff checks.
- The staged SwiftPM bundle uses ad-hoc signing; the Xcode build uses
  `CODE_SIGNING_ALLOWED=NO`. Xcode emitted only the known App Intents
  metadata-extraction warnings. These checks do not validate distribution
  signing or replace interactive testing.
- **Not run:** physical D1-D6, I1-I7, real permission changes, exact-focus
  acceptance with third-party apps, or other macOS versions. OD-02 remains
  open for hardware acceptance; no real display arrangement was changed.
- The installed executable's SHA-256 is unchanged. No installed-app
  replacement, staged-app launch, privacy reset, version change, commit, push,
  notarization or release publication was performed.

### 2026-09-27 · local installation of display-change handling

- Rebuilt and replaced `/Applications/OmniDock.app` with all current working
  changes, including display-change invalidation and interaction cancellation.
  Version remains `1.2.9`, build `19`; the installation is arm64 on macOS
  `26.6.2` (`25G83`). Source, resource and project-file hashes are unchanged
  across the build/install operation.
- All 791 tests passed again with compiler warnings treated as errors. The
  app/extension Release build, generated-project consistency and diff checks
  passed. Xcode emitted only the known App Intents metadata-extraction warnings.
- Archived the previous installation and verified archive integrity. The
  installed main executable differs from the previous installation; both
  installed binaries byte-match the newly signed installation candidate.
- Main app and Finder extension pass strict signature verification for all
  included architectures and satisfy their prior designated requirements.
  Developer ID identity and entitlement sets are unchanged. No privacy reset
  or deletion of Library data was performed.
- Both processes remained running from the installed bundle for over one
  minute. Finder Sync lists one registered extension at the installed path.
  A three-second sample showed the main run loop mostly waiting for events,
  without a sustained main-thread stall during that sample.
- **Not run:** physical D1-D6/I1-I7, real permission changes, exact-focus
  acceptance with third-party apps, or other macOS versions. Installation and
  startup checks do not close OD-02. No commit, push, notarization or release
  publication was performed.

### 2026-09-27 · installed-app UI smoke acceptance

- Tested the installed `1.2.9` / build `19` on macOS `26.6.2` (`25G83`).
  The external and built-in displays are mirrored, not an extended desktop.
  The main executable still matches the preceding installation; the app and
  Finder extension remained running. Strict signature verification passed.
- The app's permission review reports Accessibility, Input Monitoring and
  Screen Recording as enabled. No feature switches or privacy grants were
  changed. This is not a permission-revocation or permission-recovery test.
- Two disposable TextEdit documents share a filename but have different
  contents. Both were listed with distinct rendered thumbnails. Arrow-key
  navigation visibly selected the upper-left card in the multi-row grid;
  this does not cover all grid edges or scrolling cases in K1-K2.
- Five repeated Option-Tab/Esc cycles dismissed the panel and retained the
  original test document and foreground app. Ordinary numeric input reached
  TextEdit after dismissal. A subsequent Command-Tab/Esc cycle opened and
  dismissed the enhanced panel without changing the original foreground app.
  These observations cover parts of K4, K6 and K7, not their complete matrix.
- **Inconclusive / acceptance still open:** exact-window confirmation F1 and
  K3 did not establish a reliable pass. After visually selecting fixture A,
  subsequent queries still identified fixture B as TextEdit's main window;
  foreground samples also changed between the test app and other apps during
  the run. Input-automation effects and concurrent desktop interactions were
  not isolated, so neither a successful focus nor a runtime-code regression
  is claimed. Repeat with controlled input and verify the actual focused
  window identity immediately after each confirmation.
- Dock control clicks did not reliably exercise the real pointer event path.
  Dock hover transitions, repeated-click hide/restore, and pointer-to-preview
  retention remain unverified. Early fixed-delay keyboard probes were also
  inconclusive; only the later explicit observations above count as evidence.
- **Not run:** physical D1-D6/I1-I7, sleep/lock/user switching, display changes,
  revoked-permission/title-only mode, the remaining focus/status cases, or
  other macOS versions. The macOS 15 virtual machine was suspended and was
  not resumed. No P0 acceptance gate is closed by this smoke test.
- All temporary test documents and review windows were closed, and synthetic
  modifier holds were released. Existing user documents were not closed.
  Local scripts and logs remain in the ignored acceptance directory. No
  runtime code change, rebuild, installation, commit, push or release occurred.

### 2026-09-28 · macOS 15 virtual-machine smoke acceptance

- Replaced guest `1.2.8` / build `18` with the verified `1.2.9` / build `19`
  installation candidate on macOS `15.6.1` (`24G90`), arm64, one virtual display.
  Kept a rollback copy. The transferred archive and installed executables match
  the host candidate hashes; strict/deep/all-architecture signature checks and
  compatibility with the old app's designated requirement passed. The host
  installation was not replaced.
- The guest app reports all five permissions enabled after replacement. Feature
  preferences, privacy grants and Library data were not changed. This verifies
  continuity after installation, not revoked-permission recovery.
- Enhanced Command-Tab rendered the Finder window and two same-named TextEdit
  fixture windows with distinct thumbnail contents. The display status line
  identifies the virtual display. Five consecutive Command-Tab/Esc cycles
  dismissed the panel without changing the foreground app; ordinary text input
  reached the fixture document afterward.
- **Still open:** exact-window pointer confirmation was not established through
  a reliable input path. Dock hover retention and repeated-click hide/restore
  remain unverified. Alt-Tab and Dock hide/show were originally disabled in the
  guest and were preserved; those paths require a separate enabled-feature test.
- **Not run:** permission revocation/recovery, physical sleep/wake, lock or user
  switching, display reconfiguration and independent multi-display cases. No P0
  gate is closed by this smoke test. Temporary test windows were closed and
  modifier holds released; existing documents were left untouched. No runtime
  change, commit, push or release publication occurred.

### 2026-09-28 · event-driven preview status refresh

- Dock, enhanced Command-Tab and Option-Tab share a visible-panel status
  observer. Coalesced Accessibility/workspace events refresh minimized, hidden,
  full-screen and frame metadata without restarting capture or rebuilding cards.
  Metadata-only window loads now seed the inventory and its AX tracking.
- Added 12 regressions covering repeated visibility changes, metadata-only
  inventory seeding, in-place panel updates, retained live images, late snapshot
  state, queued-work cancellation, removed cards, minimize/restore placeholders,
  and ambiguous or cross-process identities. An unnumbered AX record must match
  exactly one visible card in both directions before supplying state.
- **Passed on macOS 26.6.2, arm64:** all 803 tests with warnings as errors;
  SwiftPM Release and Xcode Release app/Finder-extension builds with compiler
  warnings as errors; generated-project consistency and diff whitespace checks.
  Xcode reports its existing skipped App Intents metadata-extraction warning;
  this is not a Swift compiler warning or a new framework dependency.
- The SwiftPM staged bundle passed resource and strict ad-hoc signature checks.
  The Xcode build was unsigned. These are local build checks, not Developer ID
  distribution, notarization or release acceptance. The temporary Xcode product
  was unregistered after validation; Finder Sync still has one registered copy
  under the installed application.
- **Still required:** V1-V6 with real applications, full-screen/Space transitions,
  extended displays and macOS 15. Synthetic state notifications do not establish
  those results. This batch did not install or launch a replacement app, change
  feature/permission preferences, push commits or publish a release.

### 2026-09-28 · Option-Tab window lifecycle refresh

- The inventory now observes the dedicated AX window-created notification as
  well as generic creation events. Apps with an empty window list stay tracked
  so their next window can be discovered. Failed AX list reads retain existing
  facts and observers instead of masquerading as confirmed empty lists.
- Option-Tab coalesces create/destroy events and reconciles only the affected
  processes. Surviving windows retain their order and selected identity; removed
  windows release their captures. A confirmed empty final list closes the panel
  and stops input monitoring. Session cancellation invalidates queued work.
- New AX-backed windows can appear as metadata cards before their WindowServer
  surfaces are available. Existing tab/frame deduplication and AX validation of
  residual WindowServer surfaces remain in place.
- Added 12 regressions covering creation notifications, empty-app tracking,
  application launch/termination, event coalescing, retained selection, last-window
  cleanup, cancellation, failed versus empty reads, old snapshot rejection, and
  delayed surfaces without duplicate tabs. Initial failing tests reproduced the
  missed refresh and lingering panel/input monitor.
- **Passed on macOS 26.6.2, arm64:** 82 focused tests, all 815 tests with warnings
  as errors, strict SwiftPM Release and unsigned Xcode Release app/extension
  builds, generated-project consistency and diff whitespace checks. The existing
  skipped App Intents metadata-extraction warnings remain non-blocking.
- Staged resource and strict ad-hoc signature verification passed in a local
  temporary directory. The first staging attempt in the workspace failed because
  Finder metadata had been attached to the bundle; the retry did not alter source
  resources or the installed app. The temporary Xcode product was unregistered;
  only the installed Finder Sync extension remains registered.
- **Not established:** real-application W1-W7, capture continuity during those
  interactions, macOS 15, multi-display, permission changes or sleep/wake
  acceptance. Injected AX results and workspace notifications do not close these
  gates. No installed host/guest app, permissions or feature preferences were
  changed; no commit, push, distribution signing or release was performed.

### 2026-09-29 · enhanced Command-Tab lifecycle and macOS 15 acceptance

- Enhanced Command-Tab now reconciles window creation/removal for the selected
  process without changing the native switcher selection. Surviving cards keep
  their order, images and captures. Confirmed empty lists hide the panel while
  observation continues; failed AX reads retain the last known list. Ending the
  interaction invalidates queued queries and input callbacks. Fresh capture-list
  requests reject superseded results without losing pending completions.
- Horizontal preview layout now sizes the stack before its enclosing panel and
  preserves fixed tile sizes while cards are inserted or removed. A targeted
  debugger run no longer emits the reproduced conflicting-constraint or invalid
  geometry warnings.
- Real guest testing exposed two additional defects. Tiny screen-sharing
  indicator windows were admitted as unavailable previews; AX windows with known
  geometry now use the existing normal-window size filter. Minimizing a window
  could temporarily remove its AX window ID and discard its cached card. A
  minimized, unnumbered record now retains a known identity only for a unique,
  same-process, bidirectional title/frame match. Ambiguous and cross-process
  matches remain rejected.
- **Automated checks passed on macOS 26.6.2, arm64:** all 833 tests with warnings
  as errors, strict SwiftPM Release and unsigned Xcode Release app/extension
  builds, generated-project consistency, staged resource/ad-hoc signature
  verification and diff whitespace checks. The existing skipped App Intents
  metadata-extraction warning remains non-blocking.
- Installed a same-Developer-ID-signed `1.2.9` / build `19` candidate in macOS
  `15.6.1` (`24G90`), arm64, one virtual display. Archive/executable hashes,
  strict/deep/all-architecture signature checks and the prior installation's
  designated requirement passed. A rollback copy was retained. This arm64 local
  candidate is not Universal 2, notarization or release-distribution evidence.
- **Guest interaction checks passed:** distinct previews for two same-named
  TextEdit documents; a third window added while Command-Tab remains held;
  minimized/restored middle card retains its image and position; closed cards
  disappear; closing the final document hides the panel and creating a new one
  restores it during the same interaction. No sharing-indicator cards remained.
  Five Command-Tab/Esc cycles dismissed the panel without changing the foreground
  app, and ordinary text input reached a disposable document afterward.
- All five permission statuses remained enabled. Actual settings were checked
  in the UI: Dock, Command-Tab and live previews enabled; Option-Tab, Dock
  hide/show and minimize-instead-of-hide disabled. An initial legacy-container
  defaults read was stale and was not used as the runtime settings baseline.
  Feature preferences, privacy grants and the host installation were unchanged.
- **Still open:** exact-window pointer confirmation, Dock hover retention,
  enabled Option-Tab and Dock hide/show, real full-screen/Space transitions,
  permission revocation/recovery, sleep/wake, lock/user switching, independent
  displays and other macOS versions. This partial guest acceptance does not
  close OD-02 or the full P0 matrix. It also does not establish Finder write
  access, updater installation or uninterrupted live capture in every scenario.
- Temporary fixture windows were closed and held modifiers released; existing
  user documents were preserved. The candidate remains running in the guest.
  Logs, package fingerprints and screenshots are recorded in the ignored local
  `20260929-vm-acceptance.iQ4BrX/acceptance.md` under `.private/local-builds`.
  No commit, push, version bump or release publication was performed.

### 2026-09-29 · live preview titles and local installation

- Committed the preceding lifecycle/status work as `500abab`, then rebuilt and
  replaced the host application with the same Developer ID identity. A backup
  of the prior installation and a ZIP of the committed candidate were retained.
  No commits were pushed and the marketing/build version remained `1.2.9` / `19`.
- Follow-up testing reproduced stale titles in an open preview. Status updates
  now propagate the observed title into the existing card, tooltip and action
  data while retaining identity, image, size and selection. Old query results
  cannot overwrite a more recently observed title.
- Some native windows expose no AX window number. Renaming them invalidates a
  title/frame fallback match, so both keyboard switchers now also reconcile the
  affected application's list on title notifications. This reuses the existing
  AX-backed WindowServer reconciliation, event coalescing and stale-query guards;
  it does not add polling or loosen identity matching to geometry alone.
- Added five tests and extended the shared three-entry panel regression. Initial
  failing tests covered stale card text and unnumbered-window rename handling.
  **Passed:** 95 focused tests, all 838 tests with warnings as errors, strict
  SwiftPM Release, Xcode Release app/extension builds with compiler warnings as
  errors, generated-project consistency, staged resource/signature verification
  and diff whitespace checks. Existing App Intents metadata warnings remain.
- Installed the final follow-up build on macOS 26.6.2, arm64. Strict/deep/all-
  architecture signature checks, the previous designated requirement and
  installed/candidate executable hashes passed. Finder Sync has one registered
  copy under `/Applications/OmniDock.app`. All five permission statuses show
  enabled; feature settings and privacy grants were not changed.
- **Host interaction checks:** two disposable native windows were shown in
  Command-Tab, Option-Tab and Dock previews. Accessibility text readback confirmed
  in-place title changes in all three; Command-Tab also passed a second rename
  during the same held interaction. The sibling title stayed unchanged. A
  straight Dock-to-panel pointer path retained the preview; leaving dismissed it.
  The display configuration was mirrored U32J59x/Color LCD at 3008 x 1692 logical
  resolution, not independent-display acceptance.
- **Limits:** a screen-capture command timed out and was terminated, so no new
  screenshot-based visual pass is claimed. An additional programmatic click
  probe did not establish exact-window focus; that gate remains open. These
  observations do not close the full focus, hover, permission, sleep/wake or
  multi-display matrices. The macOS 15 guest was not replaced in this follow-up.
- Closed only the disposable fixture and management windows opened for testing,
  released held modifiers and restored the pointer. The host app remains running.
  Final local ZIP, rollback archive, logs and scope details are in the ignored
  `.private/local-builds/20260929-priority-followup` directory. The title follow-up
  remains uncommitted; no notarization, version bump, push or release was performed.

### 2026-09-29 · title follow-up acceptance on macOS 15

- Reused the preceding Developer ID arm64 `1.2.9` / build `19` candidate.
  Installed it in macOS `15.6.1` (`24G90`) after checking the archive, executable
  hashes, strict nested signatures and the previous designated requirement. A
  rollback copy was retained; the host installation was not replaced again.
- Host follow-up confirmed distinct thumbnail content and exact focus of each
  differently titled native fixture window. Foreground process, main-window
  title and panel dismissal were read back independently after pointer input.
- Guest checks passed for two consecutive title changes during one held
  Command-Tab interaction, a title change in an open Dock preview, minimized
  status and cached-image retention, restoration, exact focus of a differently
  titled window, and exact restoration/focus of its minimized sibling. Screenshots
  confirmed distinct content, unchanged sibling titles and readable status labels.
- Five Command-Tab/Esc cycles dismissed without switching the foreground app;
  ordinary typing worked afterward. Moving from a visible preview to Launchpad
  or an unopened app removed the old panel. Quitting with a preview open and
  relaunching permitted a fresh preview with current windows.
- **F1 did not pass:** two same-named TextEdit documents showed the correct,
  distinct previews, but selecting one did not focus that document. Both AX
  windows omitted `AXWindowNumber`; the current focus resolver rejects the
  ambiguous title and does not reuse the association that distinguished the
  cards. The foreground process and AXDocument URL confirmed the failed focus.
  This is not evidence of a missing permission, and must not be addressed by
  picking the first same-named window or by geometry-only matching. OD-01 and
  the complete release gate remain open.
- All five permission statuses remained enabled, and the six preview settings
  were unchanged: Dock, Command-Tab and live previews on; Option-Tab, Dock
  hide/show and minimize-instead-of-hide off. Finder Sync had one enabled
  registration at the installed path. No privacy grants or feature switches
  were changed. Enabled Option-Tab and Dock hide/show were not tested.
- Repeated the full warnings-as-errors suite: **838 tests passed**. No runtime
  code changed during this acceptance run. Physical interruptions, independent
  displays, side Dock, full-screen/Space and real permission transitions remain
  unverified; partial pointer results do not close the full F/H matrices.
- Closed the owned fixture windows/documents and management windows, released
  modifiers and restored pointers. The candidate remains running in the guest.
  Detailed scope, logs, package fingerprints and screenshots are in the ignored
  `.private/local-builds/20260929-acceptance-continue.r5aCqd/acceptance.md`.
  No commit, push, version bump, notarization or release was performed.

### 2026-09-29 · unnumbered same-title window focus

- Committed the preceding title refresh and acceptance records as `fab835f`.
  The following focus correction is a separate, uncommitted change.
- When AX omits window numbers, a requested WindowServer ID is now resolved
  against current normal surfaces owned by the target process. The requested
  ID, nonempty title and frame must identify exactly one surface and one AX
  window. Known conflicting IDs, missing geometry, coincident matches and
  closed targets remain rejected. A remaining same-named sibling cannot replace
  a closed target. The resolved AX object is retained across focus retries.
- Additional geometry and WindowServer reads occur only on this fallback path;
  exact AX-number and unnumbered metadata-only unique-title matching stay on the
  existing fast path. No capture, close-button or polling behavior changed.
- Added five policy regressions, including initially failing duplicate-title
  and closed-sibling cases. All **843 tests** passed with warnings as errors;
  strict SwiftPM/Xcode Release builds, generated-project consistency, staged
  bundle checks, archive round-trip signatures and diff checks passed.
- Installed the final Developer ID arm64 candidate in macOS 15.6.1 with rollback
  copies. Native pointer clicks selected each of two same-named TextEdit
  documents correctly; foreground process, AXDocument and AXMain confirmed the
  result. Single-window minimized restoration also passed. The first candidate
  additionally passed selecting a window moved while its Dock preview was open.
- **Command-Tab pointer acceptance remains open:** selecting a card dismissed
  the preview without focusing its window, even with a single document. The
  same single-document probe failed in the preceding signed title-refresh build;
  this observation is not introduced by the new resolver. The final candidate
  was restored after that comparison. Further input-routing diagnosis is needed.
- No privacy grants or feature switches changed. After re-registering the
  installed Finder extension following the version comparison, the final check
  showed all five permissions enabled and one registered extension. Option-Tab
  and Dock hide/show remained off and were not exercised.
  The host installation was not replaced. This does not close the full focus,
  input, physical interruption or independent-display release gates.
- Candidate hashes, rollback paths, logs and screenshots are recorded under the
  ignored `.private/local-builds/20260929-exact-focus` directory. No version bump,
  push, notarization or release publication was performed.

### 2026-09-29 · Command-Tab card pointer routing

- A failing panel regression confirmed that card bodies had no intercepted hit
  target. Only the close/quit controls used the pointer event tap; body clicks
  were passed to the native switcher instead of reliably reaching the panel.
- Card bodies now publish an exact-window focus action after their close/quit
  targets. The existing pointer capture validates the presentation generation,
  application and current hit target on release. Dragging keeps the existing
  five-point threshold, scrolls the list, and cannot turn into a focus click.
  Hit targets are clipped to visible card content and refreshed after scrolling.
  No synthetic Escape or modifier release was added to application code.
- Added six regressions for card focus, control priority, dragging, stale or
  removed targets, and visible hit targets after scrolling. All **849 tests**
  passed with warnings as errors. Strict SwiftPM/Xcode Release builds, generated
  project consistency, staged bundle/resource checks, archive round-trip signing
  checks and diff checks passed. The existing App Intents extraction warning is
  unrelated to Swift/compiler warnings.
- Installed the same Developer ID arm64 `1.2.9` / build `19` candidate on the
  macOS 26.6.2 host and macOS 15.6.1 guest. Main/extension executable hashes match
  across both installations; strict nested signatures and the preceding
  designated requirement pass. Rollback packages/copies were retained. Each
  environment has one enabled Finder extension at the installed path.
- **Guest interaction pass:** distinct thumbnails for two same-named TextEdit
  documents; clicking either Command-Tab card selects the corresponding
  AXDocument/AXMain and foreground process. Releasing Command preserves that
  selection. Single-window minimized restoration, Dock card focus, the close
  control, drag-without-focus, and Escape between pointer-down/up also passed.
  The last case swallowed the stale release without activating a window.
- All five guest permission statuses remain enabled. Preview switches remain
  `{1, 1, 0, 1, 0, 0}` in settings order: Option-Tab and Dock hide/show remain
  disabled and were not tested. Only disposable documents and management
  windows were closed, and held modifiers were released.
- **Remaining identity limit:** with two same-named unnumbered AX windows,
  minimizing one can remove the current surface association needed to resolve
  it safely. That restoration probe was rejected without selecting the sibling.
  Single-window restoration is not evidence that this ambiguous case passes;
  OD-01 remains open for a durable, verified AX association.
- **Host interaction blocked:** installation, startup and signature checks
  passed, but the host was at the lock screen when interactive checks began.
  No host pointer/focus acceptance is claimed for this build. Unlocking must be
  performed by the user; no password or privacy setting was changed. Full
  interruption, independent-display, Space/full-screen and remaining OS gates
  are also still open.
- Detailed fingerprints, rollback locations, logs and guest screenshots are in
  the ignored `.private/local-builds/20260929-command-tab/acceptance.md`.
  No commit, push, version bump, notarization or release was performed.
