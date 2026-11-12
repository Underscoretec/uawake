# Sandbox spike

Which detection and system APIs work from the sandboxed uawake app. The probe app lives in
`Tools/SandboxProbe/` and is never shipped. Rerun it against every new macOS beta.

**Tested on:** macOS 27.0.1 (26A434), Xcode 27.2 (27B52), MacBook Air (Mac17,3, Apple M5).
**Build:** Release, ad-hoc signed, App Sandbox and hardened runtime on. Base entitlements match
uawake (`app-sandbox`, `network.client`). Probe-only extras: `device.bluetooth`,
`personal-information.location`, `personal-information.calendars`, and `device.camera`
(added after the camera probe failed without it; see below).
**Date:** 8 Nov 2026.

## Results

| Probe | Release | Result | Permission needed | Notes | Fallback |
| --- | --- | --- | --- | --- | --- |
| Global hotkey (Carbon `RegisterEventHotKey`) | 0.1 | Works | None | Registered with `noErr`. Presses delivered while other apps were frontmost. No Accessibility prompt. | — |
| Battery, power source, Low Power Mode, thermal | 0.1 | Works | None | IOKit power-source notifications and `ProcessInfo` notifications. AC↔battery and LPM on/off each arrived as events within about a second. Thermal state read as nominal; a change was not provoked. | — |
| Sleep/wake notifications | 0.1 | Works | None | `NSWorkspace` `willSleep` and `didWake` were both delivered. | — |
| Fast user switching notifications | 0.1 | Untested | — | No second user account on the test Mac. The `NSWorkspace` session notifications are registered by the same code as sleep/wake. | Pending manual check before 0.1 ships. |
| `SMAppService.mainApp` login item | 0.1 | Works | None | `register()` returns `enabled` immediately. macOS shows a "Login Item Added" notification; no approval step. | — |
| `SMAppService.agent` with KeepAlive | 1.3 | Works | None | Registered from the sandbox. The bundled agent (itself sandboxed) launched. After `kill`, launchd respawned it (`runs = 2`). The in-app pid check failed only because `proc_listallpids` is blocked; use `SMAppService.status`. | — |
| Running apps and frontmost app (`NSWorkspace`) | 1.0 | Works | None | 104 running apps listed; activation notifications delivered. | — |
| Camera in use (CoreMediaIO `DeviceIsRunningSomewhere`) | 1.0 | Works with entitlement | `com.apple.security.device.camera` entitlement. No prompt appeared while listing devices. | Without the entitlement the sandbox sees **0** devices (unsandboxed: 2). With it: "MacBook Air Camera: idle; Desk View Camera: idle". Live in-use check pending. | If a prompt appears in the live check: narrow "On a call" to the microphone. |
| Microphone in use (Core Audio input devices) | 1.0 | Works | None (no audio-input entitlement) | Lists inputs (built-in mic, Teams, recorder) as idle. Live in-use check pending. | — |
| Audio output playing (default output device) | 1.0 | Works | None | Reads `DeviceIsRunningSomewhere`. It reports that an app has output running, which is not necessarily audible sound. Live in-use check pending. | — |
| CPU load | 1.0 | Works (system-wide); Limited (process list) | None | `host_statistics` gives whole-system load. `proc_pidinfo` works for a known pid (Finder). `proc_listallpids` returns 0, so processes can't be enumerated. | The spec only needs whole-system CPU. Per-app CPU is possible for apps found via `NSWorkspace`. |
| Network throughput (`getifaddrs` counters) | 1.0 | Works | None | Per-interface byte counters readable. `if_data` counters are 32-bit and wrap at 4 GiB, so deltas must use wrapping subtraction. | — |
| Displays and connect/disconnect | 1.0 | Works (list); pending (events) | None | `NSScreen.localizedName` and built-in flag readable. Connect/disconnect not exercised. | Pending manual check (1.0). |
| USB attach/detach (IOKit matching) | 1.0 | Pending manual check | None | `IOServiceGetMatchingServices` and matching notifications register successfully. No USB devices were attached (also 0 unsandboxed), so names and events are unverified. | Pending manual check (1.0). |
| Connected Bluetooth devices (IOBluetooth) | 1.0 | Pending manual check | Bluetooth entitlement and prompt | Permission not yet requested. | Pending manual check (1.0). |
| Wi-Fi network name (CoreWLAN) | 1.0 | Blocked without Location; pending with it | Location entitlement and prompt | Without Location: interface `en0`, powered on, SSID `nil`. Not yet tested after granting. | Pending manual check (1.0). |
| In-progress calendar events (EventKit) | 1.0 | Pending manual check | Calendars entitlement and full-access prompt | Permission not yet requested. | Pending manual check (1.0). |
| Create and release `PreventSystemSleep` | 1.0 | Works | None | Rerun 12 Nov 2026 (same Mac, macOS 27.0.1). `IOPMAssertionCreateWithName("PreventSystemSleep")` returned 0; `IOPMCopyAssertionsByProcess` listed it for the probe's pid; release returned 0 and it was gone. The system-wide `PreventSystemSleep` level read 0 because the Mac was on battery, where powerd ignores this type. | Pending manual check on AC power (level 1, `pmset -g assertions`). |
| Other apps' power assertions | 1.2 | Works | None | `IOPMCopyAssertionsByProcess` lists other pids with assertion type and name (powerd, caffeinate, HID). `IOPMCopyAssertionsStatus` gives system-wide levels. | — |
| Sleep/wake history | 1.2 | Limited | — | `pmset -g log` runs but is blocked from its data: "no messages found in PM ASL data store at: /var/log/powermanagement" (unsandboxed: ~36k lines, 523 sleeps). `sysctl kern.sleeptime` and `kern.waketime` give only the last sleep and wake. | Record sleep/wake events from `NSWorkspace` in the 1.2 history database from install onward. Backfill the 7 days through the CLI (outside the sandbox), or drop backfill. |
| Managed preferences (`objectIsForced`) | 1.3 | Pending manual check | — | No profile installed: `objectIsForced = false`, as expected. | Pending manual check (1.3). |

