# Changelog

All notable changes to uawake are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0-alpha.8] - 2026-11-23

Eighth internal alpha (version 1.0.0, build 8): lock and dim. Unsigned. Design and spike results:
`docs/LOCK-DIM-DESIGN.md`, `docs/SANDBOX-SPIKE.md`.

### Added
- **Lock now**: a popover button, an optional global shortcut (Lock & dim settings) and
  `uawake://lock`. It turns the display off (`pmset displaysleepnow`, screen saver as fallback);
  the session keeps running. If your Mac isn't set to ask for a password, or only after a long
  delay, the button reads "Screen off (no password required)" and links to System Settings › Lock
  Screen; uawake never says "lock" when it can't lock.
- **Auto-lock**: lock after 1–120 idle minutes while a session is active (off by default).
- **Dim when idle**: darken every display (20–90 %) after 1–120 idle minutes during a session (off
  by default). Any input removes it at once. Hidden from screen sharing, screenshots and
  recordings; the watermark can stay above it; skipped while another app keeps the display awake.
- Settings keys `LockShortcutKeyCode`, `LockShortcutModifiers`, `AutoLockEnabled`,
  `AutoLockMinutes`, `DimEnabled`, `DimMinutes`, `DimDarkness`, `DimKeepsWatermark`,
  `DimSkipsWhenPlaying` (docs/SETTINGS.md).

### Changed
- While the screen is locked, however it was locked, sessions drop their display assertion and keep
  the system (and on-power) ones; the display assertion returns on unlock.

## [1.0.0-alpha.7] - 2026-11-23

Seventh internal alpha (version 1.0.0, build 7): automatic updates. The first build that can
update itself; alpha.6 and earlier must be replaced by hand once. Unsigned.

### Added
- Automatic updates with Sparkle: uawake checks once a day (on by default) and asks before
  installing; main window › Updates has "Check for Updates…". Updates are verified with an EdDSA
  signature. The feed is `https://underscoretec.github.io/uawake/appcast.xml`; archives are the
  GitHub Release zips.
- Acknowledgements in the README.

### Changed
- The update channel (`UpdateChannel`) defaults to `beta` while uawake is in pre-release; alphas
  are published on it. It becomes `stable` with 1.0.

## [1.0.0-alpha.6] - 2026-11-23

Sixth internal alpha (version 1.0.0, build 6), from tester feedback: a new click model and a
clearer menu bar icon. Unsigned; the 8-hour performance soak is still to come before 1.0.

### Changed
- Click model: double-click the menu bar icon to start or stop the default session (as before,
  only manual and URL sessions count). A single click opens the popover once the system
  double-click interval has passed, so a single click never starts or stops anything; right-click
  and Option-click open it at once. Nothing changes on screen until the click is decided. The
  popover's idle card says "Tip: double-click the menu bar icon to start or stop."; the presets
  stay in the popover while a session runs. The General setting is now "Double-click the menu bar
  icon to keep awake for" (still Indefinite by default; key `PrimaryClickAction` unchanged).
- Menu bar icon: idle, the native dimmed look; awake, the bright cup with steam in a uawake-blue
  capsule, with the countdown (when on) inside it. The capsule turns amber within the end-warning
  window and red for about 3 seconds when a guard stops a session. Increase Contrast darkens it.
  It redraws only when its state or text changes. VoiceOver labels are unchanged.

### Added
- Appearance › "Highlight when active": Capsule (default), Coloured icon or None (key
  `MenuBarHighlight`: `capsule`, `colouredIcon`, `none`).

### Fixed
- `SignalHubTests.everyMonitorTypeIsForwardedAsItsSignal` no longer fails now and then: it waits for
  each signal and ignores the arrival order of independent streams (50 of 50 runs pass).
- A test now covers "On the power adapter, prevent all sleep" applying from launch (the alpha.4
  fix), through an injectable startup path.

## [1.0.0-alpha.5] - 2026-11-12

Fifth internal alpha (version 1.0.0, build 5): the on-screen watermark. Unsigned; the 8-hour
performance soak is still to come before 1.0.

### Added
- On-screen watermark (Appearance › "Show watermark on screen", off by default): a click-through
  overlay on every display while a session is active, showing "1:42 left" or "since 9:50" large
  with a small "AWAKE · uawake" above. Centred, Tiled (repeated diagonally) or Bouncing (glides
  around the screen). About 0.1% CPU in each style. Text and
  timer colours, opacity 5–40% (12% default) and three sizes. On by default: hidden from screen
  sharing, screenshots and recordings; hidden while presenting or when a full-screen app is in
  front; the centred style drifts every few minutes. Follows displays as they connect and
  disconnect. Reduce Motion stops drift and bouncing, Increase Contrast strengthens it, VoiceOver
  ignores it. Keys `Watermark*` in `docs/SETTINGS.md`.
