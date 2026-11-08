# uawake — Product Specification

Nov 7, 2026 · @Abhijit

## Overview

uawake is a free, open-source macOS menu bar app that keeps a Mac awake on demand or automatically, built by Underscore Technology. It is inspired by KeepingYouAwake but is a clean build in Swift with a much wider scope: smart triggers, diagnostics, developer integrations and enterprise deployment.

**Who it is for**

- Everyday users who need the Mac awake during downloads, presentations, calls or long tasks.
- Developers and creators running builds, renders, exports and scripts.
- IT teams deploying a managed keep-awake policy across a Mac fleet, including kiosks and display Macs.

**Positioning.** KeepingYouAwake is open source but deliberately minimal. Amphetamine is feature-rich but closed source. uawake aims to be the open-source app with professional-grade automation, plus diagnostics, a CLI and MDM support that neither offers well. Other keep-awake apps named around "Awake" are competitors to watch, including an open-source Awake that warns about MDM policies and the paid AwakeBar.

**Product principles**

1. **Every session has a reason.** The app always shows what is keeping the Mac awake and why.
2. **Safe by default.** Battery, Low Power Mode, thermal and maximum-duration guards are on out of the box.
3. **Quiet.** One click for the common case; power features stay out of the way until needed.
4. **Scriptable.** Everything the UI does is reachable from the URL scheme, CLI and Shortcuts.
5. **Admin-friendly.** Every setting can be managed and locked by an MDM profile.
6. **Sandboxed core.** The main app stays sandboxed; anything needing root lives in a separate, optional helper.

## Decisions locked

| Area | Decision | Why |
| --- | --- | --- |
| Publisher | Underscore Technology open-source project; Abhijit Roy credited as creator and lead maintainer | Brand fit with the u-prefixed product family, credibility with technical audiences, continuity with a team behind it |
| Licence | MIT | Simple, permissive, compatible with KeepingYouAwake's licence |
| Origin | Clean build, no code or assets copied from KeepingYouAwake | No licence obligations; frees the design from the original's single-timer model |
| Credit | Optional one-line credit to KeepingYouAwake in README | Courtesy, not a legal requirement for a clean build |
| Language and UI | Swift 6, SwiftUI with AppKit only where needed | Modern UI, safer concurrency, faster development |
| Sleep control | IOKit power assertions, not the caffeinate binary | Per-session assertions with reasons, released automatically if the app exits |
| Minimum OS | macOS 14 Sonoma | Newer SwiftUI and Observation APIs; still covers older enterprise fleets |
| Distribution | GitHub and Homebrew; Developer ID signed, notarized, Sparkle updates; no Mac App Store | CLI and root helper don't fit the App Store |
| Sandbox | Main app sandboxed; CLI and Pro helper outside it | Keeps the everyday app safe and least-privileged |
| Localisation | English at launch; String Catalogs from the first commit; community translations after 1.0 | Translation becomes content work, not code work |
| Roadmap order | 0.1 Core, 1.0 Smart triggers, 1.1 Developer integrations, 1.2 Diagnostics, 1.3 Enterprise, 2.0 Pro helper | Rules engine first, since every later layer builds on sessions |

## Architecture

uawake is built around one session engine; every entry point only starts, stops or limits sessions, so new features plug in without reworking the core.

&#91;embedded content: uawake architecture · entry points, core, outputs\]

The menu bar, URL scheme, CLI, Shortcuts and rules engine all create sessions with a source and reason. Safety guards and MDM policy can end or limit them. The engine is the only part that holds power assertions.

### Key technical choices

- **Concurrency**: the session engine is isolated on the main actor; system monitors deliver events as async streams.
- **Storage**: settings in user defaults, which MDM can manage; rules as JSON in Application Support; session history in a local SQLite database from 1.2.
- **Inter-process communication**: URL scheme from 0.1; XPC between the app, CLI and helper from 1.1.
- **Entitlements**: App Sandbox, network client (update checks only), Bluetooth, camera (only to detect calls; no video is ever read), location and calendars (requested only when a rule needs them), user-selected files (rule import and export).