### Pending manual checks
- **0.1:** fast user switching (needs a second user account).
- **1.0:** live camera, microphone and audio-output in-use; USB attach/detach; external display
  connect/disconnect; Bluetooth after granting; Wi-Fi SSID after granting Location; calendar
  events after granting.
- **1.0:** `PreventSystemSleep` takes effect on AC power (system level 1, `uawake … (on power)` in
  `pmset -g assertions`).
- **1.3:** managed preferences via the test profile.

## How to run the probe

1. `make probe` builds the Release probe into `build.noindex/DerivedData/Build/Products/Release/SandboxProbe.app`.
2. Headless, no prompts: `open -n <app> --args --run-all`. The app keeps running and logs changes.
   Read the results with
   `/usr/bin/log show --predicate 'subsystem == "com.underscoretec.uawake.probe"' --last 10m --style compact`
   (in zsh, call `/usr/bin/log`; plain `log` is a shell builtin).
   The app also writes `probe-results.json` to its container's Documents folder.
3. Interactive: each row's **Run** button may show permission prompts. Events (hotkey presses,
   power changes, sleep/wake, app activation, displays, USB) appear under their rows.
4. Ad-hoc builds lose permission grants on every rebuild, so finish all manual checks before rebuilding.
5. Afterwards, `open -n <app> --args --cleanup` unregisters the test launch agent. The login-item
   probe unregisters itself.

**Managed preferences:** double-click `Tools/SandboxProbe/ManagedPrefsTest.mobileconfig` and install
it in System Settings › General › Device Management. It sets `ProbeManagedKey` in the domain
`com.underscoretec.uawake.SandboxProbe`. Click **Run** on the managed-preferences row, then remove the profile.

Rerun once a Developer ID certificate is available: SMAppService and TCC behaviour can differ
from ad-hoc signing.
