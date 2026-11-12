# Changelog

All notable changes to uawake are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