## Release 0.1 — Core

0.1 delivers a dependable keep-awake app with a session engine designed for everything that follows. It is the first public alpha.

### Session engine

A session is the unit everything works with. Each session has:

| Field | Values |
| --- | --- |
| Source | manual, URL scheme (later: rule, CLI, Shortcuts, MDM) |
| Reason | Human-readable text, e.g. "Manual: 2 hours" |
| Mode | Keep system awake (always); keep display awake (optional); keep disk awake (optional) |
| End condition | Duration, until a clock time, indefinite, until battery drains to X% (on battery power only) |
| State | Active, paused, ended (with end cause) |

- Several sessions can run at once. The Mac stays awake while any session is active, using the combined modes of all active sessions.
- Each session holds its own IOKit assertions, named `uawake: <reason>`, so they show up in `pmset -g assertions`. Assertion names stay in English; reasons are localised only in the app's UI.
- Ending a session releases its assertions immediately. If the app quits or crashes, macOS releases them automatically.
- Every session end records a cause: expired, stopped by user, battery guard, Low Power Mode, thermal guard, maximum cap, app quit.

### Durations

- Presets: 15 min, 30 min, 1 h, 2 h, 5 h, indefinite. Users can add, edit, remove and reorder presets.
- Custom duration entry and "until" a clock time, e.g. until 18:30.
- Extend a running session by +15 min or +1 h from the menu or a notification. Extend applies only to sessions with a deadline (duration or until-time), not to indefinite or battery-level sessions.
- A default action for the primary click, set by the user (default: indefinite).

### Menu bar and popover

- Menu bar icon with clear active and inactive states, in light and dark appearance.
- Optional remaining-time text beside the icon, e.g. 1:42.
- Primary click toggles the default session; secondary click (or Option-click) opens the popover.
- Popover contents: on/off control, remaining time, preset duration chips, "until" picker, extend buttons, list of active sessions with their reasons and a stop button each, links to Settings and Quit.
- Global keyboard shortcut to toggle, set by the user (no Accessibility permission needed).

### Safety guards

All guards are on by default and adjustable in Settings.

| Guard | Default | Behaviour |
| --- | --- | --- |
| Battery | End sessions at 20% when on battery | Threshold 5–95%; ignored on AC power |
| Low Power Mode | End sessions when Low Power Mode turns on | On/off |
| Thermal | End sessions when the system reports serious or critical thermal state | On/off |
| Maximum cap | Indefinite sessions end after 24 h | 1–72 h, or off; also applies to battery-level sessions; counted from the session start, including paused time |

When a guard ends a session, the user gets a notification naming the guard.

### System events

- Fast user switching: sessions pause when the user's session becomes inactive and resume with the remaining time when it returns.
- After the Mac wakes from a forced sleep (lid closed, Apple menu Sleep), active sessions continue. Deadlines are wall-clock times, so time spent asleep counts towards a session's duration.
- Launch at login through `SMAppService`, off by default, offered during first run.

### URL scheme

| URL | Action |
| --- | --- |
| `uawake://activate` | Start an indefinite session |
| `uawake://activate?duration=90m` | Start a timed session; accepts s, m, h units |
| `uawake://activate?until=18:30` | Session until a clock time |
| `uawake://activate?display=1&reason=Render` | Optional display mode and reason |
| `uawake://deactivate` | End all manual and URL sessions |
| `uawake://toggle` | Stop all manual and URL sessions if any are running, otherwise start the default session; rule and CLI sessions are unaffected |

Invalid URLs change nothing and log a warning; they never leave the UI out of sync with the actual state.

### Notifications

- Warning before a timed session ends (default 5 min, adjustable or off), with Extend and Stop actions.
- Notice when a guard ends a session.

### Settings window

Tabs: General (launch at login, primary click action, shortcut), Durations, Safety, Appearance (icon style, countdown text), Updates (Sparkle channel: stable or beta), About (version, credits, licence).

