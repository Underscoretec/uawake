# uawake

uawake — keep your Mac awake. Free, open-source (MIT) macOS menu bar app by
Underscore Technology. Keeps a Mac awake on demand or automatically, built around
one session engine. Full spec: `docs/SPEC.md`. Contracts: `docs/CONTRACTS.md`.

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
- Roadmap order: 0.1 Core → 1.0 Smart triggers → 1.1 Dev integrations → 1.2 Diagnostics → 1.3 Enterprise → 2.0 Pro helper.

## Repo layout
| Path | Contents |
| --- | --- |
| `App/` | Menu bar app: popover, settings, first run |
| `Packages/UAwakeCore/` | Session engine, assertions, guards, rules engine, persistence |
| `Packages/UAwakeSystem/` | System monitors: power, battery, thermal, displays, devices, audio, network, CPU |
| `Packages/UAwakeIPC/` | URL scheme parsing; XPC protocol from 1.1 |
| `CLI/` | `uawake` CLI (from 1.1) |
| `Helper/` | Pro helper (from 2.0) |
| `Config/Version.xcconfig` | Single source of version and build number |
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
- Inject `FakeClock`, `FakeAssertionProvider`, `FakeDeviceStateMonitor` through the protocols. No real sleeps or real time in unit tests.
- Session engine coverage target: ≥ 85%.
- Real IOKit assertions are checked only in integration runs with `pmset -g assertions`.

## Git
- Work on `main`; one commit per phase or unit of work.
- Never `git push`. No Co-Authored-By or generated-with attribution lines.

## Clean-build rule
Never fetch, read, clone or reference KeepingYouAwake source or assets. Work only from
`docs/SPEC.md` and Apple documentation.

## Build and test
Needs Xcode 26+ and XcodeGen. `uawake.xcodeproj` is generated from `project.yml` and not committed.
- `make generate` / `make build` / `make test` (each package's `swift test` with warnings as
  errors, then the app tests) / `make lint` / `make format` / `make clean`.
- One package: `cd Packages/<Name> && swift test`.
- App: `build/DerivedData/Build/Products/Debug/uawake.app`. Check with `pmset -g assertions | grep uawake`.
- Local builds are ad-hoc signed (`CODE_SIGN_IDENTITY "-"`); Debug omits the hardened runtime, Release has it.
- New UI strings: add the key to `App/Resources/Localizable.xcstrings` (Xcode adds them when building in the IDE).

## Critical gotchas
- Assertion names must be `uawake: <reason>` so they appear in `pmset -g assertions`.
  Reasons are structured (`SessionReason`); names use `englishDescription`, never localized.
  The UI renders reasons localized.
- Toggle (primary click, `uawake://toggle`) counts and stops only manual and URL sessions.
- Maximum cap: only indefinite and battery-level sessions; deadline `startedAt + cap`,
  recomputed when `GuardPolicy` changes; ends with `.maximumCap`, never `.expired`.
- Extend: only duration and until-time sessions; otherwise the engine throws `.notExtendable`.
- Battery-level X ends only on battery power at or below X; never "charge up to".
- Fast user switching (pause/resume) and sleep/wake are 0.1 requirements, via
  `SessionLifecycleMonitor` → `SessionEngine.handle(_:)`.
- Do not name our clock protocol `Clock` — it shadows Swift's `Clock`; it is `SessionClock`.
- Deadlines are wall-clock `Date`s, so they hold across system sleep.

## Roadmap
- 0.1 Core: session engine, presets, popover, guards, URL scheme, notifications.
- 1.0 Rules engine (source `.rule`).
- 1.1 CLI over XPC, App Intents, AppleScript.
- 1.2 Diagnostics: other apps' assertions, history (SQLite), sleep/wake timeline.
- 1.3 MDM managed preferences, role presets, kiosk mode.
- 2.0 Privileged Pro helper: lid-closed awake, scheduled wake.
