import Foundation
import Testing
import UAwakeCore
import UAwakeCoreTesting

@testable import uawake

@MainActor
struct PopoverViewModelTests {
    let clock = FakeClock()
    let assertions = FakeAssertionProvider()
    let defaults: UserDefaults
    let settings: UAwakeSettings
    let engine: DefaultSessionEngine
    let model: PopoverViewModel

    init() {
        defaults = UserDefaults(suiteName: "uawake-app-tests-\(UUID().uuidString)")!
        settings = UAwakeSettings(defaults: defaults)
        engine = DefaultSessionEngine(
            assertions: assertions, clock: clock, guards: DefaultSessionEngine.standardGuards, policy: settings.policy)
        model = PopoverViewModel(engine: engine, settings: settings, now: clock.now)
    }

    // MARK: Popover state

    @Test func toggleUsesThePrimaryClickPreset() throws {
        settings.primaryClickAction = .duration(.seconds(3600))
        #expect(!model.isOn && !model.isAwake)
        model.toggle()
        #expect(model.isOn && model.isAwake)
        let session = try #require(engine.sessions.first)
        #expect(session.source == .manual)
        #expect(session.endCondition == .duration(.seconds(3600)))
        model.toggle()
        #expect(engine.sessions.isEmpty)
    }

    @Test func otherSourcesKeepTheMacAwakeButDoNotCountAsOn() throws {
        try engine.start(SessionRequest(source: .rule, reason: .rule(name: "Call"), endCondition: .indefinite))
        #expect(!model.isOn)
        #expect(model.isAwake)
    }

    @Test func presetReplacesManualSessionsOnly() throws {
        try engine.start(SessionRequest(source: .cli, reason: .custom("build"), endCondition: .indefinite))
        model.start(.indefinite)
        model.start(.duration(.seconds(900)))
        #expect(engine.sessions.map(\.source) == [.cli, .manual])
        #expect(engine.sessions.last?.endCondition == .duration(.seconds(900)))
    }

