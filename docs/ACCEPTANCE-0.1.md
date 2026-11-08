# uawake 0.1 acceptance

Results for every acceptance criterion in `docs/SPEC.md` › Release 0.1.

**Tested:** 8 Nov 2026 on macOS 27.0.1 (26A434), Xcode 27.2 (27B52), MacBook Air (Apple M5).
**Build:** 0.1.0 (1), Release configuration, ad-hoc signed without the hardened runtime (see
`docs/RELEASING.md`), except where a Debug build is named.
**Re-run:** `scripts/acceptance.sh <app>`, `scripts/perf-sample.sh <pid> <seconds> <label>`,
`make test`, `make uitest`; the countdown run is described below.

## Summary

| # | Criterion | Result |
| --- | --- | --- |
| 1 | Starting any session creates assertions visible in `pmset -g assertions` with the session's reason | **Pass** |
| 2 | Stopping a session removes its assertions within 1 second | **Pass** (0.08–0.09 s) |
| 3 | Killing the app with `kill -9` leaves no uawake assertions behind | **Pass** |
| 4 | Two overlapping sessions keep the Mac awake until the later one ends | **Pass** |
| 5 | Each guard ends sessions at its threshold and sends a notification naming it | **Pass in tests; live check pending (you)** |
| 6 | A session survives fast user switching with the correct remaining time | **Pending (you)**: needs a second account |
| 7 | Every URL in the table works; an invalid URL changes nothing | **Pass** |
| 8 | Menu bar countdown stays accurate to within 1 second over a 2-hour session | **Pass**: 2 h run, 0 of 119 samples off; minute format re-checked, 0 of 30 off |
| 9 | All user-facing strings come from the String Catalog | **Pass** |
| 10 | Session engine unit test coverage of at least 85% | **Pass** (99.2% lines) |

## Evidence

### 1. Assertions carry the reason
`scripts/acceptance.sh` started each kind of URL session and read `pmset -g assertions`:

```
$ open 'uawake://activate'
pid 96078(uawake): PreventUserIdleSystemSleep named: "uawake: URL: indefinite"
$ open 'uawake://activate?duration=90m'
pid 96078(uawake): PreventUserIdleSystemSleep named: "uawake: URL: 1 hour 30 minutes"
$ open 'uawake://activate?until=23:59'
pid 96078(uawake): PreventUserIdleSystemSleep named: "uawake: URL: until 23:59"
$ open 'uawake://activate?display=1&reason=Render'
pid 96078(uawake): PreventUserIdleSystemSleep named: "uawake: Render"
pid 96078(uawake): PreventUserIdleDisplaySleep named: "uawake: Render"
```

Manual sessions: Gate 2 and slice 1 checks showed `"uawake: Manual: indefinite"` from the popover
toggle. Unit test `SessionEngineTests.startAcquiresNamedAssertionsAndStopReleasesThem` covers the
names for every mode.

### 2. Stop within 1 second
Time from `open uawake://deactivate` to the assertion disappearing, polling `pmset` every 50 ms.
This includes LaunchServices delivering the URL:

```
run 1: gone after 0.084 s
run 2: gone after 0.093 s
run 3: gone after 0.091 s
```

### 3. `kill -9`
```
before:  pid 96670(uawake): PreventUserIdleSystemSleep named: "uawake: Kill test"
after kill -9 96670: (no uawake assertions)
```

### 4. Overlapping sessions
`activate?duration=30s&reason=Short` and `activate?duration=60s&reason=Long` together:

```
t=1s:  "uawake: Long", "uawake: Short"
t=35s: "uawake: Long"
t=65s: (none)
```
Also `SessionEngineTests.overlappingSessionsEndIndependently`.