### First run

A short welcome sheet: what uawake does, enable notifications, enable launch at login.

### Acceptance criteria

- [ ] Starting any session creates assertions visible in `pmset -g assertions` with the session's reason.
- [ ] Stopping a session removes its assertions within 1 second.
- [ ] Killing the app with `kill -9` leaves no uawake assertions behind.
- [ ] Two overlapping sessions keep the Mac awake until the later one ends.
- [ ] Each guard ends sessions at its threshold and sends a notification naming it.
- [ ] A session survives fast user switching with the correct remaining time.
- [ ] Every URL in the table works; an invalid URL changes nothing.
- [ ] Menu bar countdown stays accurate to within 1 second over a 2-hour session.
- [ ] All user-facing strings come from the String Catalog.
- [ ] Session engine unit test coverage of at least 85%.

## Release 1.0 — Smart triggers

1.0 adds a rules engine that starts and ends sessions automatically. It is the first stable public release.

### How rules work

- A rule has a name, one or more conditions, a match mode (all or any), the awake modes to apply, and an optional linger time.
- While the rule's conditions are met, it holds one session with source "rule" and the rule's name as the reason.
- When the conditions stop being met, the session ends after the linger time (default 2 min), so brief dips don't cause sleep.
- Rules can also carry an active-hours window, e.g. a rule that only applies on weekdays 9:00–19:00.
- Safety guards always win over rules. A rule that a guard has ended stays off until its conditions clear and return.
- "Pause all rules" for 1 h, until tomorrow, or until turned back on. Manual sessions are unaffected.

### Conditions

| Condition | Example | Detection | Permission |
| --- | --- | --- | --- |
| App running | Xcode is open | Workspace app notifications | None |
| App frontmost | Keynote is in front | Workspace activation notifications | None |
| Call in progress | Camera or microphone in use | Core Audio and CoreMediaIO device state; needs the camera entitlement | None |
| Audio playing | Any output audio active | Core Audio output device state | None |
| CPU busy | Above 50% for 1 min | Whole-system processor load, sampled every 10 s; per-process only for apps uawake can already see | None |
| Network busy | Above 1 MB/s for 1 min | Interface byte counters, sampled every 10 s | None |
| Power adapter | Connected | Power source notifications | None |
| External display | Any or a named display connected | Screen change notifications | None |
| USB or Bluetooth device | Dock or named headset connected | IOKit device notifications | Bluetooth entitlement for Bluetooth |
| Wi-Fi network | Office network name | CoreWLAN | Location |
| Calendar event | An event is in progress, optionally matching a calendar or keyword | EventKit | Calendar |
| Schedule | Weekdays 9:00–19:00 | Internal timer | None |

Permissions are requested only when a user adds a rule that needs them. Without the permission, the rule shows a clear warning and stays inactive.

### Rule editor

- A Rules tab in Settings lists rules with on/off switches and a live indicator showing which rules are matching right now.
- The editor builds a rule from condition rows, with app pickers, device pickers and threshold sliders, not free text.
- A "Test" view shows each condition's current value, e.g. CPU 34% against a 50% threshold.
- Starter templates: Presenting (Keynote or PowerPoint frontmost), On a call, Building (Xcode or a CPU threshold), Downloading (network threshold), Plugged in at the office (power plus Wi-Fi).

### Popover changes

- Active sessions show their source, so users see "Rule: On a call" separately from manual sessions.
- A Rules section with the pause control and matching rules.

### Performance budget

With 10 rules enabled, uawake's average CPU use stays below 0.5% and memory below 60 MB. Event-driven detection is used wherever possible; sampling is limited to CPU and network conditions.

### Acceptance criteria

