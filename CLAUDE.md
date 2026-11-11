# uawake

uawake — keep your Mac awake. Free, open-source (MIT) macOS menu bar app by
Underscore Technology. Keeps a Mac awake on demand or automatically, built around
one session engine. Spec: `docs/SPEC.md`. Contracts: `docs/CONTRACTS.md`. Rules: `docs/RULES-DESIGN.md`.

## Principles
1. Every session has a reason — the app always shows what keeps the Mac awake and why.
2. Safe by default — battery, Low Power Mode, thermal and max-duration guards on out of the box.
3. Quiet — one click for the common case.
4. Scriptable — everything in the UI is reachable from URL scheme, CLI, Shortcuts.
5. Admin-friendly — every setting manageable and lockable via MDM.
6. Sandboxed core — anything needing root lives in a separate optional helper.

## Locked decisions
- Publisher: Underscore Technology; Abhijit Roy creator and lead maintainer. Licence: MIT.
- Clean build: no code or assets from KeepingYouAwake (optional README credit only).
- Swift 6, strict concurrency, SwiftUI; AppKit only where SwiftUI can't do it.
- Sleep control: IOKit power assertions (`IOPMAssertionCreateWithName`/`IOPMAssertionRelease`), never `caffeinate`.
- Minimum macOS 14 Sonoma. Apple silicon and Intel.
- Distribution: GitHub + Homebrew, Developer ID signed, notarized, Sparkle. No Mac App Store.
- Main app sandboxed; CLI and Pro helper outside it.
- English at launch; every user-facing string in `Localizable.xcstrings` from the first line of UI.

## Repo layout
| Path | Contents |
| --- | --- |
| `App/` | Menu bar app: popover, settings, first run |
| `Packages/UAwakeCore/` | Session engine, guards, `RuleEngine`, `RuleStore`, settings |
| `Packages/UAwakeSystem/` | System monitors, `SignalHub`, permissions |
| `Packages/UAwakeIPC/` | URL scheme parsing and routing; XPC protocol from 1.1 |
| `CLI/` | `uawake` CLI (from 1.1) |
| `Helper/` | Pro helper (from 2.0) |
| `Config/Version.xcconfig` | Single source of version and build number |
| `Tools/SandboxProbe/` | Sandbox spike app, not shipped; `make probe`. Results: `docs/SANDBOX-SPIKE.md` |
| `docs/` | Spec, contracts, user/admin guides, appcast feeds |
| `.github/` | CI, issue and PR templates |

Dependency direction: App → IPC, System → Core. Core imports nothing but Foundation.

## Coding conventions
- Swift API Design Guidelines. Format with `swift-format` using `.swift-format`.
- No force unwraps (`!`, `try!`, `as!`) outside tests.
- Logging: `os.Logger(subsystem: "com.underscoretec.uawake", category: <module>)`, one category per module
  (`core`, `system`, `ipc`, `app`). Expected failures (e.g. an invalid URL) log at `.warning`, not `.error`.
- `SessionEngine` is `@MainActor`; providers, clocks, guards and monitors are `Sendable`; monitors deliver `AsyncStream`s.
- Only the engine holds assertions. Entry points start/stop/limit sessions; they never call IOKit.
- IOKit and AppKit conformers (`IOKitAssertionProvider`, system monitors) live in UAwakeSystem;
  Core stays Foundation-only. The app wires monitors to `engine.apply`/`engine.handle`.

## Testing
- Swift Testing in each package's test target.
- Inject `FakeClock`, `FakeAssertionProvider`, fake monitors through the protocols. No real sleeps or time.
- Session and rule engine coverage target: ≥ 85%.
- Real IOKit assertions are checked only in integration runs with `pmset -g assertions`.

## Git
- Work on `main`; one commit per phase or unit of work.
- Never `git push`. No Co-Authored-By or generated-with attribution lines.

## Clean-build rule
Never fetch, read, clone or reference KeepingYouAwake source or assets; work only from
`docs/SPEC.md` and Apple docs.

## Build and test
Needs Xcode 26+ and XcodeGen. `uawake.xcodeproj` is generated from `project.yml` and not committed.
- `make generate` / `make build` / `make test` (each package's `swift test` with warnings as
  errors, then the app tests) / `make lint` / `make format` / `make clean` / `make clean-apps`.