### 5. Guards
Covered by unit tests on the real engine with fake device state:
`batteryGuardEndsSessionsOnlyOnBatteryAtThreshold`, `batteryGuardReportsItsCause`,
`lowPowerModeGuard`, `thermalGuardEndsAtSeriousOrCritical` (serious and critical),
`indefiniteSessionEndsAtMaximumCap`, `policyChangeRecomputesCapAndEndsPastSessions`,
`startIsRefusedWhileAGuardApplies`, and on the app side `refusalAndGuardBanners`.
The notification names the guard via `EndCause.guardText` (Battery guard, Low Power Mode,
Thermal guard, Maximum duration). A live notification needs notification permission and a real
Low Power Mode or battery change. See *Steps for you* below. Thermal pressure can't be raised
safely on demand, so it stays test-only.

### 6. Fast user switching
Engine behaviour is covered by `fastUserSwitchingPausesAndResumesWithRemainingTime`,
`pauseAndResumeAreReportedAsEvents` and the app's `keptAwakeTodayExcludesPausedTime`. The sandbox
spike confirmed sleep/wake notifications arrive; the user-switch notifications need a second
account. See *Steps for you*.

### 7. URL table
```
toggle (off→on): "uawake: URL: indefinite"
toggle (on→off): (none)
activate?duration=1h, then 5 invalid URLs (duration=0, duration=30m1h, uawake://sleep,
until=25:00, deactivate?x=1): the 1 h session is unchanged.
```
Plus 38 parser cases in `URLCommandTests` and the routes in `URLRouterTests` (including
"invalid URLs change nothing" and "refused start changes nothing").

### 8. Countdown accuracy over 2 hours
A real 2-hour session (`-Headless -OpenURL "uawake://activate?duration=2h…" -SampleCountdown 60`,
countdown on) ran from 13:01:06 to 15:01:06. Once a minute the app logged what the menu bar had
last drawn (`shown`), the true time left at that wall-clock moment (`expected`), and how long ago
the menu bar was drawn (`renderedAgo`):

```
2026-11-08 13:02:06.592 COUNTDOWN wall=… shown=1:59:00 expected=1:59:00 renderedAgo=…
…
2026-11-08 15:00:24.127 COUNTDOWN wall=… shown=0:43 expected=0:43 renderedAgo=…
```

- **119 samples, 0 mismatches**; largest difference 0 s.
- `renderedAgo`: median 0.11 s, maximum 0.71 s. The text on screen was never more than 1 s old.
- `pmset -g log`: `Released PreventUserIdleSystemSleep "uawake: Countdown accuracy" 02:00:00`.
  The session ended exactly on time.
- This instance ran under its own bundle ID with no URL scheme, so test URLs couldn't reach it.
  An earlier attempt was invalid: the copy had been registered with the scheme and a test
  `uawake://deactivate` stopped its session after 3 min 54 s. Its 3 samples were exact, but it was
  discarded and re-run.
- The sample is the text uawake drew into its status item, not a screen capture; this terminal has
  no Screen Recording permission.
- Build: the bitmap-pill build. The later symbol cache changes only how the icon is rasterized,
  not the timing or text.

**Minute format (shipped after Gate 6).** The 2-hour run above used the earlier seconds format.
The minute format was re-checked with a 32-minute session (15:16:54–15:48:54, countdown on,
sampled every minute):

```
15:17:54 shown=31m  expected=31m
15:18:54 shown=30m  expected=30m
…
15:46:54 shown=2m   expected=2m
15:47:54 shown=1:00 expected=1:00
```
30 samples while the session ran, 0 mismatches. `pmset -g log`: `Released … "uawake: Countdown
minutes" 00:32:00`. Unit tests `menuBarTextIsMinutesUntilTheFinalMinute` and
`menuBarRedrawsOnlyWhenTheTextChanges` check the format and that every redraw lands exactly where
the text changes.

### 9. String Catalog
- `make strings` reports `174 strings extracted, 174 in catalog, 0 stale`. Every string the
  compiler extracted from `Text`, `Label`, `Button` and `String(localized:)` is in
  `App/Resources/Localizable.xcstrings`.