- [ ] Each condition type starts a session within its detection window and ends it after the linger time.
- [ ] All-match and any-match rules behave correctly with three or more conditions.
- [ ] Active-hours windows start and stop rules at the right local time, including across midnight.
- [ ] A guard ending a rule session is not undone until the rule's conditions clear and return.
- [ ] Pause all rules works for each duration and leaves manual sessions running.
- [ ] Rules needing a permission ask only when added and show a warning if it's denied.
- [ ] The performance budget holds over an 8-hour soak test.
- [ ] Rules persist across restarts and upgrades from 0.1.

## Releases 1.1 to 2.0 — outlines

These releases are outlined for direction; each gets a full spec before its build starts.

### 1.1 — Developer integrations

- **CLI** (`uawake`), installed through Homebrew. Commands: `on [duration|--until time] [--display] [--reason text]`, `off`, `status [--json]`, `run [--display] -- <command>` (keeps the Mac awake until the command exits and passes through its exit code), `rules list|pause|resume`.
- The CLI talks to the running app over XPC, and launches it if needed. Sessions show source "CLI".
- **App Intents** for Shortcuts and Spotlight: Start session, Stop sessions, Get status, Pause rules. This also enables Focus-mode triggers through Shortcuts automations.
- **AppleScript** dictionary with the same actions.
- Raycast and Alfred extensions, community-maintained with a reference implementation.

### 1.2 — Diagnostics

- **"Why won't my Mac sleep?"** view listing every app and process currently holding a sleep or display assertion, with its name, type and how long it has held it.
- **Session history**: what kept the Mac awake, the source and reason, start, end and end cause; kept for 30 days, exportable to CSV.
- **Sleep/wake timeline**: when the Mac actually slept and woke, recorded by uawake from install onward, with uawake sessions overlaid. The CLI can show the full system history, which the sandboxed app cannot read.
- The sandbox spike confirmed that other apps' assertions are readable from the sandbox; the system sleep/wake log is not.

### 1.3 — Enterprise

- **Managed preferences**: every setting can be set and locked through an MDM configuration profile; locked settings show a "Managed by your organisation" label.
- Admin controls: allowed modes, maximum session length, guard thresholds, allowed rule types, pre-installed rules.
- **Role presets**: Presenter, Build machine, Kiosk; selectable by users or enforced by MDM.
- **Import and export** of rules and settings as a file.
- **Kiosk mode**: auto-start at login, an indefinite session with no cap, auto-recovery after crashes through a small bundled launch agent (SMAppService with KeepAlive), and a minimal or hidden menu bar presence.
- Published admin guide with a sample configuration profile.

### 2.0 — Pro helper (separate, optional download)

- A signed privileged helper installed with the user's explicit approval, managed through `SMAppService`.
- **Lid-closed awake** without an external display, with mandatory thermal and battery safeguards.
- **Scheduled wake** from sleep at set times.
- **Run then sleep or shut down**: when a session or command ends, put the Mac to sleep or shut it down.
- The main app works fully without the helper; helper features appear only once it is installed.

## Repository, build and distribution

uawake lives in one public repository under Underscore's GitHub organisation, with every release built, signed and published by CI.

### Repository layout

| Path | Contents |
| --- | --- |
| `App/` | Menu bar app target: popover, settings, first run |
| `Packages/UAwakeCore/` | Session engine, assertions, guards, rules engine, persistence |
| `Packages/UAwakeSystem/` | System monitors: power, battery, thermal, displays, devices, audio, network, CPU |
| `Packages/UAwakeIPC/` | URL scheme parsing, XPC protocol (from 1.1) |
| `CLI/` | `uawake` command-line tool (from 1.1) |
| `Helper/` | Pro helper (from 2.0) |
| `Config/Version.xcconfig` | The single source of the version number |
| `docs/` | User guide, admin guide, appcast feeds |
| `.github/` | CI workflows, issue and pull request templates |

### Git workflow

- `main` is always releasable. Work happens on short-lived branches that are merged and deleted promptly; no long-running branches.
- Every pull request runs build, unit tests and lint before merge.
- Releases are tags on `main`: `v0.1.0`, `v1.0.0-beta.1` and so on, following semantic versioning.