- One package: `cd Packages/<Name> && swift test`.
- Build output goes in `build.noindex/`; throwaway copies in `build.noindex/tmp`. Stray `uawake.app`
  copies steal `uawake://`: `make clean-apps` (keeps current DerivedData products).
- App: `build.noindex/DerivedData/Build/Products/Debug/uawake.app`. Check: `pmset -g assertions | grep uawake`.
- Local builds are ad-hoc signed; Debug omits the hardened runtime, Release has it.
- `make uitest` runs the UI tests. They need UI automation allowed for Xcode's runner.
- `make screenshots` regenerates `docs/design/screenshots/` (light, dark): once per gate, never per fix.
- `make release`: DMG and zip (`docs/RELEASING.md`); unsigned stub without a Developer ID.
  `scripts/acceptance.sh`, `scripts/perf-sample.sh` give evidence. Never commit `docs/design/reference/`.
- `make strings` syncs `Localizable.xcstrings`; run it after any UI text change.

## Critical gotchas
- Assertion names are `uawake: <reason>` (`SessionReason.englishDescription`, never localized);
  the UI renders reasons localized.
- Toggle (primary click, `uawake://toggle`) counts and stops only manual and URL sessions.
- Maximum cap: only non-rule indefinite and battery-level sessions; deadline `startedAt + cap`,
  recomputed when `GuardPolicy` changes; ends with `.maximumCap`, never `.expired`.
- Extend: only duration and until-time sessions; otherwise the engine throws `.notExtendable`.
- Battery-level X ends only on battery power at or below X; never "charge up to".
- Fast user switching and sleep/wake: `SessionLifecycleMonitor` → `SessionEngine.handle(_:)`.
- The clock protocol is `SessionClock`, not `Clock` (which would shadow Swift's).
- Deadlines are wall-clock `Date`s, so they hold across system sleep.
- `SystemClock` holds a latency-critical activity for the final 60 s before a deadline (App Nap).
- The app uses the AppKit lifecycle (`main.swift`, `AppDelegate`), not a SwiftUI `App`:
  `NSStatusItem` + `NSPopover` because `MenuBarExtra` can't tell primary from secondary clicks.
  Windows host SwiftUI via `HostingWindowController`; sections are `MainSection` in `MainWindowView`.
- Design: shared components in `DesignSystem.swift`. Colour always paired with an icon and
  text: green awake, amber near a limit, red stopped by a guard.
- `-UITesting`: throwaway settings, no welcome window, popover in a stand-in panel.
  `-UITestDeviceState battery|lowPower` fixes power. `-UITestRules` loads fixture rules with
  scripted signals and no monitors (keep it time-independent); `-UITestRulesSection`,
  `-UITestRuleEditor edit|test`. Screenshots must click inside the window before shooting.
- Rules: the app forwards each `DeviceState` to `RuleEngine` as `.power` *after*
  `engine.apply`, plus every `SessionEvent` and lifecycle event. Monitors run only through
  `SignalHub` for `neededSignals`. A guard end waits until 5 min guard-free; only a user stop
  latches until conditions clear and return.
- Permissions (Bluetooth, Location, Calendar) are requested only from explicit buttons. Never
  touch IOBluetooth before Bluetooth is granted: it prompts.
- Settings keys are public API for MDM (`docs/SETTINGS.md`): add keys, never rename them.
  The UI binds with `@AppStorage(SettingsKey.x.rawValue)`.
- Guards apply at start too: `start` throws `.wouldEndImmediately(cause)` instead of
  creating a session that would end at once.
- Ad-hoc hardened builds can't load Sparkle.framework (no Team ID): local Release runs use
  `ENABLE_HARDENED_RUNTIME=NO`.
- XCUITest's `launch()` terminates every running uawake (same bundle id). Never run UI tests
  during a long acceptance run. `-Headless` runs keep isolated settings and show no windows.
- Popover colours come from `Palette` (WCAG AA, ContrastTests); no `.secondary`/`.orange` text.
- Use `/usr/bin/log show` (zsh's `log` shadows it).

## Roadmap
- 0.1 Core: session engine, presets, popover, guards, URL scheme, notifications.
- 1.0 Rules engine (source `.rule`).
- 1.1 CLI over XPC, App Intents, AppleScript.
- 1.2 Diagnostics: other apps' assertions, history (SQLite), sleep/wake timeline.
- 1.3 MDM managed preferences, role presets, kiosk mode.
- 2.0 Privileged Pro helper: lid-closed awake, scheduled wake.
