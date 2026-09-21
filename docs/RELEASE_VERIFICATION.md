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

Nothing in the app currently observes sleep, wake, or display-parameter
changes — see [Known gaps](#known-gaps) — so S1–S4 are the scenarios most
likely to find something.

### Window lifecycle

| # | Do this | Expect |
|---|---|---|
| W1 | Open and close windows while a preview is showing | The panel follows; closed windows leave it |
| W2 | Quit an application that had windows listed | Its entries go, and nothing else does |
| W3 | Relaunch that application | Its windows come back once, not twice |
| W4 | Minimise, hide, and restore | State is shown accurately and the window is still reachable |

A ghost window — one listed after it is gone — and a lost window — one missing
while it is on screen — are both failures here. Note which.

### Teardown

| # | Do this | Expect |
|---|---|---|
| T1 | Open and dismiss the switcher quickly, many times | No capture session survives the last dismissal |
| T2 | Turn each feature off in Settings | Its event tap and its captures stop |
| T3 | Revoke a permission while the app runs | The feature stops; the switch keeps the value the user set (OD-21) |
| T4 | Grant it again | The feature works without a relaunch |
| T5 | Quit the app with a preview open | Nothing is left behind: no tap, no capture, no panel |

T1 and T2 are looking for a leak the tests cannot see. The teardown paths were
read for this list and are sound on paper; that is not the same as watching
them run.

### Menu bar shelf

| # | Do this | Expect |
|---|---|---|
| M1 | Turn the shelf off and on several times | Both items come back every time |
| M2 | Drag the divider past the arrow, then collapse | The controls return rather than disappearing with the icons |
| M3 | Hold Command and drag icons for longer than the auto-hide delay | The shelf stays open until the dragging stops |

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
