# Lock & dim design (1.0.0-alpha.8)

Status: **draft for approval, no feature code yet.** Evidence: `docs/SANDBOX-SPIKE.md` (rows marked alpha.8).

## What it is
Stay awake without leaving the Mac open to anyone walking past. Three independent, opt-in pieces:

1. **Lock now, keep running**: lock the screen; the session keeps going.
2. **Auto-lock while awake**: lock after X idle minutes during a session.
3. **Dim when idle**: darken the screen after X idle minutes; any input removes it at once.

All off by default except the button. They sit on the existing session engine; none starts or ends a session.

## What the spike showed (summary)
- Locking works from the sandbox with public API: launching `ScreenSaverEngine.app` through `NSWorkspace` locked the session within 1 s. `pmset displaysleepnow` also works from the sandbox.
- Whether it locks **depends on the user's "Require password after screen saver begins or display is turned off"**. Tested only with "immediately". The setting is readable only via `sysadminctl -screenLock status`, not via preferences.
- Lock/unlock detection works (distributed notifications). `screenIsUnlocked` arrives before the session-dictionary flag flips: use the notification.
- Idle time works with no permission.
- The dim overlay works as a window; capture exclusion, other Spaces and removal latency still need hand checks.
- Releasing only the display assertion leaves the others listed; that the display then sleeps is not yet observed.

## Behaviour

### 1. Lock now
- Popover button **Lock now** (icon + text), optional global shortcut (`LockShortcutKeyCode/Modifiers`, same rules as the other shortcuts), and `uawake://lock` (CLI and Shortcuts follow in 1.1).
- Works with or without a session. With none, it just locks.
- Method: start the screen saver through `NSWorkspace` (public API, no exec). `displaysleepnow` is the fallback if the launch fails. No private APIs.
- After the call, wait up to 3 s for `screenIsLocked`. No notification: post "uawake couldn't confirm the screen locked" and log `.warning`. We never claim success we did not see.

### 2. Auto-lock while awake
- Setting: lock after **X idle minutes** (1–120, default 10) while any session is active (manual, URL or rule). Off by default.
- Idle = `CGEventSource` seconds since last input, sampled once a second by an idle monitor in `UAwakeSystem` (an `AsyncStream`, like the other monitors).
- No session: auto-lock does nothing; the Mac's own lock settings apply.
- If a session starts when idle time is already past X, it locks at once. Locking is the safe direction, so no special case.
- Locks once per idle period; input resets it.

### 3. While locked
- On `screenIsLocked` the engine **releases the display assertion** and keeps `PreventUserIdleSystemSleep` and, on power, `PreventSystemSleep`. On `screenIsUnlocked` it takes the display assertion back (if the session would hold one).
- The session, its reason and its deadline do not change. Assertion names stay `uawake: <reason>`.
- Implemented as a new lifecycle event `.screenLocked(Bool)` through `SessionLifecycleMonitor` → `SessionEngine.handle(_:)`. The engine alone touches assertions (convention unchanged); Core gains the event type but stays Foundation-only. `RuleEngine` receives it like other lifecycle events.
- Applies to every lock, not only ours: a user pressing ⌃⌘Q mid-session also drops the display assertion. A locked screen has no reason to stay lit.
- Open: confirm by the hands-off `lockAssertions` run that the display then sleeps (spike, pending).

### 4. Dim when idle
- Settings: enabled (off), idle minutes (1–120, default 5), **darkness 20–90 %** (default 60), **keep watermark visible above the dim** (default on).
- One borderless black window per display, level `.screenSaver`, click-through, all Spaces, `sharingType = .none`. Reuse the watermark's window code and `HostingWindowController` patterns; the watermark window sits one level above the dim.
- Fades in over 1.5 s (instant when Reduce Motion is on). Removal is **instant, no fade**: poll idle time at 50 Hz only while the dim is up, remove on the first drop. No Accessibility or Input Monitoring.
- Only while a session is active, and removed when the session ends, a guard ends it, or the Mac locks.
- Hidden from screen sharing, screenshots and recordings, on purpose: sharing a dimmed screen would hide the presentation. This differs from the watermark, whose `WatermarkHiddenFromCapture` is a setting.
- Not dimmed when **another app holds a display-sleep assertion** (video, presentation); `IOPMCopyAssertionsByProcess` works from the sandbox (1.2 spike). Setting `DimSkipsWhenPlaying`, default on. Our own assertion is ignored.

### 5. Combined sequence
Both count idle time from the **last input**, not from each other. Dim at X, lock at Y, with **Y > X** enforced (the UI keeps Y at least X + 1; out-of-range managed values are clamped).

```
input ──── idle X min ──► dim fades in ──── idle Y min ──► lock (dim removed, display assertion released)
   ▲                          │                                  │
   └── any input: dim gone ───┘                                  └── unlock: assertion restored, idle clock restarts
```