- A global shortcut to show or hide the watermark (Appearance; keys `WatermarkShortcutKeyCode`,
  `WatermarkShortcutModifiers`).
- `scripts/overnight-test.sh` and `scripts/overnight-report.sh`: log every 30 s overnight and report
  gaps (sleep), uawake's assertions and macOS sleep and display events.

## [1.0.0-alpha.4] - 2026-11-12

Fourth internal alpha (version 1.0.0, build 4): the screen stays on, awake time, and an option to
prevent all sleep on the power adapter. Unsigned; the 8-hour performance soak is still to come
before 1.0.

### Added
- "On the power adapter, prevent all sleep" (General, off by default): on AC power, sessions also
  hold a `PreventSystemSleep` assertion, like `caffeinate -s`, shown in `pmset -g assertions` as
  `uawake: <reason> (on power)`. It is dropped on battery. Rules get the same option in the editor.
  Closing the lid still sleeps the Mac unless an external display is connected. Setting key
  `PreventSleepOnPower`; rule field `preventSleepOnPower`. The popover's status strip shows
  "No sleep on power" while it is in effect.
- "Allow the display to sleep during sessions" (General, off by default; key `AllowDisplaySleep`).
- `uawake://activate?display=0` starts a system-only session whatever the setting says.
- Sessions without an end time show how long they have kept the Mac awake: the hero reads
  "Awake for 2:14" with "since 9:50 AM · Indefinite" beneath, excluding paused time; rows show
  "since 9:50" (rules: since they started matching) or "until 20% battery · since 9:50".
- The hero says "Screen stays on" or "Screen can sleep".

### Fixed
- Manual and URL sessions now keep the display awake (`PreventUserIdleDisplaySleep`) as well as
  the system, so the screen no longer dims and locks during a session. Rules choose per rule with
  the editor's "Keep the display on" toggle (Presenting and On a call keep it on).
- "On the power adapter, prevent all sleep" now applies from launch; before, it took effect only
  after a setting changed.

## [1.0.0-alpha.3] - 2026-11-11

Third internal alpha (version 1.0.0, build 3): the new icon. Unsigned; the 8-hour performance
soak is still to come before 1.0.

### Changed
- New app icon and menu bar icon ("the cup", from the Underscore logo): steam while awake,
  plain cup when idle. Appearance keeps Cup, Eye and Bolt; `IconStyle` defaults to `uawake`.

### Fixed
- About shows the app icon at once instead of a grey placeholder.

## [1.0.0-alpha.2] - 2026-11-11

Second internal alpha (version 1.0.0, build 2): the rules engine. Unsigned; the 8-hour
performance soak is still to come before 1.0.

### Added
- Rules: keep the Mac awake automatically while conditions hold. Conditions: an app is open or
  in front, a call (camera or microphone in use), audio playing, the processor or network busy,
  the power adapter, an external display, a USB or Bluetooth device, a Wi-Fi network, a calendar
  event, and a schedule. Match all or any, active hours, a linger time, and system or display mode.
- Rules section in the main window: templates (Presenting, On a call, Building, Downloading,
  Plugged in at the office), an editor with a live Test view, and Pause Rules.
- Rules strip and rule sessions in the popover; guards win over rules, and a rule stopped by a
  guard waits until five minutes guard-free.
- Bluetooth, Location (Wi-Fi name) and Calendar permissions, asked only from explicit buttons.

### Fixed
- The popover sizes to its full content, up to the space below the menu bar, and scrolls only
  beyond that; it has an "Open uawake" button in the footer.
- The popover closes on a click outside it, an app switch or Esc.
- While the main window is open, uawake shows in the Dock and ⌘-Tab; closing it (⌘W) removes it.

## [0.1.0-alpha.1] - 2026-11-08

First internal alpha.

### Added
- Session engine: several sessions at once, each with its own IOKit power assertions named
  `uawake: <reason>`; durations, until a time, indefinite, and until the battery drains to a level.
- Menu bar icon with an optional countdown pill (minutes, then seconds in the final minute);
  primary click toggles the default session, secondary click or Option-click opens the popover.
- Popover with the current state, preset and "Until…" chips, extend buttons, sessions, a status
  strip and banners; a main window with Overview, Durations, Safety, Appearance, General, Updates and About.
- Safety guards: battery limit, Low Power Mode, thermal pressure and a maximum duration.
- Notifications before a session ends (Extend, Stop) and when a guard stops one.
- Fast user switching pauses sessions; sleep and wake keep wall-clock deadlines.
- `uawake://` URL scheme: activate, deactivate, toggle.
- Global shortcut, launch at login, first-run welcome window.
- Documented preference keys for MDM (docs/SETTINGS.md).
- Sparkle update integration (inactive until signing keys and a feed exist).