- A search for literal strings outside the catalog (`verbatim:`, window titles, button titles)
  finds only the UI-test stand-in window, the menu bar preview window and the `-CrowdMenuBar`
  debug placeholders, none of which users see.
- Session reasons in assertion names are English by design (decided at Gate 1).

### 10. Coverage
`swift test --enable-code-coverage` in `Packages/UAwakeCore`: `DefaultSessionEngine.swift` 99.16%
lines (97.22% regions); Core total 97.18% lines.

## Performance

Spec budget: idle CPU under 0.1%; memory under 60 MB. Each instance ran headless (no windows) with
its own settings. CPU is the average over the run, from the process's CPU time; memory is
`footprint` (physical footprint) and RSS.

| Run | Duration | Average CPU | Physical footprint | RSS | Budget |
| --- | --- | --- | --- | --- | --- |
| Idle, no session | 30 min | 0.011% | 13 MB | 21–55 MB | **Pass** |
| One 2 h session, countdown off (default) | 30 min | 0.012% | 13 MB | 22–56 MB | **Pass** |
| One 2 h session, countdown on: first build | 30 min | 0.89% | 14 MB | 29–55 MB | Over 0.1% |
| … pill drawn once into a bitmap | 30 min | 1.05% | 14 MB | 47–58 MB | Over 0.1% |
| … plus the symbol rasterized once and cached | 10 min | 0.94% | 14 MB | 31–41 MB | Over 0.1% |
| One 32 min session, countdown on, **minute format (shipped)** | 30 min | **0.018%** | 14 MB | 30–33 MB | **Pass** |

Memory passes in every run (14 MB physical footprint against a 60 MB budget).

**Decision (Gate 6):** the menu bar redraws once a minute: `1:42` from an hour, `42m` under an
hour, `m:ss` only in the final 60 seconds. The popover still shows seconds while it's open.
A `sample` profile of the seconds format showed most of its ~0.9% was AppKit updating and
redrawing the status item every second. Redrawing only when the text changes brings the countdown
down to 0.018%, the same as having no countdown. The redraw is a one-shot timer set for the exact
moment the text next changes (`secondsUntilMenuBarChange`, unit-tested over a whole 2-hour range).

*Correction:* an earlier interim figure of 0.117% for the bitmap build was wrong. The session in
that run had been stopped by a stray `uawake://deactivate` 4 minutes in (see criterion 8), so most
of that half-hour had no countdown.

## Steps for you

**Fast user switching (criterion 6)**
1. System Settings › Users & Groups › Add User: a temporary Standard account.
2. Control Centre settings: show Fast User Switching in the menu bar.
3. In your account, open uawake, click **15 min**, and note the time left (e.g. 14:41).
4. Within a few seconds, switch to the temporary account from the menu bar. Stay there **2 minutes**.
5. In the temporary account, open Terminal: `pmset -g assertions | grep uawake` should print nothing
   (the session is paused, so its assertion is released).
6. Switch back. Within 5 seconds, open the popover: the time left should be within 1–2 s of what you
   noted in step 3 (not 2 minutes less). `pmset -g assertions | grep uawake` shows it again.
7. Evidence: `/usr/bin/log show --predicate 'subsystem == "com.underscoretec.uawake"' --last 10m --info | grep -E 'Paused|Resumed'`.
8. Delete the temporary account.

**Guard notifications (criterion 5)**
1. Allow notifications for uawake (first-run window or System Settings › Notifications).
2. Start a session, then turn on Low Power Mode (System Settings › Battery). Expect: the session ends,
   a "Low Power Mode" notification, and a red "Stopped by Low Power Mode" banner in the popover.
3. Battery guard: `defaults write com.underscoretec.uawake BatteryGuardThreshold -int 95`, quit and
   reopen uawake, start a session, unplug the power adapter (battery must be at 95% or less).
   Expect a "Battery guard" notification. Afterwards: `defaults delete com.underscoretec.uawake BatteryGuardThreshold`.
