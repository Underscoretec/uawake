# uawake 1.0 checklist for the maintainer

Everything here needs a person, hardware or a real permission prompt. Do the groups in any order,
by what you have at hand. Reply with the **Report** line of each step you ran (pass / fail, plus the
output asked for). Anything not run, say "skipped". Results go into `docs/ACCEPTANCE-1.0.md`.

## 0. Start the build to test

Built in Part 1: Release, ad-hoc signed, version 0.1.0 (1), commit-for-commit the Gate B code.

```sh
cd ~/working/projects/uawake
open build.noindex/DerivedData/Build/Products/Release/uawake.app
```

- If a menu bar uawake already runs, quit it first (popover › Quit). Check one copy only:
  `pgrep -lx uawake` prints one line; `mdfind "kMDItemFSName == 'uawake.app'"` prints nothing
  (build.noindex is not indexed).
- It uses your real settings and `rules.json`, so rules you create are real. Delete test rules
  afterwards (Settings… › Rules › the rule › Delete Rule…).
- Reset the permission prompts to see them again (macOS 27's `tccutil` has no `All`; reset per service):
  `tccutil reset Calendar com.underscoretec.uawake`, `tccutil reset BluetoothAlways com.underscoretec.uawake`, `tccutil reset Camera com.underscoretec.uawake` and `tccutil reset Microphone com.underscoretec.uawake`; Location via System Settings › Privacy & Security › Location Services. Then relaunch.
- Handy watchers (Terminal): `pmset -g assertions | grep uawake` shows what is held;
  `/usr/bin/log show --predicate 'subsystem == "com.underscoretec.uawake"' --last 10m --info`
  shows the app's own log.
- When all done: quit uawake, run `make clean-apps`.

Open the rules screen: menu bar icon (secondary click or the popover's **Settings…**) › **Rules**.
A rule's status pill reads **Matching now** while its conditions hold and **Ends in …** while lingering.
Each editor has an **Edit | Test** switch; **Test** shows every condition's current value.

## 1. External display

Create the rule: Rules › **New Rule** › Name `Display test` › **Add Condition** › *External display
connected* (Any display) › set linger to the shortest value › **Save**.
1. Plug in the display. Expect status **Matching now** and `uawake: Rule: Display test` within about 2 s.
2. Test tab: *External display connected* shows **Met**.
3. Edit the rule, choose the display by name in the **Display** picker, Save. Unplug, plug in: still matches.
4. Unplug. Expect the session to end after the linger time.

Report: pass/fail for 1 and 4, and the time between unplugging and the assertion disappearing.

## 2. USB device

Rule `USB test`: *USB or Bluetooth device connected* › Connection **USB** › **Choose a Device** (pick your
device) › Save.
1. Plug the device in (unplug first if already connected). Expect a match within about 2 s.
2. Unplug. Expect the end after linger.

Report: pass/fail; the device name as the picker shows it.

## 3. Bluetooth device

Rule `BT test`: same condition, Connection **Bluetooth**.
1. Before choosing a device, expect a **Grant Access** row (or similar) for Bluetooth. Confirm no
   Bluetooth prompt appeared when you only opened the Rules section or the editor.
2. Click **Grant Access**: the macOS prompt appears. Allow. The device list fills in.
3. Pick the headset or other device, Save. Connect it (or turn it on). Expect a match.
   Disconnect: ends after linger.
4. Denied case: `tccutil reset BluetoothAlways com.underscoretec.uawake`, relaunch, add the rule again,
   click **Grant Access** and choose **Don't Allow**. Expect the rule shows **Needs Bluetooth** and
   an **Open System Settings** button, and never starts a session.

Report: pass/fail for 1–4; whether any Bluetooth prompt appeared unprompted.

## 4. Camera, microphone, audio

*Call in progress* rule `Call test` (camera and microphone ticked).
1. Open Photo Booth or FaceTime (camera on) or Voice Memos (microphone). Expect a match about 3 s after
   the device goes live (the engine needs 3 s of use), a session named `uawake: Rule: Call test`.
2. Quit it. Ends after linger.
3. Edit the rule to watch only the camera; start Voice Memos: expect **no** match. Then Photo Booth: match.
4. No camera/microphone permission prompt should appear for uawake at any point.

*Audio is playing* rule `Audio test`:
5. Play music in Music or a browser. Expect a match about 5 s after the sound starts.
6. Trigger a short alert sound (e.g. `afplay /System/Library/Sounds/Ping.aiff`) with nothing else playing:
   expect **no** match (alert sounds are shorter than 5 s).
7. Pause the music. Ends after linger.

Report: pass/fail for each of 1–7; any prompt that appeared.

## 5. Wi-Fi with Location, and the office network rule (at the office)

1. Connect to the office Wi-Fi. Create the rule: Rules › **New Rule** › Name `Office network` ›
   **Add Condition** › *On a Wi-Fi network*.
2. Confirm no Location prompt has appeared yet. Click **Grant Access**; allow the macOS prompt.
3. A **Use “<your network>”** button appears: click it so the name is filled in. Save.
4. Test tab: *On a Wi-Fi network* shows **Met**; the list row shows **Matching now**; `pmset -g assertions | grep uawake`
   shows `uawake: Rule: Office network`.
5. Combine with power: add *Power adapter connected*, set **All of these are true** (or use the
   **Plugged in at the office** template if the Rules list offers one, then pick the network). Unplug
   the charger: the rule ends after linger; plug in: it matches again.
6. Turn Wi-Fi off (or join a phone hotspot): the rule ends after linger. Back on the office network: matches again.
7. Denied case: reset Location in System Settings › Privacy & Security › Location Services (`tccutil` can't), relaunch, add a Wi-Fi rule, click
   **Grant Access** › **Don't Allow**. Expect **Needs Location** and no session.

Report: pass/fail for 2–7; whether the network name was filled correctly (macOS 26 and later can hide
Wi-Fi names without Location; say if you saw an empty or placeholder name).

## 6. Calendar

Rule `Meeting`: *Calendar event in progress* (Any calendar, no keyword).
1. Confirm no Calendar prompt appeared before you clicked **Grant Access**. Grant it.
2. In Calendar create an event that started 1 minute ago and ends in 10 minutes (title `uawake test`).
   Expect a match within a few seconds of the event window being current.
3. Edit the rule, set a keyword that is **not** in the title (e.g. `zzz`): no match. Set `uawake`: match.
4. Mark the event **Free** (Show As: Free): no match. Back to Busy: match. Create an **all-day** event: no match for it.
5. Delete the event. Ends after linger.
6. Denied case: `tccutil reset Calendar com.underscoretec.uawake`, relaunch, add the rule, **Grant Access**
   › **Don't Allow**. Expect **Needs Calendar**, no session.

Report: pass/fail for 2–6.

## 7. Network and power adapter (needs you; no special hardware)

*Network is busy* rule `Download test` (Download, 1 MB/s, window 20 s):
1. Start a big download (e.g. a macOS installer or `curl -o /dev/null <large file URL>`) at over 1 MB/s.
   Expect a match about 20 s in. Stop it. Ends after the window falls plus linger.

*Power adapter connected* rule `Power test`:
2. Unplug: ends after linger (and the popover shows the rule as not matching). Plug in: matches.

Report: pass/fail for each; the download speed you saw.

## 8. Permission prompts, one more pass

After resetting every service (see section 0) and relaunching, open every part of the Rules UI
(list, editor, Test tab, templates, pickers) without clicking any **Grant Access**.
Report: whether **any** macOS permission prompt (Bluetooth, Location, Calendar, camera, microphone,
files) appeared. Expected: none; each appears only after its own button.

## 9. "Other…" app picker

1. New Rule › **Add Condition** › *App is open* › the app picker › **Other…**.
2. A file dialog opens, limited to apps. Choose an app in `/Applications` (e.g. Safari) or one outside
   it, such as one on your Desktop.
3. The picker now shows that app by name; Save. Open the app: matches. Quit: ends after linger.
4. Quit uawake and relaunch: the rule still names the app.

Report: pass/fail for 2–4; whether the app's name (not its bundle ID) appeared.

## 10. Rules persist, upgrade from 0.1

1. Make two or three rules, one disabled, with different match modes and linger times. Quit uawake and relaunch.
   Expect them all back, in the same order, with the same switches and settings.
2. Upgrade from 0.1: install the 0.1.0 build you tested earlier in `/Applications` (or skip: there is
   nothing to migrate because 0.1 had no rules file) and run this build over its settings. Expect your
   0.1 settings (presets, guards, shortcut) intact and an empty Rules list with the templates.

Report: pass/fail for 1; for 2, say whether you did it.

## 11. Pause, guards live (battery needed)

1. Create a rule that matches right now (e.g. *Schedule* every day, all day). Start a manual 15 min session too.
2. Popover › Rules strip › **Pause** › **1 hour**: the rule's session ends, the manual session stays.
   Strip shows **Paused**. **Resume**: rule restarts. Repeat with **Until tomorrow, 6:00** (label should
   say 6:00) and **Until turned back on**; relaunch the app under the last one: it should stay paused.
3. Guard hold: with the rule matching, turn on **Low Power Mode** (System Settings › Battery). Expect the
   rule's session to end, a "Low Power Mode" notification, and the rule showing **Waiting: Low Power Mode is on**.
   Turn Low Power Mode off: the rule shows **Waiting: restarts in …** counting down from 5 minutes and
   restarts at 0 (time it, report the real gap).
4. Battery guard: `defaults write com.underscoretec.uawake BatteryGuardThreshold -int 95`, relaunch, unplug
   with the battery at 95% or less: expect the rule's session to end with a "Battery guard" notification
   and **Waiting: battery low**. Plug in; the 5 minutes starts. Afterwards
   `defaults delete com.underscoretec.uawake BatteryGuardThreshold`.
5. Stopping a rule session by hand: click **Stop** on a rule's session. Expect **Stopped by you** and no
   restart while its condition remains true. Make the condition false for the full linger time, then true
   again: it restarts.

Report: pass/fail for 2–5, the gap you measured in 3.

## 12. VoiceOver and keyboard

With VoiceOver on (Cmd+F5) and then with VoiceOver off, keyboard only (turn on System Settings ›
Keyboard › Keyboard navigation):
1. Rules list: each row announces its name, status (e.g. "Matching now") and switch state; **New Rule**, **Pause Rules**
   and **Resume** are reachable and announced.
2. Editor: Tab reaches every control; the app picker, device picker, threshold sliders and day buttons
   announce a label and value ("Processor threshold", "App, Safari"); Add and Remove Condition announce which condition.
3. Test tab: each condition reads as its value plus **Met / Not met / Needs access**, not colour alone.
4. Popover: Rules strip and rule rows readable; **Pause** menu opens with the keyboard.
5. Escape closes the editor and popover; **Save** disabled with a spoken reason until the rule is valid.

Report: pass/fail per item; any control with no label, an unhelpful label or a focus trap.

## 13. Carried from 0.1

**Fast user switching (0.1 criterion 6)**
1. System Settings › Users & Groups › Add User: a temporary Standard account.
2. Control Centre settings: show Fast User Switching in the menu bar.
3. In your account open uawake, click **15 min**, note the time left (e.g. 14:41).
4. Within a few seconds, switch to the temporary account. Stay there 2 minutes.
5. In the temporary account's Terminal: `pmset -g assertions | grep uawake` should print nothing.
6. Switch back. Within 5 s open the popover: the time left should be within 1–2 s of step 3 (not 2 minutes
   less); `pmset -g assertions | grep uawake` shows it again.
7. Evidence: `/usr/bin/log show --predicate 'subsystem == "com.underscoretec.uawake"' --last 10m --info | grep -E 'Paused|Resumed'`.
8. Delete the temporary account.

Also try with a matching rule: it should pause and resume with the user switch too.

**Live guard notifications (0.1 criterion 5)**: covered by step 11.3 and 11.4. Allow notifications for
uawake first (first-run window or System Settings › Notifications).

Report: pass/fail; the two time-left readings and the log lines.

## What to send back

One message: for each numbered group, either "pass", "skipped" or "fail: what happened", with the
output each step asks for. For a fail, add what the Test tab showed at the time and, if you can,
the output of `/usr/bin/log show --predicate 'subsystem == "com.underscoretec.uawake"' --last 5m --info`.