Popover, under the reason line, only while a session is active and something is armed:
- Idle, armed: `Dims in 3 min · Locks in 8 min` (grey text with a small moon/lock icon).
- Dimmed: amber `Dimmed · locks in 4 min` (amber is for near-a-limit; here it means locking is imminent). It cannot be opened while dimmed without moving the mouse, which removes the dim, so this state shows chiefly in the menu bar tooltip and the next popover open.
- Locked: not visible (the screen is locked). On unlock the popover reason line is unchanged.
Countdowns are minute-resolution, derived from idle time, and are computed, not stored.

## If locking is not reliable
The lock works only when the user's setting requires a password. We can read it, so be honest in the UI rather than promise:

| Setting read | "Lock now" button | Auto-lock toggle |
| --- | --- | --- |
| Immediately | `Lock now` | Enabled |
| Delay (e.g. 5 min) | `Start screen saver`, caption "Your Mac asks for a password after 5 minutes." | Enabled, same caption: "Locks after your Mac's password delay (5 min)." |
| Never / off | `Start screen saver` disabled, caption "Your Mac isn't set to ask for a password." + button "Open Lock Screen settings" | Disabled with the same caption |
| Unreadable | `Start screen saver`, caption "uawake can't tell if a password is required." | Enabled with the caption |

- "Open Lock Screen settings" uses `x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension`; verify it opens on macOS 14 and 27 before shipping.
- Settings are re-read each time the popover opens and when the app becomes active.
- A lock that the notification does not confirm is reported (see 1.).
- **2.0 Pro helper**: it could lock the session regardless of the user setting, but that is a privileged action and a forced password; not built here. If testers ask for lock without changing system settings, that is where it goes.
- Wording never says "locked" unless `screenIsLocked` was seen.

## Settings keys (public API for MDM, `docs/SETTINGS.md`; new keys only)
| Key | Type | Default | Range |
| --- | --- | --- | --- |
| `LockShortcutKeyCode` / `LockShortcutModifiers` | Integer | none | As `GlobalShortcut*` |
| `AutoLockEnabled` | Boolean | `false` | |
| `AutoLockMinutes` | Integer | `10` | 1–120 |
| `DimEnabled` | Boolean | `false` | |
| `DimMinutes` | Integer | `5` | 1–120 (kept below `AutoLockMinutes` when auto-lock is on) |
| `DimDarkness` | Integer | `60` | 20–90 (%) |
| `DimKeepsWatermark` | Boolean | `true` | |
| `DimSkipsWhenPlaying` | Boolean | `true` | |

## MDM, for 1.3
- Same keys, same names; `objectIsForced` locks the UI control (no new mechanism).
- **Force auto-lock on**: force `AutoLockEnabled = true`. Admins also pin `AutoLockMinutes`; add `AutoLockMaxMinutes` (Integer, 1–120, absent = no ceiling) so users may choose a shorter time but not a longer one.
- Role presets (1.3): "Shared kiosk" forces auto-lock at 5 and dim at 2; "Personal" leaves both off.
- Kiosk mode: Lock now stays available; the dim stays off (a kiosk screen should stay readable).
- Admin note to document: the screen-lock *requirement* itself (password after screen saver) is a separate system profile payload (`com.apple.screensaver` / Login Window); uawake only reads it. Recommend deploying both.

## Where code goes
| Piece | Module |
| --- | --- |
| `.screenLocked(Bool)` lifecycle event; display-assertion drop/restore; idle-minute arithmetic and `LockDimPolicy` (pure, testable with `FakeClock`) | `UAwakeCore` |
| `ScreenLocker` (saver launch, displaysleepnow fallback, setting reader), `IdleMonitor`, `ScreenLockMonitor` (distributed notifications) | `UAwakeSystem` |
| Dim windows, Lock button, settings section, popover line | `App` |
| `uawake://lock` | `UAwakeIPC` |
Tests: engine drops/restores only the display assertion on lock/unlock (`FakeAssertionProvider`); policy sequence (dim X, lock Y, input resets) with `FakeClock` and a fake idle monitor; setting-string parser. Real locking only in an integration run with `pmset -g assertions`.

## Decisions to confirm
1. Screen saver as the primary lock method (API, no exec), `displaysleepnow` as fallback. Alternative: `displaysleepnow` first, so the screen goes dark immediately rather than showing the saver.
2. Dim is always hidden from capture (no setting).
3. Skip dimming while another app holds a display assertion (default on).
4. Dropping the display assertion on **any** lock, not just ours.
5. Ship with the honest wording table above, rather than defer lock to the 2.0 helper.

## Before building: remaining spike checks
Capture exclusion in a QuickTime recording, second display, other Spaces and over a full-screen app, `dimRemoval` latency, display idle-sleep after display-assertion release, and lock with delay 5 min / Never. Then `make probe` rerun, and the alpha.8 build ships through `make release` and the Sparkle feed (`beta` channel).
