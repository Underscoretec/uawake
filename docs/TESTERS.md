# Testing uawake 1.0 alpha

Thanks for testing. This alpha adds **rules**: uawake keeps your Mac awake by itself while
something you care about is happening. Give it a few days of normal work and tell us what
surprises you.

## Install

Alpha builds are unsigned and not notarized, so macOS blocks them the first time.

1. Download `uawake-1.0.0-alpha.2.dmg` from
   [GitHub Releases](https://github.com/Underscoretec/uawake/releases).
2. Open it and drag uawake to Applications (replace any older copy).
3. Open uawake. macOS says it can't verify the app; click **Done**.
4. Open System Settings › Privacy & Security, scroll down, click **Open Anyway** next to the
   uawake message, and confirm.

uawake lives in the menu bar. Click the icon to turn it on or off; right-click or Option-click
for the popover. If the icon is hidden behind the notch, open uawake again from Applications to
get its window.

## What to try

Rules are in the main window (popover › **Open uawake** › Rules). Each rule's assertion shows in
Terminal as `uawake: Rule: <name>` in `pmset -g assertions`.

- **Each template.** Add every template and check it starts and stops when it should:
  - *Presenting*: put Keynote or PowerPoint in front.
  - *On a call*: join a Teams or FaceTime call (camera or microphone in use).
  - *Building*: open Xcode, or keep the processor busy.
  - *Downloading*: download something large.
  - *Plugged in at the office*: plug in power while on the office Wi-Fi.
- **A Wi-Fi rule at the office.** Make a rule for the office Wi-Fi network. uawake asks for
  Location only when you press the button (macOS needs it to read Wi-Fi names). Leave the office
  and check the rule stops.
- **A call rule.** Join a real call; the session should start within a few seconds and end a
  little after you hang up.
- **A download rule.** Start a large download with the editor's **Test** tab open: the network
  condition should turn to **Met**, and back after the download ends.
- **Pause.** Pause Rules for an hour, until tomorrow and until resumed. Manual sessions must keep
  running while rules are paused.
- **Guards.** On battery, turn on Low Power Mode or let the battery fall below the limit: rule
  and manual sessions should stop with a red banner. A rule stays off until five minutes after
  the guard clears.
- Everyday use: sleep and wake, closing the lid, switching users, a second display.

## Reporting a problem

Open a [GitHub issue](https://github.com/Underscoretec/uawake/issues/new/choose), or post in our
Teams channel. Please include:

- what you did, what you expected and what happened;
- the uawake version (main window › About) and your macOS version (Apple menu › About This Mac);
- the output of `pmset -g assertions` in Terminal, taken while the problem is happening;
- for a rule, a screenshot of the rule in the editor.

Don't paste anything private from `pmset` output you'd rather not share (it lists other apps'
names); trim it to the `uawake` lines if you prefer.
