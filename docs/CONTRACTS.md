# uawake core contracts

These types are the stable seams of the app. Later releases add conformers and
callers; they should not need to change these signatures.

## Session and its value types (`UAwakeCore/Session.swift`)
A `Session` is an immutable record of who asked (`SessionSource`), why (`reason`),
what to keep awake (`AwakeMode` set, always including `.system`), and when it ends
on its own (`EndCondition`). `state` is `active`, `paused(remaining:)` or
`ended(EndCause)`; the end cause is carried by the terminal state, so a session
can never be "ended" without a cause. `deadline` is the resolved wall-clock end.
`SessionRequest` is what callers send; the engine assigns id, start and deadline.

- **Reason** is structured: `SessionReason` is a kind plus arguments
  (`.standard(source, endCondition)`, `.custom(text)`, `.rule(name:)`). The UI renders
  it localized; `englishDescription` is the untranslated text used for assertion names.
- **Battery level X**: ends (`expired`) when on battery power and the level is at or
  below X. On AC power it keeps running. There is no "charge up to X".
- **Maximum cap** applies only to indefinite and battery-level sessions, as the
  deadline `startedAt + cap`. It ends them with `maximumCap`, never `expired`.
- **Until a clock time** that has passed today means the same time tomorrow.

**Threading:** all value types, `Sendable`.

## SessionEngine (`UAwakeCore/SessionEngine.swift`)
Owns every session and is the only holder of assertions. `start` acquires before
returning (and throws without creating a session on failure); `stop`/`stopAll`
release immediately; `extend`, `pause`, `resume` adjust deadlines and assertions.
`sessions` is observable for SwiftUI. `events()` streams `SessionEvent`s:
`started`, `paused`, `resumed`, `aboutToEnd` (a duration or until-time session reaching `endWarning` before
its deadline; sessions shorter than the lead time are not warned) and `ended` (carrying
its cause). Notifications, the UI and, later, history consume it.

- **Toggle** (menu bar primary click and `uawake://toggle`): only manual and URL
  sessions count as "on". If any exist they are stopped; otherwise the default
  session starts. Rule and CLI sessions are never stopped or counted.
- **Extend** works only on duration and until-time sessions; others throw
  `notExtendable` and the UI hides the control.
- **Policy**: setting `policy` recomputes the cap deadline of active capped sessions and
  re-runs the guards on the last device state.
- **Device state**: `apply(_:)` ends reached battery-level sessions (`expired`), then guard
  verdicts. A guard ends every live session, paused ones included.
- **Refused starts**: `start` throws `wouldEndImmediately(cause)` when a guard, or the
  session's own battery level, already applies to the last device state. No session is created.
- **Lifecycle**: `handle(_:)` pauses active sessions when the user session resigns,
  resumes them when it returns, and on wake ends sessions whose deadline passed.
  Deadlines are wall-clock, so time asleep counts.

**Threading:** `@MainActor`. Conformers are `@Observable` classes. Timers run as
main-actor tasks sleeping on the injected `SessionClock`.

## AssertionProvider (`UAwakeCore/AssertionProvider.swift`)
`acquire(modes:reason:)` creates one IOKit assertion per mode named
`uawake: <reason>` (always English) and returns an `AssertionHandle`; `release`
frees them. Modes map to `PreventUserIdleSystemSleep`, `PreventUserIdleDisplaySleep`,
`PreventDiskIdle`. The fake records live handles so tests assert "nothing leaked".
The IOKit conformer lives in UAwakeSystem so Core stays Foundation-only.

**Threading:** `Sendable`, synchronous; IOKit calls are thread-safe and cheap.

## SessionClock (`UAwakeCore/SessionClock.swift`)
`now` and `sleep(until:)`. The system conformer uses `Date()` and a
`ContinuousClock` sleep (which counts time asleep). It sleeps relaxed until 60 s before
the deadline, then precisely under a latency-critical activity, because App Nap would
otherwise delay a background menu bar app's deadlines by up to ~10 s. The fake advances
time manually and resumes sleepers whose deadline has passed, making timed tests instant.

**Threading:** `Sendable`.

## Guard and GuardPolicy (`UAwakeCore/Guard.swift`)
A `Guard` is a pure function: given a `DeviceState`, the live sessions and a
`GuardPolicy`, it returns `GuardVerdict`s (session id + `EndCause`). The engine
re-evaluates on every device-state change. The maximum cap is time-based, so the
engine applies it as a deadline rather than a guard. `GuardPolicy` holds thresholds
with spec defaults (20% battery, LPM on, thermal on, 24 h cap). The 0.1 guards are
`BatteryGuard`, `LowPowerModeGuard` and `ThermalGuard` (`DefaultSessionEngine.standardGuards`),
each ending sessions with its own `EndCause`.

**Threading:** `Sendable` values and protocol.

## DeviceStateMonitor (`UAwakeSystem/DeviceStateMonitor.swift`)
Exposes `current` and `updates()`, an `AsyncStream<DeviceState>` that yields the
current value then each change. `DeviceState` itself lives in Core so guards stay
free of system frameworks. The app forwards each value to `SessionEngine.apply(_:)`.

