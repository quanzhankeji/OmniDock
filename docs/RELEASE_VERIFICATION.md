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
| S3 | Plug in and unplug an external display | Previews and the switcher appear on a screen that exists; no stale geometry |
| S4 | Change resolution or scaling | Panels resize rather than clipping or spilling |
| S5 | Enter and leave a full-screen Space | Full-screen windows are listed as such, not as missing |
| S6 | Toggle *Displays have separate Spaces* | Space membership stays readable; unknown is shown as unknown, never as another Space |

The window inventory and Dock interaction do not currently observe sleep,
wake, or display-parameter changes. Display changes are observed by the
window-placement size indicator only; see [Known gaps](#known-gaps).
S1–S4 therefore need particular attention.

### Window lifecycle

| # | Do this | Expect |
|---|---|---|
| W1 | Open and close windows while a preview is showing | The panel follows; closed windows leave it |
| W2 | Quit an application that had windows listed | Its entries go, and nothing else does |
| W3 | Relaunch that application | Its windows come back once, not twice |
| W4 | Minimise, hide, and restore | State is shown accurately and the window is still reachable |

A ghost window — one listed after it is gone — and a lost window — one missing
while it is on screen — are both failures here. Note which.

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

## Known gaps

Found by reading the source for this list, not by reproducing a failure. They
are written down so a run can look for them, not as promises to change
anything.

- **No sleep or wake handling.** Nothing observes
  `NSWorkspace.willSleepNotification` or `didWakeNotification`. Whether the
  window inventory and the event taps survive a sleep is untested.
- **Display changes are barely observed.**
  `NSApplication.didChangeScreenParametersNotification` is observed in one
  place, the window-placement size indicator. The window inventory and the Dock
  interaction do not watch it.
- **Space membership is inferred, not established.** The app observes
  `activeSpaceDidChangeNotification`, which says when to refresh, not which
  Space a window belongs to.

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
