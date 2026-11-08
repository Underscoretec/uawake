# uawake settings

All settings live in the app's user defaults (domain `com.underscoretec.uawake`), under
the keys below. They use plain property-list types so an MDM configuration profile can
set and lock them from 1.3. Keys are stable: new keys may be added, existing ones are
never renamed or retyped.

Out-of-range values (from a profile or `defaults write`) are clamped to the range; values
of the wrong type are ignored and the default is used. Changes apply to running sessions
immediately.

| Key | Type | Default | Range / values | Effect |
| --- | --- | --- | --- | --- |
| `BatteryGuardEnabled` | Boolean | `true` | | End sessions on battery power at or below the threshold |
| `BatteryGuardThreshold` | Integer | `20` | 5–95 (%) | Battery guard threshold |
| `LowPowerModeGuardEnabled` | Boolean | `true` | | End sessions when Low Power Mode turns on |
| `ThermalGuardEnabled` | Boolean | `true` | | End sessions at serious or critical thermal state |
| `MaximumCapEnabled` | Boolean | `true` | | Cap indefinite and battery-level sessions |
| `MaximumCapHours` | Integer | `24` | 1–72 | Cap length, counted from session start including paused time |
| `DurationPresets` | Array of strings | `15m`, `30m`, `1h`, `2h`, `5h`, `indefinite` | Up to 12 unique entries | Popover preset chips, in order |
| `PrimaryClickAction` | String | `indefinite` | A preset value | Session started by the primary click and `uawake://toggle` |
| `EndWarningMinutes` | Integer | `5` | 0–60; 0 = off | Warning before a timed session ends |
| `ShowsCountdown` | Boolean | `false` | | Remaining time beside the menu bar icon |
| `UpdateChannel` | String | `stable` | `stable`, `beta` | Sparkle update feed |

**Preset values** are `indefinite` or a duration of `h`, `m`, `s` parts in that order, each
at most once: `45s`, `90m`, `1h30m`. Unreadable entries are skipped.

**Not stored here:**
- Launch at login is held by the system (`SMAppService`). Admins manage it with the
  `com.apple.servicemanagement` login-items payload.
- The global shortcut and icon style will be added in 0.1 slice 2, alongside the UI that sets them.

## Testing locally

```sh
defaults write com.underscoretec.uawake BatteryGuardThreshold -int 30
defaults write com.underscoretec.uawake DurationPresets -array 10m 1h indefinite
defaults delete com.underscoretec.uawake          # back to defaults
```

The app reads the new values the next time it applies settings: on launch, and on any
in-process defaults change. Live pickup of out-of-process changes (`defaults write`, MDM)
is planned for 1.3. Managed (forced) keys can be tested with a configuration profile; see
the managed-preferences section of `docs/SANDBOX-SPIKE.md`.
