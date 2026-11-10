# uawake 1.0 acceptance

Results for every acceptance criterion in `docs/SPEC.md` › Release 1.0. Part 1 of Gate C (10 Nov 2026)
records what could be verified without the maintainer; the rest is in `docs/CHECKLIST-1.0.md`, and
its results are added here (marked **Pending**) as they come in.

**Tested:** 10 Nov 2026 on macOS 27.0.1, MacBook Air (Apple M5), build 0.1.0 (1) from commit `136886f`
plus the housekeeping commit, Release configuration, ad-hoc signed without the hardened runtime.
**Re-run:** `make test`, `make lint`; live runs below used `uawake -Headless -RulesFile <file>` and
`pmset -g assertions`, polled every 2–5 s.

## Summary

| # | Criterion | Result |
| --- | --- | --- |
| 1 | Each condition type starts a session within its detection window and ends it after the linger time | **Partly verified live** (app open, app frontmost, CPU, schedule); the rest **Pending (you)**; all 12 covered by tests |
| 2 | All-match and any-match rules behave with three or more conditions | **Pass** (live and tests) |
| 3 | Active-hours windows start and stop at the right local time, including across midnight | **Pass in tests**; live schedule start/stop **Pass**; live midnight crossing **Pending (you)** |
| 4 | A guard ending a rule session holds the rule off; it restarts 5 minutes after the guard clears | **Pass in tests**; live check **Pending (you)** |
| 5 | Pause all rules works for each duration and leaves manual sessions running | **Pass in tests**; live check **Pending (you)** |
| 6 | Rules needing a permission ask only when added and warn if denied | **Pass in tests**; live prompts **Pending (you)** |
| 7 | The performance budget holds over an 8-hour soak | **Pending** (Part 3) |
| 8 | Rules persist across restarts and upgrades from 0.1 | **Pass in tests**; live relaunch and 0.1 upgrade **Pending (you)** |

## Automated checks

- `make test`: all three packages with warnings as errors (Core 101 tests, System 31, IPC 10) and the app
  tests, 0 failures. `make lint` clean.
- Coverage (`swift test --enable-code-coverage` in `Packages/UAwakeCore`): `RuleEngine.swift` 98.0% lines,
  `Rule.swift` 97.5%, `RuleStore.swift` 89.6%, `DefaultSessionEngine.swift` 99.2%, Core total 97.0%
  (target 85%).
- UI tests were not run in this part: `launch()` terminates every running uawake (see `CLAUDE.md`).

## Evidence by criterion

### 1. Each condition starts and ends
Live, with rules in an isolated rules file and the Release build running headless. Times are wall
clock; "Rule: X" is the assertion name `uawake: Rule: X` in `pmset -g assertions`.

| Condition | Action | Result |
| --- | --- | --- |
| App is open (Notes, linger 10 s) | open Notes | assertion present at the first poll (≤ 2 s) |
| | quit Notes at 08:18:22 | assertion gone between 08:18:30 and 08:18:33: **linger 10 s honoured** |
| App is in front (Calculator, linger 5 s) | open Calculator | present within 2 s |
| | bring Finder to front | gone within 7 s (5 s linger) |
| Processor is busy (> 50% for a 20 s window, linger 10 s) | 10 busy `yes` processes from 08:22:32 | started by 08:22:53 (the 20 s window has to fill) |
| | stopped at 08:23:25 | ended by 08:23:58: the window average falls, then 10 s linger |
| Schedule (08:19–08:21, linger 0) | none | started 08:19:01, ended 08:21:01 |

Notes relaunched itself a few seconds after being quit (an Apple background behaviour, seen in
`pgrep`), which the rule correctly treated as "open again" and re-matched.

Not driven live in Part 1, **Pending (you)** in the checklist: external display, USB, Bluetooth,
call (camera/microphone), audio playing, power adapter, Wi-Fi, calendar. Network busy could not be
driven either: the two download hosts tried (Cloudflare speed test answered 403, tele2 was
unreachable). Test coverage for all of these: `eventConditionsStartOnTheirSignalAndEndAfterLinger`,
`callNeedsThreeSecondsOfCameraOrMicrophoneUse`, `callCanWatchOnlyTheCamera`,
`audioNeedsFiveSecondsSoAlertSoundsDoNotCount`, `cpuUsesTheAverageOverAFullWindow`,
`networkUsesTheChosenDirection`, `staleSamplesDoNotMatch`, `calendarEventStartsAndEndsOnItsBoundaries`,
`scheduleConditionStartsOnTimeAndEndsAfterLinger`, `zeroLingerEndsAtOnce`, `lingerIsCancelledWhenConditionsReturn`,
`wakeDiscardsSamplesAndSettlesAgain`, plus the monitor parsing tests in `UAwakeSystemTests`
(`cpuPercentIsBusyShareOfTickDelta`, `byteDeltaWrapsPastUInt32Max`, `mediaUseCombinesPerDeviceFlags`,
`calendarFilterDropsAllDayDeclinedAndFree`, device ID and display name tests). The monitors'
`real…` tests read the live system once each.

