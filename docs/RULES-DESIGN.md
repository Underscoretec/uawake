# uawake 1.0 — rules engine design

Status: **approved at Gate A (10 Nov 2026), with the maintainer's decisions in §12; built in
Gate B.** Sources: `docs/SPEC.md`
(Release 1.0), `docs/CONTRACTS.md`, `docs/SANDBOX-SPIKE.md`, `docs/ACCEPTANCE-0.1.md` and the 0.1 code.

Anything marked **unverified** has not been observed on a real Mac yet and is checked in the
Gate C live session. The maintainer's answers to the Gate A questions are in
[Decisions](#12-decisions).

## 1. Summary

- A `RuleEngine` in UAwakeCore sits beside the session engine. It receives *signals* from
  system monitors, evaluates rules as pure functions, and calls `SessionEngine.start`/`stop`
  with source `.rule` and reason `.rule(name:)`. It never touches IOKit.
- The 12 condition types map to 10 new monitors in UAwakeSystem, the existing
  `DeviceStateMonitor` (power adapter) and the injected `SessionClock` (schedule).
- No existing contract signature changes. Everything is additive (§10).
- Rules are a versioned JSON file in Application Support, using only property-list-compatible
  types so the same rule dictionary can arrive from an MDM profile or an import file in 1.3.

## 2. Rule model

| Field | Type | Default | Limits (clamped on load) |
| --- | --- | --- | --- |
| `id` | UUID string | generated | Stable for the rule's life; MDM and import refer to it |
| `name` | String | — | 1–64 characters, unique (the editor suffixes " 2" on a clash) |
| `enabled` | Bool | `true` | |
| `match` | `all` \| `any` | `all` | |
| `conditions` | Array | — | 1–16 entries; each is `{ "type": …, parameters }` (§3) |
| `modes` | Array of `system`, `display`, `disk` | `["system"]` | `system` is always added |
| `lingerSeconds` | Int | `120` | 0–3600 |
| `activeHours` | Optional weekly window | none | `{ "days": ["mon",…], "start": "09:00", "end": "19:00" }` |
| `preventSleepOnPower` | Bool | `false` | On AC power, also hold `PreventSystemSleep` (`uawake: Rule: <name> (on power)`). Written only when `true` |

The name is the session reason, so it appears in `pmset -g assertions` as `uawake: Rule: <name>`.

**Deliberately not in the model:** negated conditions ("app is *not* running"), nested
groups, per-rule guard overrides. None are in the spec.

### Weekly window (shared by active hours and the Schedule condition)
- `days` is the set of days the window **starts** on. `end` at or before `start` means it runs
  past midnight into the next day: Fri 22:00–02:00 covers Saturday 00:00–02:00.
- `start == end` means the whole day.
- Evaluated in the current calendar and time zone. Boundaries are computed with
  `Calendar.nextDate`, so DST changes follow wall-clock time. A time-zone or clock change
  (`NSSystemTimeZoneDidChange`, `NSSystemClockDidChange`) and every wake trigger a re-evaluation.

### Persistence
- File: `Application Support/uawake/rules.json` inside the app container. Shape:

```json
{ "version": 1,
  "rules": [ { "id": "…", "name": "On a call", "enabled": true, "match": "any",
               "conditions": [ { "type": "call", "camera": true, "microphone": true } ],
               "modes": ["system", "display"], "lingerSeconds": 120 } ] }
```

- Written atomically on every change. A missing file means no rules, which is the 0.1 upgrade
  path: nothing to migrate, and updating the app never touches the file.
- **Versioning:** `version` is the schema version. A newer app migrates older files in memory
  and rewrites them. A file with a *higher* version than the app understands is left untouched
  and rules stay off, with a banner in the Rules section.
- **Unknown content:** a rule that fails to decode (for example a condition type from a newer
  build) is kept as an opaque entry, written back unchanged, and listed as "Unsupported rule".
  It never runs and is never silently dropped.
- **Corrupt file:** moved aside as `rules.corrupt-<timestamp>.json`, the app starts with no
  rules and shows a banner. No data is deleted.
- **Runtime state is not persisted** (matching, lingering, guard latches). On launch every rule
  is evaluated from scratch.
- **Pause state** is a setting, not part of the file (§5).
- **1.3 hooks, designed now and not built:** the engine takes `[Rule]` and does not care where
  they came from, so managed rules (an array of the same dictionaries under a managed
  preference key) merge in as read-only entries. Import and export use the same
  `{ version, rules }` document. No store protocol is added until a second source exists.

## 3. Conditions

Signals flow one way: monitor (UAwakeSystem) → `ruleEngine.update(_ signal:)` → pure
evaluation in Core. Each monitor conforms to one small generic protocol
(`updates() -> AsyncStream<Value>`, current value first), so a single generic fake covers all
of them in tests. Value types live in Core; Core stays Foundation-only.

Two kinds of debounce:
- **Settle** (Core, tested with `FakeClock`): the raw value must stay true this long before the
  condition counts as met. The end side needs none, because linger covers it.
- **Coalesce** (inside the monitor): bursts of system notifications collapse into one read.

**Detection window** is the longest time from the real-world change to the session starting;
it is what the acceptance run measures.

| # | Condition | Parameters | Detection (spike result) | Model | Settle / coalesce | Detection window | Permission |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | App running | Bundle ID | `NSWorkspace.runningApplications` plus launch/terminate notifications (works) | Event | None | 2 s | None |
| 2 | App frontmost | Bundle ID | `NSWorkspace` activation notifications (works) | Event | None | 2 s | None |
| 3 | Call in progress | Camera, microphone or either (default either) | Core Audio `DeviceIsRunningSomewhere` on every input device; CoreMediaIO `DeviceIsRunningSomewhere` on every camera; property listeners on both and on the device lists (listing works; **live in-use unverified**) | Event | Settle 3 s | 5 s | Camera entitlement and usage string; no prompt seen in the spike |
| 4 | Audio playing | — | Core Audio default output device `DeviceIsRunningSomewhere`, plus a default-device-changed listener (works; **live unverified**) | Event | Settle 5 s, so alert sounds don't start sessions (initial value, tuned in the live check) | 7 s | None |
| 5 | CPU busy | Percent 10–100 (default 50), window 30 s–10 min (default 1 min) | `host_statistics` tick deltas, whole system (works) | Sampled every 10 s | The window is the debounce | Window + 10 s | None |
| 6 | Network busy | Rate (default 1 MB/s), direction download/upload/both (default download), window as CPU | `getifaddrs` byte counters with wrapping subtraction (works) | Sampled every 10 s, same timer as CPU | The window is the debounce | Window + 10 s | None |
| 7 | Power adapter | — | Existing `DeviceStateMonitor`: `powerSource == .ac` (works) | Event | None | 2 s | None |
| 8 | External display | Any, or a display name | `didChangeScreenParameters`, then `NSScreen.screens` with the built-in flag (list works; **events unverified**) | Event | Coalesce 1 s | 3 s | None |
| 9 | USB or Bluetooth device | A picked device: USB vendor and product ID, or Bluetooth address; the name is kept for display | USB: IOKit matching notifications on `IOUSBHostDevice` (registers; **names and events unverified**). Bluetooth: IOBluetooth paired devices with connect/disconnect notifications (**unverified**) | Event | Coalesce 1 s | 3 s | Bluetooth entitlement and prompt, for Bluetooth devices only |
| 10 | Wi-Fi network | Network name | CoreWLAN SSID, re-read on CoreWLAN SSID-change events (blocked without Location; **unverified with it**) | Event | None | 3 s | Location |
| 11 | Calendar event | Optional calendar, optional keyword | EventKit: events for the next 25 h, refetched on `EKEventStoreChanged`, on wake and hourly; Core times the start and end boundaries on the clock (**unverified**) | Event plus timer | None | 2 s after the event starts | Calendar (full access) |
| 12 | Schedule | Weekly window | `SessionClock` timer in Core | Timer | None | 2 s | None |

Notes per condition:
- **Call:** this reports "a camera or microphone is in use", which also covers dictation and
  voice recording. The editor says so. uawake never opens a device or reads any audio or video.
  If the live check shows a camera prompt, the condition narrows to the microphone (the spike's fallback).
- **Audio:** an output device can be running without audible sound. The editor says so.
- **CPU and network:** the condition is met when the **average over the window** is at or
  above the threshold. It needs a full window of samples first. Samples spanning a system sleep
  are discarded. Rates divide by measured elapsed time, so a late timer doesn't skew them.
- **Network:** sums interfaces named `en*` (Ethernet, Wi-Fi, USB and Thunderbolt adapters).
  Loopback and VPN tunnels are left out so VPN traffic isn't counted twice.
- **Power adapter:** always met on desktop Macs.
- **Display:** AirPlay and Sidecar displays count as external.
- **Bluetooth:** IOBluetooth lists classic paired devices. Whether LE-only devices appear is unverified.
- **Calendar:** all-day events, events the user declined and events whose availability is
  "free" are ignored. The keyword matches
  the title, ignoring case and accents. Titles stay in memory, are never written to disk and
  are logged only as private.
- **Wi-Fi fallback:** if CoreWLAN events don't arrive in the sandbox, the SSID is re-read on
  `NWPathMonitor` path changes. Still event-driven, no polling.

A condition evaluates to **met**, **not met** or **unavailable** (permission missing, or no
such hardware). Each also produces a *reading* for the Test view: the current value and the
threshold, as structured data the UI localizes.

## 4. How rules drive sessions

A rule **matches** when it is enabled, rules aren't paused, the time is inside its active
hours, every condition is available, and all (or any) of its conditions are met.

An **episode** runs from the moment a rule starts matching until it has been not matching for
its full linger time. One episode holds at most one session.

| State | Meaning | Leaves when |
| --- | --- | --- |
| Off | Disabled, or all rules paused | Enabled or resumed → evaluated at once |
| Idle | Not matching | Matches → starts a session → Active |
| Active | Holds one session: `.rule`, `.rule(name:)`, the rule's modes, `.indefinite` | Stops matching → Lingering |
| Lingering | Not matching; the session is still held | Matches again → Active. Linger elapses → session ends (`expired`) → Idle |
| Waiting | A guard ended (or refused) the session | No guard has applied for 5 continuous minutes → evaluated (starts if matching). Not matching for the linger time → Idle |
| Stopped by user | The user stopped the session during this episode | Not matching for the linger time → Idle |
| Needs permission | A condition is unavailable | Permission granted → evaluated at once |
| Outside hours | Active-hours window is closed | Window opens → evaluated at once |

Rules in detail:
- **One session per matching rule.** Three matching rules are three sessions with three sets of
  assertions; the engine's combined-modes behaviour is unchanged.
- **Guards always win, then cool down.** The rule engine reads `SessionEngine.events()`. If a
  session it holds ends with `batteryGuard`, `lowPowerMode` or `thermalGuard`, the rule becomes
  Waiting. It restarts by itself (if its conditions still match) once **no guard has applied for
  5 continuous minutes**; a guard returning during the cool-down starts the 5 minutes again. A
  start refused with `wouldEndImmediately` is handled the same way. The rule shows why it waits
  ("Waiting: Mac cooling down", "Waiting: battery low", "Waiting: Low Power Mode is on") and,
  once the guard has cleared, "Waiting: restarts in 4:12". The rule engine checks "does a guard
  apply" with the same `Guard` values and policy as the session engine, on the device state the
  app forwards after `SessionEngine.apply`.
- **Stop button.** Stopping a rule session from the popover (`stoppedByUser`) latches the rule
  for the rest of the episode: it stays off until its conditions clear (for the linger time) and
  return. This is the only latch.
- **Rule sessions are exempt from the maximum cap.** Their own conditions end them. The cap
  still applies to every other indefinite and battery-level session (`DefaultSessionEngine.isCapped`).
- **Linger** applies only when conditions stop being met. Disabling or deleting a rule, pausing
  all rules and an active-hours window closing end the session immediately.
- **Editing** a rule that holds a session replaces the session, **starting the new one before
  ending the old**, so there is never a moment without an assertion; a rename or mode change
  shows up in the assertion name at once (test
  `editingAnActiveRuleStartsTheNewSessionBeforeEndingTheOld`). If the edited rule no longer
  matches, the old session simply ends.
- **Re-arming.** Turning a rule off and on, editing it, or resuming from pause clears a user
  latch or a guard wait. If a guard still applies, the start is refused and the rule waits again.
- **End causes** reuse the existing enum: `expired` when conditions end, `stoppedByUser` when
  the user disables, deletes, edits or pauses.
- **Fast user switching:** the session engine pauses rule sessions like any other. The rule
  engine freezes while the user session is inactive (no starts, no linger expiry) and
  re-evaluates everything when it returns.
- **Sleep and wake:** on wake, sampled windows are discarded and every rule is re-evaluated.
  Linger and window deadlines are wall-clock, like session deadlines.
- **Toggle** and `uawake://deactivate` never touch rule sessions (existing contract).
- **Assertion failure** on start is logged at `.error`, shown on the rule, and retried at the
  next evaluation.
- **Timers:** one task sleeps on the `SessionClock` until the earliest pending moment (settle,
  linger, window boundary, calendar boundary, pause expiry), the same pattern as the session engine.

## 5. Pause all rules

- Choices: **For 1 hour**, **Until tomorrow, 6:00** (06:00 local time on the next calendar day,
  even when paused after midnight), **Until I turn them back on**.
- Pausing ends every rule session immediately and stops the rule monitors. Manual, URL and
  other sessions are untouched.
- Stored in settings so it survives a relaunch: `RulesPaused` (Boolean) and `RulesPausedUntil`
  (Date, absent for "until resumed"). Both are added to `docs/SETTINGS.md` as new keys.
- When the pause ends, every rule is evaluated; rules that match start after their normal
  settle or sample window.

## 6. Permissions

| Permission | Needed by | Entitlement | Usage string |
| --- | --- | --- | --- |
| Camera (device state only) | Call in progress | `device.camera` | `NSCameraUsageDescription` |
| Bluetooth | Bluetooth device | `device.bluetooth` | `NSBluetoothAlwaysUsageDescription` |
| Location | Wi-Fi network | `personal-information.location` | `NSLocationWhenInUseUsageDescription` |
| Calendar | Calendar event | `personal-information.calendars` | `NSCalendarsFullAccessUsageDescription` |

Usage strings are localizable and say what uawake does and does not read.

Flow:
1. Nothing is requested at launch, at first run, or when the Rules section opens.
2. When the user adds a condition that needs a permission (in the editor, or by adding a
   template that has one), the row shows a one-line explanation and a **Continue** button. That
   button triggers the system prompt. It happens here because the device, calendar and
   "current network" pickers need the permission to show anything.
3. **Granted:** the picker fills in.
4. **Denied or restricted:** the row shows a warning with an **Open System Settings** link. The
   rule can still be saved. In the list it shows "Needs Location" (or Calendar, Bluetooth) with
   a warning icon and stays inactive. Other rules are not affected.
5. Rules that arrive without the editor (a restored `rules.json`, ad-hoc rebuilds that lose
   grants, MDM in 1.3) never prompt on their own. They show the warning with a **Grant access** button.
6. Status is re-read when the app becomes active and on authorization-change callbacks. A
   revoked permission makes the condition unavailable; the session ends through the normal linger path.

A permissions type in UAwakeSystem reports status and requests access; tests use a fake.

## 7. UI plan

### Main window: Rules section
A new `MainSection.rules` in the first sidebar group, under Overview. (The spec says "a Rules
tab in Settings"; settings moved to the sidebar window in 0.1.)

- **List.** Each row: icon tile, name, a one-line summary ("Any of: Keynote in front,
  PowerPoint in front · Display awake · Weekdays 9:00–19:00"), a status pill and an on/off switch.
  Status pills pair colour with an icon and text: green "Matching now", amber "Ends in 1:12"
  (lingering), red "Stopped by Battery guard" or "Stopped by you", warning "Needs Location",
  neutral "Outside active hours" and "Off".
- **Header.** "New rule" menu (blank, or a template) and the pause menu. While paused, a banner
  shows "Rules paused until 15:30" with **Resume**.
- **Empty state.** The five templates as cards.
- **Editor** (a sheet working on a draft; Save and Cancel):
  - Name.
  - "Keep awake when **all / any** of these are true".
  - Condition rows. Each has a type menu and type-specific controls: app picker (running apps
    with icons, plus "Other…"), device picker (attached USB and paired Bluetooth devices),
    display picker (any, or a connected display), calendar picker, sliders for CPU percent,
    network rate and window, weekday chips with two time pickers. Text fields only where
    nothing can be enumerated: a Wi-Fi name other than the current one, and the calendar keyword.
  - Keep awake: system (always on), display, disk.
  - Linger: 0 s, 30 s, 1, 2, 5, 10, 15, 30 min.
  - Active hours: switch, weekday chips, start and end.
  - Delete, with confirmation.
  - Validation: a name, at least one condition, every condition complete.
- **Test view** (second segment of the editor, works on unsaved drafts): one row per condition
  with its live value against the threshold ("CPU 34% · needs 50%", "Frontmost: Safari · needs
  Keynote", "Wi-Fi: Office-5G"), a met / not met / unavailable mark, a bar for CPU and network,
  and an overall line: "This rule would be matching now" or why not (paused, outside hours,
  permission). Monitors the draft needs run only while this view is open.

### Starter templates
Offered, never installed automatically.

| Template | Match | Conditions | Modes |
| --- | --- | --- | --- |
| Presenting | Any | Keynote frontmost; PowerPoint frontmost | System, display |
| On a call | Any | Call in progress (camera or microphone) | System, display |
| Building | Any | Xcode running; CPU above 50% for 1 min | System |
| Downloading | All | Network download above 1 MB/s for 1 min | System |
| Plugged in at the office | All | Power adapter; Wi-Fi network (filled with the current network once Location is granted) | System |

### Popover
- **Rule sessions** get their own row style: the rule source tile (`wand.and.stars`, already
  defined in 0.1), the rule name as the title, and "Rule · <conditions met>" or "Rule · ends
  in 1:12" while lingering. The stop button stays; its accessibility label is "Stop rule <name>".
- **Rules strip** above the status strip: "2 of 5 rules matching" and a pause menu. While
  paused it turns amber: "Rules paused until 15:30 · Resume". Hidden when there are no rules.
- The main on/off control still acts only on manual and URL sessions. With only rule sessions
  running, the hero shows awake with the rule's name.
- Rule sessions have no deadline, so the menu bar countdown is unchanged.
- Colours come from `Palette`; new pairs go into `ContrastTests`.

### Accessibility and strings
- Every control gets a VoiceOver label; pills are read as text; sliders speak their value
  ("50 percent", "1 megabyte per second"); the editor is fully keyboard-navigable; no animation
  that Reduce Motion wouldn't allow.
- Every string goes through `Localizable.xcstrings` (`make strings`), including condition
  summaries, readings and usage descriptions.

### Screenshots and UI tests
`-UITestRules <fixture>` loads a fixed rule set with scripted signals, so the list, editor
and Test view screenshots show stable "matching now" states in light and dark.

## 8. Performance plan

Budget: average CPU under 0.5% and memory under 60 MB with 10 rules. 0.1 baseline: 0.011% idle,
13–14 MB physical footprint.

- **Event-driven for ten of twelve conditions.** No polling anywhere except CPU and network.
- **One sampling timer.** CPU and network share a single 10 s timer with 1 s leeway, so the
  system can coalesce it. A tick is one `host_statistics` call and one `getifaddrs` call. The
  timer exists only while an enabled CPU or network rule exists and rules aren't paused.
- **Monitors on demand.** A monitor exists only while an enabled rule or the open Test view
  uses its condition type. With no rules the app behaves as in 0.1.
- **One engine timer** for every settle, linger and boundary, not one per rule.
- **Evaluation only on change.** A signal that equals the previous one does nothing. Evaluation
  is a pure pass over rules and conditions.
- **No UI work when nothing is visible.** Published rule status changes only when a status
  actually changes. Live readings are produced only while the Test view is open. Linger
  countdowns are drawn by SwiftUI's timer text only while on screen. The 0.1 lesson was that
  status-item redraws were the whole cost, so rules never redraw the menu bar except on session start and end.
- **Calendar** work is bounded: a 25-hour window, refetched on change, on wake and hourly.

Measured, not assumed:
- Gate B: 30-minute runs of a 10-rule fixture with `scripts/perf-sample.sh`, against the same
  build with no rules. Reported: average CPU from process CPU time, physical footprint, RSS.
- Gate C: the 8-hour soak with 10 rules. It also logs each rule session's start latency and
  linger error for the accuracy figure.
- Known risk: App Nap may delay the 10 s timer for a background menu bar app. Rates stay
  correct, but detection could be late. If measurements show windows being missed, the fix is
  decided then with numbers.
- Linking EventKit, CoreWLAN, IOBluetooth, CoreMediaIO and CoreLocation may raise the baseline
  footprint. Measured at Gate B.

## 9. Testing plan

- Rule evaluation, the state machine, linger, settle, weekly windows (midnight, DST, time-zone
  change), guard latch, pause, lifecycle freeze and persistence: unit tests in UAwakeCore
  against the real `DefaultSessionEngine` with `FakeClock` and `FakeAssertionProvider`.
- Every monitor is driven through the generic fake with recorded sequences. System conformers
  get smoke tests where a test can run headless.
- Persistence: round trip, unknown rule kept, higher version untouched, corrupt file moved
  aside, values clamped.
- Coverage: rule engine at or above 85%, and `DefaultSessionEngine` stays at or above 85%
  (now 99.2%). All 0.1 tests keep passing unchanged.
- Live hardware and permission checks are batched for the maintainer at Gate C.

## 10. Contract changes

**No existing signature changes.** `SessionSource.rule` and `SessionReason.rule(name:)` already
exist, and `events()` already carries what the latch needs, as `CONTRACTS.md` predicted.

Additions, to be documented in `CONTRACTS.md` at Gate B:

| Addition | Where | Reason |
| --- | --- | --- |
| `Rule`, `Condition`, `WeeklyWindow`, `RuleStatus`, readings | Core | The rule model |
| `RuleEngine` (`@MainActor`, `@Observable`) | Core | Evaluates rules; starts and stops sessions through `SessionEngine` |
| Rules file store | Core | Versioned JSON persistence |
| Signal value types and the generic monitor protocol | Core (values), System (protocol and conformers) | Keeps Core Foundation-only, as with `DeviceState` |
| Permissions type | System | Status and request for Bluetooth, Location, Calendar |
| Settings keys `RulesPaused`, `RulesPausedUntil` | Core, `docs/SETTINGS.md` | Pause survives relaunch; keys are added, none renamed |
| Entitlements and usage strings (§6) | App | Already listed in the spec's architecture section |

Not added: an `EndCause` for "rule conditions ended". `expired` already means "the session's
own end condition was reached".

## 11. Spec ambiguities resolved

1. **"Rules tab in Settings"** → a Rules section in the main-window sidebar.
2. **A guard ends a rule session** → includes the maximum cap, and a start the engine refuses
   because a guard already applies.
3. **"Conditions clear"** → not matching for the full linger time, the same moment the session
   would have ended on its own. A shorter dip doesn't re-arm a held rule.
4. **Stop button on a rule session** → holds the rule for the rest of the episode.
5. **Linger scope** → only when conditions stop being met. Active hours closing, pause, disable
   and delete are immediate. A *Schedule condition* ending does get linger, because it is a condition.
6. **Missing permission** → the whole rule is inactive, even in "any" mode with other usable
   conditions, as the spec says "the rule … stays inactive".
7. **"Above X for 1 min"** (CPU, network) → the average over the window.
8. **Calendar "in progress"** → excludes all-day, declined and "free" events.
9. **Weekly windows past midnight** → belong to the day they start on.
10. **Templates** → offered, not pre-installed. "Building" follows the spec literally: Xcode
    merely being open keeps the Mac awake.
11. **Rule edits while active** → replace the session, new one first.
12. **Network rate** → `en*` interfaces only; 1 MB/s is 1,000,000 bytes per second.
13. **Latches and linger are not persisted** across a relaunch.
14. **Per-app CPU** → not built. The spec's wording limits it rather than requires it.

## 12. Decisions

Answered by the maintainer at Gate A (10 Nov 2026):

1. **Guard latch** → no latch for guards. A guard ends a rule's session while it applies; the
   rule re-arms automatically once no guard has applied for 5 continuous minutes, and shows the
   waiting state. Only the user stopping a rule session latches it for the rest of the episode.
2. **Maximum cap** → rule sessions are exempt. The cap applies only to manual, URL and other
   non-rule indefinite and battery-level sessions.
3. **"Until tomorrow"** → 06:00 local next morning, labelled "Until tomorrow, 6:00".
4. **App picker "Other…"** → add `com.apple.security.files.user-selected.read-only` now.
5. **Rule URLs** → stay in 1.1.
6. **Per-app CPU** → whole-system CPU only in 1.0.
7. **SPEC wording** → 0.1 is "the first internal alpha"; the decisions above are in `docs/SPEC.md`.

Also approved: all 14 resolutions in §11, plus editing an active rule starts the new session
before ending the old (with a test), and calendar conditions ignore "free" events.
