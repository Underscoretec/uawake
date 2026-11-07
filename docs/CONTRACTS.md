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
`sessions` is observable for SwiftUI; `endedSessions()` streams every end with its
cause for notifications and, later, history.

- **Toggle** (menu bar primary click and `uawake://toggle`): only manual and URL
  sessions count as "on". If any exist they are stopped; otherwise the default
  session starts. Rule and CLI sessions are never stopped or counted.
- **Extend** works only on duration and until-time sessions; others throw
  `notExtendable` and the UI hides the control.
- **Policy**: setting `policy` recomputes the cap deadline of active capped sessions.
- **Device state**: `apply(_:)` ends reached battery-level sessions, then guard verdicts.
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
`ContinuousClock` sleep (which counts time asleep); the fake advances time manually
and resumes sleepers whose deadline has passed, making timed tests instant.

**Threading:** `Sendable`.

## Guard and GuardPolicy (`UAwakeCore/Guard.swift`)
A `Guard` is a pure function: given a `DeviceState`, the live sessions and a
`GuardPolicy`, it returns `GuardVerdict`s (session id + `EndCause`). The engine
re-evaluates on every device-state change. The maximum cap is time-based, so the
engine applies it as a deadline rather than a guard. `GuardPolicy` holds thresholds
with spec defaults (20% battery, LPM on, thermal on, 24 h cap).

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

**Threading:** `Sendable` values; parse anywhere.

## How later releases plug in
- **1.0 rules:** a `RuleEngine` in Core consumes new monitors (also `AsyncStream`
  protocols in UAwakeSystem) and calls `start`/`stop` with source `.rule` and
  reason `.rule(name:)`. "Guard ended it, stay off" is rule-engine state, read from
  `endedSessions()`. No contract change.
- **1.1 CLI:** an XPC protocol in UAwakeIPC mirrors `SessionEngine` (start, stopAll,
  status). The app's XPC listener hops to the main actor and calls the engine with
  source `.cli`. App Intents do the same with `.shortcut`.
- **1.3 MDM:** managed preferences produce a `GuardPolicy` (clamped/locked) and
  allowed-mode filters applied to `SessionRequest` before `start`. Kiosk mode is
  an `.mdm` session with `maximumCap = nil`. No contract change.