### Release pipeline

1. Tag pushed on `main`.
2. CI archives the app, signs it with Underscore's Developer ID, and submits it for notarization.
3. The notarization ticket is stapled; the app is packaged as a DMG and a zip.
4. The update is signed for Sparkle and the appcast is updated (stable or beta feed).
5. A GitHub Release is published with notes; the Homebrew cask is updated.

Signing certificates and notarization credentials are stored as encrypted CI secrets, never in the repository. Before each release, SandboxProbe is rerun with a Developer ID-signed build, since ad-hoc signing can behave differently for login items and permission prompts.

### Community files

README (with screenshots, install steps and the KeepingYouAwake credit), LICENSE (MIT), CONTRIBUTING, CODE\_OF\_CONDUCT, SECURITY (how to report vulnerabilities), CHANGELOG, and issue templates for bugs, feature requests and translations.

## Quality

The session engine and rules engine are tested hardest, because a keep-awake app that silently fails is worse than none.

### Testing strategy

| Layer | How it is tested |
| --- | --- |
| Session engine, guards, rules | Unit tests with injected fake clocks and fake system monitors; at least 85% coverage |
| Power assertions | Integration tests that create and release real assertions and check them with `pmset -g assertions` |
| System monitors | Each monitor behind a protocol, tested with recorded event sequences |
| URL scheme, CLI | Parser unit tests plus end-to-end tests against the running app |
| UI | SwiftUI previews for every state; a small set of UI tests for the popover and settings |
| Concurrency | Swift 6 strict concurrency checking enabled; Thread Sanitizer run in CI |
| Soak | 8-hour run with rules enabled before each release, measuring CPU, memory and session accuracy |

### Non-functional requirements

- **Reliability**: no leftover assertions after any exit, crash or upgrade.
- **Resource use**: idle CPU under 0.1%; under 0.5% with 10 rules; memory under 60 MB.
- **Privacy**: no analytics, no network calls except Sparkle update checks; history stays on the Mac.
- **Accessibility**: full VoiceOver labels, keyboard navigation in all windows, works with Increase Contrast and Reduce Motion.
- **Security**: hardened runtime, minimal entitlements, signed and notarized builds only.
- **Compatibility**: macOS 14 and later, Apple silicon and Intel.

## Risks and open items

### Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Some detection (full process list, system sleep/wake log) is blocked in the sandbox | Weaker CPU, process or diagnostics features | Sandbox spike done (docs/SANDBOX-SPIKE.md); blocked items moved to the CLI or narrowed; SandboxProbe rerun on every macOS beta |
| macOS changes power or privacy behaviour in a new release | Triggers or guards stop working | Test against each macOS beta from June; keep detection behind protocols so one monitor can be replaced |
| Lid-closed awake causes overheating | Hardware damage, reputational harm | Ships only in the optional 2.0 helper, with thermal and battery guards that can't be disabled |
| Scope across five releases outgrows a small team | Slow releases, abandoned features | Releases ship independently; each gets a full spec only when its build is next |
| Signing or notarization credentials leak | Malicious builds signed as Underscore | Credentials only in encrypted CI secrets with restricted access; rotate on any doubt |

### Open items

- [ ] Name: uawake confirmed. Still to do: formal Class 9 trademark search in India, the US and the EU; register the domain, GitHub repository, Homebrew cask and social handles; always present it as "uawake — keep your Mac awake", since search engines correct the name to "awake".
- [ ] Apple Developer Program: confirm Underscore Technology's organisation enrollment for Developer ID signing.
- [ ] Icon and visual identity: commission or design the app icon and menu bar icons.
- [ ] GitHub organisation name for Underscore's open-source work.
- [ ] Decide whether AI-assisted contributions are welcome, and say so in CONTRIBUTING.
- [ ] Sandbox spike done. Remaining live checks: fast user switching before 0.1 ships; camera, microphone, audio, USB, display, Bluetooth, Wi-Fi and calendar before 1.0; managed preferences before 1.3.