### 2. All-match and any-match, three conditions
Live: "Live all3" (TextEdit **and** Calculator **and** Stickies) with two of three open: no
assertion; third opened: assertion within 3 s; one closed: ended after the 10 s linger. "Live any3"
(Notes **or** Maps **or** Stickies): started on the first one alone and, with Stickies and Notes
both involved, held until the last was gone plus linger. Tests:
`allMatchNeedsEveryOneOfThreeConditions`, `anyMatchNeedsOneOfThreeConditions`.

### 3. Active hours, midnight
`activeHoursAcrossMidnightStartAndStopOnTime`, `overnightWindowBelongsToTheDayItStartsOn`,
`equalStartAndEndIsTheWholeDay`, `windowsFollowLocalTimeAcrossADaylightSavingChange`. The live
Schedule row above is a same-day window. A real midnight crossing needs the clock to pass
midnight; that is in the soak or checklist.

### 4. Guards win over rules
`guardEndsARuleSessionAndTheRuleRearmsFiveMinutesAfterItClears`, `startRefusedByAGuardWaitsLikeAGuardEnd`,
`aWaitingRuleWhoseConditionsClearGoesBackToIdle`, `aGuardPolicyChangeIsPickedUpOnReevaluation`,
`ruleSessionsAreExemptFromTheMaximumCap`, `stoppingARuleSessionHoldsTheRuleUntilConditionsClearAndReturn`.
A real Low Power Mode or battery guard run is in the checklist (it needs the Mac on battery).

### 5. Pause
`pauseEndsRuleSessionsLeavesManualOnesAndResumesOnTime` (1 h), `untilTomorrowIsSixOClockOnTheNextCalendarDay`,
`pauseUntilResumedHoldsUntilTurnedBackOn`, `toggleAndDeactivateLeaveRuleSessionsAlone`, and in the app
`pauseIsStoredInSettingsAndRestored`, `toggleLeavesRuleSessionsRunning`.

### 6. Permissions
`permissionsAreRequestedOnlyWhenAsked`, `aDeniedPermissionKeepsOnlyThatRuleOff`,
`aRuleMissingAPermissionStaysInactiveEvenInAnyMode`. Real system prompts need a human; see the checklist.

### 7. Performance budget (8 h soak)
**Pending (Part 3).** Earlier idle result, for reference: 0.011% CPU and 13 MB footprint with no
rules (`docs/ACCEPTANCE-0.1.md`). The 10-rule soak file is `perf-10.json` (Presenting, On a call,
Building, Downloading, Music, Plugged in, Desk, Dock, Work hours, Finder open).

### 8. Persistence and upgrade
`savedRulesPersistAndRunAfterARelaunch`, `rulesSurviveASaveAndLoad`, `aMissingFileMeansNoRules` (the
0.1 upgrade: no rules file, nothing to migrate), `rulesThisBuildCannotReadAreKeptAndWrittenBack`,
`aFileFromANewerVersionIsLeftUntouched`, `aCorruptFileIsMovedAsideNotDeleted`.

## Housekeeping evidence (Launch Services)

`mdfind "kMDItemFSName == 'uawake.app'"`:

| | Copies |
| --- | --- |
| Before | 10, all under `build/` (DerivedData ×3, xcarchive, export, longrun, perf2, perf3, acceptance), plus 2 in Xcode's own DerivedData archive intermediates that Launch Services still knew |
| After `make clean-apps` | 0 |

Build output now lives in `build.noindex/`. `scripts/clean-apps.sh` (`make clean-apps`) finds copies
through `lsregister -dump` and on disk, runs `lsregister -u`, and deletes them. The UI-test and
screenshot targets unregister afterwards, `make release` deletes its archive, export and DerivedData
once the DMG and zip exist, and `acceptance.sh` removes `build.noindex/tmp` on exit.

## Results from the maintainer's checklist
**Pending.** Add each `docs/CHECKLIST-1.0.md` result here, with the date and build.