    @Test func untilPickerStartsAnUntilSession() throws {
        model.untilTime = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: clock.now)!
        model.startUntil()
        #expect(engine.sessions.first?.endCondition == .until(ClockTime(hour: 18, minute: 30)!))
    }

    @Test func rowsShowReasonsAndStop() throws {
        model.start(.duration(.seconds(7200)))
        let row = try #require(model.rows.first)
        #expect(row.title == "2 hours")
        let time = clock.now.formatted(date: .omitted, time: .shortened)
        #expect(row.subtitle == "Started manually at \(time)")
        #expect(model.remaining(row, now: clock.now) == "2:00:00")
        model.stop(row.id)
        #expect(model.rows.isEmpty)
    }

    @Test func defaultUntilTimeIsAboutAnHourAheadOnAFiveMinuteBoundary() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let until = PopoverViewModel.defaultUntilTime(from: now)
        #expect(until.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 300) == 0)
        #expect(until.timeIntervalSince(now) >= 3600 && until.timeIntervalSince(now) < 3900)
    }

    // MARK: Extend visibility

    @Test func extendIsOfferedOnlyForSessionsWithADeadline() throws {
        model.start(.duration(.seconds(600)))
        try engine.start(SessionRequest(source: .url, reason: .custom("i"), endCondition: .indefinite))
        try engine.start(SessionRequest(source: .url, reason: .custom("b"), endCondition: .batteryLevel(30)))
        try engine.start(
            SessionRequest(source: .url, reason: .custom("u"), endCondition: .until(ClockTime(hour: 9, minute: 0)!)))
        #expect(model.rows.map(\.canExtend) == [true, false, false, true])
        #expect(model.rows[1].deadline == nil)  // The cap is not shown as a countdown.
        let id = model.rows[0].id
        model.extend(id, by: .seconds(900))
        #expect(model.remaining(model.rows[0], now: clock.now) == "25:00")
    }

    // MARK: Refusal message

    @Test func refusalExplainsTheGuardAndPointsToSafety() {
        engine.apply(.test(lowPowerMode: true))
        model.toggle()
        #expect(model.refusal == Refusal(message: "Low Power Mode is on.", section: .safety))
        #expect(engine.sessions.isEmpty)
        var opened: MainSection??
        model.openMainWindow = { opened = $0 }
        model.openRefusalSettings()
        #expect(opened == .safety)
        model.clearRefusal()
        #expect(model.refusal == nil)
    }

    @Test func refusalShowsThePopover() {
        var shown = false
        model.showPopover = { shown = true }
        engine.apply(.test(thermal: .critical))
        model.toggle()
        #expect(shown)
        #expect(model.refusal?.message == "Your Mac is too warm to keep awake right now.")
    }

    @Test func refusedPresetKeepsTheRunningSession() throws {
        model.start(.indefinite)
        engine.apply(.test(battery: 25, source: .battery))  // Above the 20% guard.
        model.start(.batteryLevel(30))
        #expect(model.refusal == Refusal(message: "The battery is already at or below that level.", section: nil))
        #expect(engine.sessions.map(\.endCondition) == [.indefinite])
    }

    @Test func refusalMessages() {
        settings.batteryGuardThreshold = 30
        let battery = PopoverViewModel.refusal(for: .wouldEndImmediately(.batteryGuard), settings: settings)
        #expect(battery == Refusal(message: "The battery is at or below the 30% safety limit.", section: .safety))
        #expect(PopoverViewModel.refusal(for: .assertionFailed(code: -1), settings: settings).section == nil)
        #expect(
            PopoverViewModel.refusal(for: .notExtendable, settings: settings).message
                == "That session can't be changed.")
        #expect(
            PopoverViewModel.refusal(for: .wouldEndImmediately(.maximumCap), settings: settings).message
                == "That session would end straight away.")
    }

    @Test func successClearsAPreviousRefusal() {
        engine.apply(.test(lowPowerMode: true))
        model.toggle()
        engine.apply(.test())
        model.toggle()
        #expect(model.refusal == nil)
        #expect(model.isOn)
    }

    // MARK: Countdown formatting

    @Test func countdownText() {
        #expect(PopoverViewModel.countdownText(102) == "1:42")
        #expect(PopoverViewModel.countdownText(101.2) == "1:42")  // Rounds up.
        #expect(PopoverViewModel.countdownText(3599) == "59:59")
        #expect(PopoverViewModel.countdownText(3600) == "1:00:00")
        #expect(PopoverViewModel.countdownText(6120) == "1:42:00")
        #expect(PopoverViewModel.countdownText(0) == "0:00")
        #expect(PopoverViewModel.countdownText(-5) == "0:00")
    }

    @Test func menuBarTextIsMinutesUntilTheFinalMinute() {
        #expect(PopoverViewModel.menuBarText(6120) == "1:42")
        #expect(PopoverViewModel.menuBarText(6061) == "1:42")  // 1:41:01 rounds up.
        #expect(PopoverViewModel.menuBarText(3600) == "1:00")
        #expect(PopoverViewModel.menuBarText(3599) == "1:00")  // Rounds up: never "60m".
        #expect(PopoverViewModel.menuBarText(3540) == "59m")
        #expect(PopoverViewModel.menuBarText(2520) == "42m")
        #expect(PopoverViewModel.menuBarText(61) == "2m")
        #expect(PopoverViewModel.menuBarText(60) == "1:00")
        #expect(PopoverViewModel.menuBarText(42.3) == "0:43")
        #expect(PopoverViewModel.menuBarText(0) == "0:00")
    }

    @Test func menuBarRedrawsOnlyWhenTheTextChanges() {
        #expect(PopoverViewModel.secondsUntilMenuBarChange(6120) == 60)
        #expect(PopoverViewModel.secondsUntilMenuBarChange(6090) == 30)
        #expect(PopoverViewModel.secondsUntilMenuBarChange(90) == 30)  // "2m" until 60 s, then "1:00".
        #expect(PopoverViewModel.secondsUntilMenuBarChange(42.3) == 42.3 - 42)
        #expect(PopoverViewModel.secondsUntilMenuBarChange(42) == 1)
        // Every redraw lands where the text actually changes.
        for remaining in stride(from: 7200.0, to: 0.5, by: -13.7) {
            let next = remaining - PopoverViewModel.secondsUntilMenuBarChange(remaining)
            #expect(PopoverViewModel.menuBarText(next - 0.01) != PopoverViewModel.menuBarText(remaining))
        }
    }

    @Test func countdownShowsTheLatestDeadlineOnlyWhenEverySessionHasOne() throws {
        #expect(model.countdown(now: clock.now) == nil)
        model.start(.duration(.seconds(600)))
        try engine.start(SessionRequest(source: .url, reason: .custom("x"), endCondition: .duration(.seconds(1200))))
        #expect(model.countdown(now: clock.now) == "20:00")
        #expect(model.countdown(now: clock.now + 300) == "15:00")
        try engine.start(SessionRequest(source: .url, reason: .custom("y"), endCondition: .indefinite))
        #expect(model.countdown(now: clock.now) == nil)
    }

    @Test func statusAccessibilityLabel() {
        #expect(model.statusAccessibilityLabel(now: clock.now) == "uawake: off")
        model.start(.duration(.seconds(90)))
        #expect(model.statusAccessibilityLabel(now: clock.now) == "uawake: keeping your Mac awake, 2m left")
        model.start(.indefinite)
        #expect(model.statusAccessibilityLabel(now: clock.now) == "uawake: keeping your Mac awake")
    }

    // MARK: Hero

    @Test func heroIdleTimedAndIndefinite() throws {
        #expect(model.hero(now: clock.now).kind == .idle)
        model.start(.duration(.seconds(3600)))
        var hero = model.hero(now: clock.now + 900)
        #expect(hero.kind == .timed)
        #expect(hero.countdown == "45:00")
        #expect(hero.caption.hasPrefix("until "))
        #expect(hero.progress == 0.25)
        #expect(!hero.isEndingSoon)
        hero = model.hero(now: clock.now + 3400)
        #expect(hero.isEndingSoon)  // Within the 5-minute warning.
        try engine.start(SessionRequest(source: .url, reason: .custom("x"), endCondition: .indefinite))
        hero = model.hero(now: clock.now + 8040)
        let since = PopoverViewModel.sinceText(clock.now)
        #expect(
            hero
                == Hero(
                    kind: .indefinite, countdown: "2:14", caption: "\(since) · Indefinite", progress: nil,
                    isEndingSoon: false, keepsScreenOn: true))
    }

    @Test func elapsedTextIsHoursAndMinutesRoundedDown() {
        #expect(PopoverViewModel.elapsedText(0) == "0:00")
        #expect(PopoverViewModel.elapsedText(299) == "0:04")
        #expect(PopoverViewModel.elapsedText(8099) == "2:14")
        #expect(PopoverViewModel.elapsedText(26 * 3600 + 180) == "26:03")
    }

    @Test func heroAwakeTimeExcludesPausedTime() throws {
        model.start(.indefinite)
        clock.advance(by: 3600)
        engine.handle(.userSessionDidResignActive)
        clock.advance(by: 1800)
        engine.handle(.userSessionDidBecomeActive)
        clock.advance(by: 600)
        #expect(model.hero(now: clock.now).countdown == "1:10")
    }

    @Test func sessionsKeepTheScreenOnUnlessTheSettingAllowsSleep() {
        model.start(.indefinite)
        #expect(engine.sessions[0].modes == [.system, .display])
        #expect(model.hero(now: clock.now).keepsScreenOn)
        settings.allowDisplaySleep = true
        model.start(.indefinite)
        #expect(engine.sessions[0].modes == [.system])
        #expect(!model.hero(now: clock.now).keepsScreenOn)
    }

    @Test func rowsWithoutADeadlineShowWhenTheyStarted() throws {
        try engine.start(SessionRequest(source: .url, reason: .custom("i"), endCondition: .indefinite))
        try engine.start(SessionRequest(source: .url, reason: .custom("b"), endCondition: .batteryLevel(20)))
        let since = PopoverViewModel.sinceText(clock.now)
        #expect(model.remaining(model.rows[0], now: clock.now) == since)
        #expect(model.remaining(model.rows[1], now: clock.now) == "until 20% battery · \(since)")
    }

    @Test func onPowerChipShowsWhileTheAssertionIsHeld() {
        engine.preventsSleepOnPower = true
        engine.apply(.test(source: .ac))
        #expect(!model.statusChips.contains { $0.id == "onPower" })
        model.start(.indefinite)
        #expect(model.statusChips.contains { $0.id == "onPower" && $0.text == "No sleep on power" })
        engine.apply(.test(source: .battery))
        #expect(!model.statusChips.contains { $0.id == "onPower" })
    }

    @Test func heroCountsDownToTheLastTimedSession() throws {
        model.start(.duration(.seconds(600)))
        try engine.start(SessionRequest(source: .url, reason: .custom("y"), endCondition: .duration(.seconds(1800))))
        let hero = model.hero(now: clock.now)
        #expect(hero.countdown == "30:00")
        #expect(hero.progress == 0)
    }

    // MARK: Banners

    @Test func refusalAndGuardBanners() throws {
        engine.apply(.test(lowPowerMode: true))
        model.toggle()
        #expect(model.banners.map(\.kind) == [.refusal])
        #expect(model.banners.first?.tone == .caution)
        #expect(model.banners.first?.section == .safety)

        engine.apply(.test())
        model.toggle()  // Succeeds: clears the refusal.
        let session = try #require(engine.sessions.first)
        var ended = session
        ended.state = .ended(.lowPowerMode)
        model.handle(.ended(ended), now: clock.now + 60)
        let banner = try #require(model.banners.first)
        #expect(banner.kind == .guardStop(session.id))
        #expect(banner.tone == .critical)
        #expect(banner.title == "Stopped by Low Power Mode")
        var opened: MainSection??
        model.openMainWindow = { opened = $0 }
        model.open(banner)
        #expect(opened == .safety)
        model.dismiss(banner)
        #expect(model.banners.isEmpty)
    }

    @Test func expiryAndUserStopsMakeNoBanner() throws {
        model.start(.indefinite)
        var ended = try #require(engine.sessions.first)
        ended.state = .ended(.stoppedByUser)
        model.handle(.ended(ended))
        #expect(model.banners.isEmpty)
    }

    // MARK: Kept awake today

    @Test func keptAwakeTodayMergesOverlapsAndClipsToToday() throws {
        let calendar = Calendar(identifier: .gregorian)
        let midnight = calendar.startOfDay(for: clock.now) + 86_400
        let now = midnight + 3600  // 01:00 the next day.
        // 23:00–00:30 overlapping 00:00–00:45; only 00:00–00:45 is today.
        func ended(from start: Date, to end: Date) throws {
            var session = Session(
                source: .manual, reason: .custom("s"), modes: [.system], endCondition: .indefinite, startedAt: start,
                deadline: nil)
            session.state = .ended(.stoppedByUser)
            model.handle(.ended(session), now: end)
        }
        try ended(from: midnight - 3600, to: midnight + 1800)
        try ended(from: midnight, to: midnight + 2700)
        #expect(model.keptAwakeToday(now: now, calendar: calendar) == .seconds(2700))
        #expect(PopoverViewModel.keptAwakeText(.seconds(12_000)) == "3h 20m")
        #expect(PopoverViewModel.keptAwakeText(.seconds(0)) == "0m")
    }

    @Test func keptAwakeTodayExcludesPausedTime() throws {
        model.start(.indefinite)
        let session = try #require(engine.sessions.first)
        model.handle(.started(session), now: clock.now)
        var paused = session
        paused.state = .paused(remaining: nil)
        model.handle(.paused(paused), now: clock.now + 600)  // 10 min awake.
        model.handle(.resumed(session), now: clock.now + 1800)  // 20 min paused.
        var ended = session
        ended.state = .ended(.stoppedByUser)
        model.handle(.ended(ended), now: clock.now + 2400)  // 10 more min awake.
        #expect(model.keptAwakeToday(now: clock.now + 3000) == .seconds(1200))
    }

    @Test func titlesAndSubtitles() throws {
        try engine.start(SessionRequest(source: .url, reason: .custom("Render"), endCondition: .indefinite))
        try engine.start(
            SessionRequest(
                source: .url, reason: .standard(.url, .until(ClockTime(hour: 18, minute: 30)!)),
                endCondition: .until(ClockTime(hour: 18, minute: 30)!)))
        #expect(model.rows[0].title == "Render")
        #expect(model.rows[0].subtitle.hasPrefix("Started from a link at "))
        #expect(model.rows[1].title.hasPrefix("Until "))
        #expect(EndCondition.indefinite.sessionTitle == "Indefinite")
        #expect(EndCondition.batteryLevel(20).sessionTitle == "Until battery 20%")
    }

    @Test func singleSessionMovesIntoTheHero() throws {
        #expect(!model.showsSessionList)
        model.start(.duration(.seconds(3600)))
        #expect(model.singleRow?.title == "1 hour")
        #expect(!model.showsSessionList)
        try engine.start(SessionRequest(source: .url, reason: .custom("x"), endCondition: .indefinite))
        #expect(model.singleRow == nil)
        #expect(model.showsSessionList)
    }

    @Test func singlePausedSessionStaysListed() throws {
        model.start(.duration(.seconds(3600)))
        engine.handle(.userSessionDidResignActive)
        #expect(model.showsSessionList)
    }

    @Test func selectedPresetFollowsTheManualSession() throws {
        #expect(model.currentManualCondition == nil)
        model.start(.duration(.seconds(1800)))
        #expect(model.currentManualCondition == .duration(.seconds(1800)))
        try engine.start(SessionRequest(source: .url, reason: .custom("x"), endCondition: .indefinite))
        #expect(model.currentManualCondition == .duration(.seconds(1800)))  // URL sessions don't count.
    }

    @Test func keptAwakeTodayIncludesActiveSessions() {
        model.start(.indefinite)
        #expect(model.keptAwakeToday(now: clock.now + 600) == .seconds(600))
    }

    // MARK: Status strip

    @Test func statusChips() {
        #expect(model.statusChips.isEmpty)
        engine.apply(.test(battery: 76, source: .battery))
        #expect(model.statusChips.map(\.id) == ["battery", "power", "guards"])
        #expect(model.statusChips.map(\.tone) == [.neutral, .neutral, .good])
        #expect(model.statusChips[0].text == "76%")
        engine.apply(.test(battery: 28, source: .battery))  // Within 10 points of the 20% guard.
        #expect(model.statusChips[0].tone == .caution)
        #expect(model.statusChips[2].tone == .caution)
        engine.apply(.test(battery: 90, source: .ac, lowPowerMode: true))
        #expect(model.statusChips.map(\.tone) == [.neutral, .neutral, .critical])
        #expect(model.statusChips[0].symbol == "battery.100percent.bolt")
        settings.batteryGuardEnabled = false
        settings.lowPowerModeGuardEnabled = false
        settings.thermalGuardEnabled = false
        #expect(model.statusChips.last?.text == "Guards off")
        engine.apply(.test(battery: nil, source: .ac))
        #expect(model.statusChips.map(\.id) == ["power", "guards"])
    }

    // MARK: Other localized text

    @Test func chipTitlesAndShortcutDisplay() {
        #expect(EndCondition.indefinite.chipTitle == "Indefinite")
        #expect(EndCondition.duration(.seconds(900)).chipTitle == "15 min")
        #expect(GlobalShortcut(keyCode: 49, carbonModifiers: 0x1900).displayString == "⌃⌥⌘Space")
        #expect(StatusItemController.symbols(.cup) == ("cup.and.saucer.fill", "cup.and.saucer"))
        for active in [true, false] {
            #expect(StatusItemController.symbolImage(style: .uawake, active: active).size.height == 18)
        }
    }
}