**Threading:** `Sendable`; streams are consumed by a main-actor task.

## SessionLifecycleMonitor (`UAwakeSystem/SessionLifecycleMonitor.swift`)
`events()` streams `SessionLifecycleEvent`s: user session resigned/became active
(fast user switching), system will sleep, system did wake. The event type lives in
Core; the app forwards each to `SessionEngine.handle(_:)`. Required in 0.1.

**Threading:** `Sendable`; streams are consumed by a main-actor task.

## URLCommand (`UAwakeIPC/URLCommand.swift`)
`URLCommand(url:)` parses the 0.1 URL table into `.activate(ActivateOptions)`,
`.deactivate` or `.toggle`, throwing `URLCommandError` otherwise. Parsing is pure,
so an invalid URL is rejected before the engine is touched. Strict:
- `duration` is h/m/s parts in descending order, each unit at most once
  (`1h30m`, `2h15m`, `90m`, `45s`); 0, negatives and anything else are rejected.
- `duration` with `until`, repeated keys and unknown keys are errors.
- `until` is 24-hour `HH:mm`; `display` is `1`/`true` or `0`/`false`.
- `reason` is 1–128 characters and becomes `SessionReason.custom`.

`URLRouter.route(_:to:defaultCondition:)` carries a URL out on the engine:
`activate` starts a `.url` session, `deactivate` stops manual and URL sessions, and
`toggle` calls `engine.toggle` with the primary-click preset. Invalid URLs and refused
starts change nothing and log a warning.

**Threading:** `URLCommand` values are `Sendable` and parse anywhere; `URLRouter` is `@MainActor`.

## Settings (`UAwakeCore/Settings.swift`)
`UAwakeSettings` reads and writes every 0.1 setting in `UserDefaults` under the keys in
`docs/SETTINGS.md`, clamping out-of-range values. `policy` and `endWarning` feed the
engine through `DefaultSessionEngine.apply(_ settings:)`, which the app calls on every
defaults change. It also holds the duration presets (add, replace, remove, move, reset).
`DurationText` is the shared `1h30m` duration syntax used by URLs, presets and, later, the CLI.

**Threading:** a value wrapper over `UserDefaults`; used on the main actor.

## Test support (`UAwakeCore/UAwakeCoreTesting`)
`FakeClock`, `FakeAssertionProvider` and `DeviceState.test(...)`, shared by every
package's tests. Never linked into the app.

## Rules (1.0)
No existing signature changed. Rule sessions are exempt from the maximum cap
(`DefaultSessionEngine.isCapped` leaves out `.rule`).

- **Rule, Condition, WeeklyWindow** (`UAwakeCore/Rule.swift`): the rule model. Codable as
  plist-compatible JSON; decoding clamps values and rejects rules without a name or
  conditions, or with an unknown condition type. `WeeklyWindow.contains` and
  `nextBoundary` are pure functions of a date and a `Calendar`.
- **RuleStore** (`UAwakeCore/RuleStore.swift`): `{ "version": 1, "rules": [...] }`. Missing file:
  no rules. Unreadable entries are kept as `JSONValue` and written back. A newer version is
  left untouched (`Problem.newerVersion`); a corrupt file is moved aside (`Problem.corrupt`).
- **Signal** (`UAwakeCore/Signals.swift`): the value each monitor reports, with `SignalKind`.
  Core stays Foundation-only.
- **RuleEngine** (`UAwakeCore/RuleEngine.swift`): `@MainActor @Observable`. Inputs:
  `update(_ Signal)`, `handle(SessionEvent)`, `handle(SessionLifecycleEvent)`, `setRules`,
  `setPause`, `permissions`, `preview`, `reset(_ SignalKind)`, `reevaluate()`. Outputs:
  `statuses` (`RuleStatus` per rule), `neededSignals`, `readings(for:)`, `rule(forSession:)`.
  It only calls `SessionEngine.start`/`stop`; the app forwards each `DeviceState` as
  `.power` *after* `SessionEngine.apply`. Guard waits re-arm after 5 min with no guard.
  One timer task on the `SessionClock` covers settle, linger, boundaries and pause end.
- **SignalMonitor, PermissionProvider** (`UAwakeSystem/SignalMonitor.swift`): one generic
  monitor protocol (`updates()` yields current value then changes) with a conformer per
  system source, and permission status/request. **SignalHub** runs a monitor only while
  `neededSignals` contains its kind.

**Threading:** model and signal values `Sendable`; `RuleEngine` and `SignalHub` `@MainActor`;
monitors `Sendable`.

## How later releases plug in
- **1.1 CLI:** an XPC protocol in UAwakeIPC mirrors `SessionEngine` (start, stopAll,
  status). The app's XPC listener hops to the main actor and calls the engine with
  source `.cli`. App Intents do the same with `.shortcut`.
- **1.3 MDM:** managed preferences produce a `GuardPolicy` (clamped/locked) and
  allowed-mode filters applied to `SessionRequest` before `start`. Kiosk mode is
  an `.mdm` session with `maximumCap = nil`. No contract change.
