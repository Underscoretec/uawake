# Changelog

All notable changes to uawake are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - Unreleased

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
