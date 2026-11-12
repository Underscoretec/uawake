import Foundation
import Testing
import UAwakeCoreTesting

@testable import UAwakeCore

@MainActor
struct RuleEngineTests {
    /// Monday 1 January 2001, 10:00 UTC.
    static let start = Date(timeIntervalSinceReferenceDate: 10 * 3600)
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
    static let ac = DeviceState(
        batteryLevel: 80, powerSource: .ac, isLowPowerModeEnabled: false, thermalState: .nominal)
    static let lowBattery = DeviceState(
        batteryLevel: 10, powerSource: .battery, isLowPowerModeEnabled: false, thermalState: .nominal)
    static let xcode = AppRef(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    static let keynote = AppRef(bundleID: "com.apple.iWork.Keynote", name: "Keynote")

    let clock = FakeClock(now: RuleEngineTests.start)
    let assertions = FakeAssertionProvider()
    let engine: DefaultSessionEngine

    init() {
        engine = DefaultSessionEngine(assertions: assertions, clock: clock, guards: DefaultSessionEngine.standardGuards)
    }

    /// A rule engine wired to the session engine's events, as the app does.
    func makeRules(_ rules: [Rule], pause: RulePause? = nil) -> RuleEngine {
        let ruleEngine = RuleEngine(engine: engine, clock: clock, calendar: Self.utc, rules: rules, pause: pause)
        let events = engine.events()
        Task { for await event in events { ruleEngine.handle(event) } }
        return ruleEngine
    }

    func rule(
        _ name: String, _ conditions: [Condition], match: MatchMode = .all, linger: Int = 120,
        hours: WeeklyWindow? = nil
    ) -> Rule {
        Rule(name: name, match: match, conditions: conditions, lingerSeconds: linger, activeHours: hours)
    }

    func rule(_ conditions: [Condition], match: MatchMode = .all, linger: Int = 120, hours: WeeklyWindow? = nil) -> Rule
    {
        rule("Test", conditions, match: match, linger: linger, hours: hours)
    }

    /// Lets forwarded session events reach the rule engine.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Advances the fake clock and waits for whichever timers are now due.
    func advance(_ rules: RuleEngine, by seconds: TimeInterval) async {
        let timers = [(engine.timerTask, engine.nextWake), (rules.timerTask, rules.nextWake)]
        clock.advance(by: seconds)
        for (timer, wake) in timers {
            if let wake, wake <= clock.now { await timer?.value }
        }
        await settle()
    }

    func apps(_ running: [AppRef], frontmost: AppRef? = nil) -> Signal {
        .apps(AppsState(running: Set(running.map(\.bundleID)), frontmost: frontmost?.bundleID))
    }

    /// Feeds one 10 s load sample per step.
    func feed(_ rules: RuleEngine, samples: Int, cpu: Double = 0, bytesIn: Double = 0, bytesOut: Double = 0) async {
        for _ in 0..<samples {
            await advance(rules, by: 10)
            rules.update(
                .load(LoadSample(cpuPercent: cpu, bytesInPerSecond: bytesIn, bytesOutPerSecond: bytesOut, interval: 10))
            )
        }
    }

    var names: Set<String> { Set(assertions.live.values) }

    // MARK: Start, linger, end

    @Test func ruleHoldsOneNamedSessionWhileMatchingAndEndsAfterLinger() async {
        let building = rule("Building", [.appRunning(Self.xcode)])
        let rules = makeRules([building])
        #expect(rules.statuses[building.id] == .idle)
        #expect(engine.sessions.isEmpty)

        rules.update(apps([Self.xcode]))
        #expect(rules.statuses[building.id] == .matching)
        #expect(engine.sessions.map(\.source) == [.rule])
        #expect(engine.sessions.first?.reason == .rule(name: "Building"))
        #expect(names == ["uawake: Rule: Building"])
        rules.update(apps([Self.xcode, Self.keynote]))
        #expect(engine.sessions.count == 1)

        rules.update(apps([]))
        #expect(rules.statuses[building.id] == .lingering(until: clock.now + 120))
        await advance(rules, by: 119)
        #expect(engine.sessions.count == 1)
        await advance(rules, by: 1)
        #expect(engine.sessions.isEmpty)
        #expect(assertions.live.isEmpty)
        #expect(rules.statuses[building.id] == .idle)
    }

    @Test func lingerIsCancelledWhenConditionsReturn() async {
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        let session = engine.sessions.first?.id
        rules.update(apps([]))
        await advance(rules, by: 100)
        rules.update(apps([Self.xcode]))
        #expect(rules.statuses[building.id] == .matching)
        await advance(rules, by: 600)
        #expect(engine.sessions.map(\.id) == [session])
    }

    @Test func rulesUseTheirOwnModesAndEachHoldsItsOwnSession() {
        var presenting = rule("Presenting", [.appFrontmost(Self.keynote)])
        presenting.modes = [.system, .display]
        let rules = makeRules([presenting, rule("Building", [.appRunning(Self.xcode)])])
        rules.update(apps([Self.xcode, Self.keynote], frontmost: Self.keynote))
        #expect(engine.sessions.count == 2)
        #expect(names == ["uawake: Rule: Presenting", "uawake: Rule: Building"])
        #expect(assertions.live.count == 3)
        #expect(rules.rule(forSession: engine.sessions[0].id)?.name == "Presenting")
    }

    @Test func ruleCanPreventAllSleepOnPower() {
        engine.apply(Self.ac)
        var building = rule("Building", [.appRunning(Self.xcode)])
        building.preventSleepOnPower = true
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        #expect(Set(assertions.live.values) == ["uawake: Rule: Building", "uawake: Rule: Building (on power)"])
    }

    @Test func zeroLingerEndsAtOnce() {
        let rules = makeRules([rule([.powerAdapter], linger: 0)])
        rules.update(.power(Self.ac))
        #expect(engine.sessions.count == 1)
        var battery = Self.ac
        battery.powerSource = .battery
        rules.update(.power(battery))
        #expect(engine.sessions.isEmpty)
    }

    // MARK: Condition types

    @Test func eventConditionsStartOnTheirSignalAndEndAfterLinger() async {
        let display = DisplayInfo(name: "Studio Display", isBuiltIn: false)
        let builtIn = DisplayInfo(name: "Built-in", isBuiltIn: true)
        let dock = ConnectedDevice(id: "05ac:8104", name: "Dock")
        let headset = ConnectedDevice(id: "a4-83-e7-12-34-56", name: "Headset")
        var battery = Self.ac
        battery.powerSource = .battery
        let cases: [(Condition, on: Signal, off: Signal)] = [
            (.appRunning(Self.xcode), apps([Self.xcode]), apps([])),
            (.appFrontmost(Self.keynote), apps([Self.keynote], frontmost: Self.keynote), apps([Self.keynote])),
            (.powerAdapter, .power(Self.ac), .power(battery)),
            (.externalDisplay(name: nil), .displays([builtIn, display]), .displays([builtIn])),
            (
                .externalDisplay(name: "Studio Display"), .displays([display]),
                .displays([.init(name: "TV", isBuiltIn: false)])
            ),
            (.device(kind: .usb, id: dock.id, name: "Dock"), .usbDevices([dock]), .usbDevices([])),
            (
                .device(kind: .bluetooth, id: headset.id, name: "Headset"), .bluetoothDevices([headset]),
                .bluetoothDevices([])
            ),
            (.wifi(ssid: "Office"), .wifi("Office"), .wifi("Cafe")),
        ]
        for (condition, on, off) in cases {
            let rules = makeRules([rule([condition])])
            rules.permissions = [.bluetooth: .granted, .location: .granted]
            rules.update(off)
            #expect(engine.sessions.isEmpty, "\(condition)")
            rules.update(on)
            #expect(engine.sessions.count == 1, "\(condition)")
            rules.update(off)
            await advance(rules, by: 119)
            #expect(engine.sessions.count == 1, "\(condition)")
            await advance(rules, by: 1)
            #expect(engine.sessions.isEmpty, "\(condition)")
            rules.setRules([])
        }
    }

    @Test func callNeedsThreeSecondsOfCameraOrMicrophoneUse() async {
        let rules = makeRules([rule([.call(camera: true, microphone: true)])])
        rules.update(.mediaUse(MediaUse(cameraInUse: false, microphoneInUse: true)))
        await advance(rules, by: 2)
        #expect(engine.sessions.isEmpty)
        await advance(rules, by: 1)
        #expect(engine.sessions.count == 1)

        // A blip shorter than the settle time never starts a session.
        rules.update(.mediaUse(MediaUse(cameraInUse: false, microphoneInUse: false)))
        await advance(rules, by: 120)
        #expect(engine.sessions.isEmpty)
        rules.update(.mediaUse(MediaUse(cameraInUse: true, microphoneInUse: false)))
        await advance(rules, by: 2)
        rules.update(.mediaUse(MediaUse(cameraInUse: false, microphoneInUse: false)))
        await advance(rules, by: 10)
        #expect(engine.sessions.isEmpty)
    }

    @Test func callCanWatchOnlyTheCamera() async {
        let rules = makeRules([rule([.call(camera: true, microphone: false)])])
        rules.update(.mediaUse(MediaUse(cameraInUse: false, microphoneInUse: true)))
        await advance(rules, by: 10)
        #expect(engine.sessions.isEmpty)
        rules.update(.mediaUse(MediaUse(cameraInUse: true, microphoneInUse: true)))
        await advance(rules, by: 3)
        #expect(engine.sessions.count == 1)
    }

    @Test func audioNeedsFiveSecondsSoAlertSoundsDoNotCount() async {
        let rules = makeRules([rule([.audioPlaying])])
        rules.update(.audioPlaying(true))
        await advance(rules, by: 3)
        rules.update(.audioPlaying(false))
        await advance(rules, by: 10)
        #expect(engine.sessions.isEmpty)
        rules.update(.audioPlaying(true))
        await advance(rules, by: 5)
        #expect(engine.sessions.count == 1)
    }

    @Test func cpuUsesTheAverageOverAFullWindow() async {
        let busy = rule([.cpuBusy(percent: 50, windowSeconds: 60)])
        let rules = makeRules([busy])
        await feed(rules, samples: 5, cpu: 90)
        #expect(engine.sessions.isEmpty, "the window is not full yet")
        #expect(rules.readings(for: busy) == [.init(state: .notMet, value: .level(current: nil, threshold: 50))])
        await feed(rules, samples: 1, cpu: 90)
        #expect(engine.sessions.count == 1)
        #expect(rules.readings(for: busy) == [.init(state: .met, value: .level(current: 90, threshold: 50))])

        // One idle sample keeps the average above 50%; more bring it down, then linger runs.
        await feed(rules, samples: 1, cpu: 0)
        #expect(rules.statuses[busy.id] == .matching)
        await feed(rules, samples: 3, cpu: 0)
        #expect(rules.statuses[busy.id] == .lingering(until: clock.now + 110))
        await feed(rules, samples: 11, cpu: 0)
        #expect(engine.sessions.isEmpty)
    }

    @Test func networkUsesTheChosenDirection() async {
        let download = rule("Down", [.networkBusy(bytesPerSecond: 1_000_000, direction: .download, windowSeconds: 30)])
        let upload = rule("Up", [.networkBusy(bytesPerSecond: 1_000_000, direction: .upload, windowSeconds: 30)])
        let both = rule("Both", [.networkBusy(bytesPerSecond: 1_000_000, direction: .both, windowSeconds: 30)])
        let rules = makeRules([download, upload, both])
        await feed(rules, samples: 3, bytesIn: 600_000, bytesOut: 600_000)
        #expect(names == ["uawake: Rule: Both"])
        await feed(rules, samples: 3, bytesIn: 2_000_000, bytesOut: 0)
        #expect(names == ["uawake: Rule: Both", "uawake: Rule: Down"])
    }

    @Test func staleSamplesDoNotMatch() async {
        let busy = rule([.cpuBusy(percent: 50, windowSeconds: 30)])
        let rules = makeRules([busy, rule("Other", [.appRunning(Self.xcode)])])
        await feed(rules, samples: 3, cpu: 90)
        #expect(rules.statuses[busy.id] == .matching)
        // The sampler stops (e.g. system sleep) and another signal triggers an evaluation.
        await advance(rules, by: 31)
        rules.update(apps([Self.xcode]))
        #expect(rules.statuses[busy.id] != .matching)
    }

    @Test func calendarEventStartsAndEndsOnItsBoundaries() async {
        let meeting = CalendarEvent(
            start: Self.start + 600, end: Self.start + 2400, calendarID: "work", title: "Défi review")
        let other = CalendarEvent(start: Self.start, end: Self.start + 3600, calendarID: "home", title: "Lunch")
        let any = rule("Any", [.calendarEvent(calendarID: nil, calendarName: nil, keyword: nil)], linger: 0)
        let work = rule("Work", [.calendarEvent(calendarID: "work", calendarName: "Work", keyword: nil)], linger: 0)
        let keyword = rule("Keyword", [.calendarEvent(calendarID: nil, calendarName: nil, keyword: "defi")], linger: 0)
        let rules = makeRules([any, work, keyword])
        rules.permissions = [.calendar: .granted]
        rules.update(.calendar([other, meeting]))
        #expect(names == ["uawake: Rule: Any"])
        await advance(rules, by: 600)
        #expect(names == ["uawake: Rule: Any", "uawake: Rule: Work", "uawake: Rule: Keyword"])
        #expect(rules.readings(for: keyword).first?.value == .names(["Défi review"]))
        await advance(rules, by: 1800)
        #expect(names == ["uawake: Rule: Any"])
        await advance(rules, by: 1200)
        #expect(names.isEmpty)
    }

    @Test func scheduleConditionStartsOnTimeAndEndsAfterLinger() async {
        // Weekdays 11:00–12:00; the clock starts on Monday at 10:00.
        let window = WeeklyWindow(
            days: Weekday.workdays, start: ClockTime(hour: 11, minute: 0)!, end: ClockTime(hour: 12, minute: 0)!)
        let scheduled = rule([.schedule(window)])
        let rules = makeRules([scheduled])
        await advance(rules, by: 3599)
        #expect(engine.sessions.isEmpty)
        await advance(rules, by: 1)
        #expect(engine.sessions.count == 1)
        await advance(rules, by: 3600)
        #expect(rules.statuses[scheduled.id] == .lingering(until: clock.now + 120))
        await advance(rules, by: 120)
        #expect(engine.sessions.isEmpty)
    }

    // MARK: All and any

    @Test func allMatchNeedsEveryOneOfThreeConditions() {
        let rules = makeRules([
            rule([.appRunning(Self.xcode), .powerAdapter, .externalDisplay(name: nil)], match: .all)
        ])
        rules.update(apps([Self.xcode]))
        rules.update(.power(Self.ac))
        #expect(engine.sessions.isEmpty)
        rules.update(.displays([DisplayInfo(name: "Studio Display", isBuiltIn: false)]))
        #expect(engine.sessions.count == 1)
        rules.update(apps([]))
        #expect(rules.statuses.values.first == .lingering(until: clock.now + 120))
    }

    @Test func anyMatchNeedsOneOfThreeConditions() async {
        let rules = makeRules([
            rule([.appRunning(Self.xcode), .powerAdapter, .externalDisplay(name: nil)], match: .any)
        ])
        #expect(engine.sessions.isEmpty)
        rules.update(.displays([DisplayInfo(name: "Studio Display", isBuiltIn: false)]))
        #expect(engine.sessions.count == 1)
        rules.update(apps([Self.xcode]))
        rules.update(.displays([]))
        #expect(rules.statuses.values.first == .matching, "another condition still holds")
        rules.update(apps([]))
        await advance(rules, by: 120)
        #expect(engine.sessions.isEmpty)
    }

    // MARK: Active hours

    @Test func activeHoursAcrossMidnightStartAndStopOnTime() async {
        // Monday 22:00 to Tuesday 02:00.
        let hours = WeeklyWindow(
            days: [.mon], start: ClockTime(hour: 22, minute: 0)!, end: ClockTime(hour: 2, minute: 0)!)
        let night = rule([.appRunning(Self.xcode)], hours: hours)
        let rules = makeRules([night])
        rules.update(apps([Self.xcode]))
        #expect(rules.statuses[night.id] == .outsideHours)
        await advance(rules, by: 12 * 3600 - 1)
        #expect(engine.sessions.isEmpty)
        await advance(rules, by: 1)
        #expect(engine.sessions.count == 1, "starts at 22:00")
        await advance(rules, by: 2 * 3600 + 1)
        #expect(engine.sessions.count == 1, "still on after midnight")
        await advance(rules, by: 2 * 3600 - 2)
        #expect(engine.sessions.count == 1)
        await advance(rules, by: 1)
        #expect(engine.sessions.isEmpty, "ends at 02:00 with no linger")
        #expect(rules.statuses[night.id] == .outsideHours)
        // Tuesday 22:00 is not in the window: only Monday starts one.
        await advance(rules, by: 21 * 3600)
        #expect(engine.sessions.isEmpty)
    }

    // MARK: Guards

    @Test func guardEndsARuleSessionAndTheRuleRearmsFiveMinutesAfterItClears() async {
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        engine.apply(Self.ac)
        rules.update(.power(Self.ac))
        rules.update(apps([Self.xcode]))
        #expect(engine.sessions.count == 1)

        engine.apply(Self.lowBattery)
        rules.update(.power(Self.lowBattery))
        await settle()
        #expect(engine.sessions.isEmpty)
        #expect(rules.statuses[building.id] == .waiting(.batteryGuard, until: nil))
        await advance(rules, by: 3600)
        #expect(engine.sessions.isEmpty, "stays off while the guard applies")

        engine.apply(Self.ac)
        rules.update(.power(Self.ac))
        #expect(rules.statuses[building.id] == .waiting(.batteryGuard, until: clock.now + 300))
        await advance(rules, by: 200)
        // The guard returns during the cool-down: the five minutes start again.
        engine.apply(Self.lowBattery)
        rules.update(.power(Self.lowBattery))
        await advance(rules, by: 200)
        engine.apply(Self.ac)
        rules.update(.power(Self.ac))
        await advance(rules, by: 299)
        #expect(engine.sessions.isEmpty)
        await advance(rules, by: 1)
        #expect(engine.sessions.count == 1)
        #expect(rules.statuses[building.id] == .matching)
    }

    @Test func startRefusedByAGuardWaitsLikeAGuardEnd() async {
        var hot = Self.ac
        hot.thermalState = .serious
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        engine.apply(hot)
        rules.update(.power(hot))
        rules.update(apps([Self.xcode]))
        #expect(engine.sessions.isEmpty)
        #expect(rules.statuses[building.id] == .waiting(.thermalGuard, until: nil))
        engine.apply(Self.ac)
        rules.update(.power(Self.ac))
        await advance(rules, by: 300)
        #expect(engine.sessions.count == 1)
    }

    @Test func aWaitingRuleWhoseConditionsClearGoesBackToIdle() async {
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        engine.apply(Self.lowBattery)
        rules.update(.power(Self.lowBattery))
        await settle()
        rules.update(apps([]))
        await advance(rules, by: 120)
        #expect(rules.statuses[building.id] == .idle)
    }

    @Test func aGuardPolicyChangeIsPickedUpOnReevaluation() async {
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        engine.apply(Self.lowBattery)
        rules.update(.power(Self.lowBattery))
        rules.update(apps([Self.xcode]))
        #expect(rules.statuses[building.id] == .waiting(.batteryGuard, until: nil))
        engine.policy.batteryThreshold = nil
        rules.reevaluate()
        await advance(rules, by: 300)
        #expect(engine.sessions.count == 1)
    }

    @Test func ruleSessionsAreExemptFromTheMaximumCap() async throws {
        let rules = makeRules([rule([.appRunning(Self.xcode)])])
        rules.update(apps([Self.xcode]))
        let manual = try engine.start(
            SessionRequest(source: .manual, reason: .standard(.manual, .indefinite), endCondition: .indefinite))
        #expect(manual.deadline == clock.now + 24 * 3600)
        #expect(engine.sessions.first?.deadline == nil)
        await advance(rules, by: 25 * 3600)
        #expect(engine.sessions.map(\.source) == [.rule])
    }

    // MARK: User actions

    @Test func stoppingARuleSessionHoldsTheRuleUntilConditionsClearAndReturn() async throws {
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        engine.stop(try #require(engine.sessions.first).id, cause: .stoppedByUser)
        await settle()
        #expect(rules.statuses[building.id] == .stoppedByUser)
        await advance(rules, by: 3600)
        #expect(engine.sessions.isEmpty)

        // A dip shorter than the linger time does not re-arm it.
        rules.update(apps([]))
        await advance(rules, by: 60)
        rules.update(apps([Self.xcode]))
        #expect(rules.statuses[building.id] == .stoppedByUser)

        rules.update(apps([]))
        await advance(rules, by: 120)
        #expect(rules.statuses[building.id] == .idle)
        rules.update(apps([Self.xcode]))
        #expect(engine.sessions.count == 1)
    }

    @Test func toggleAndDeactivateLeaveRuleSessionsAlone() throws {
        let rules = makeRules([rule([.appRunning(Self.xcode)])])
        rules.update(apps([Self.xcode]))
        let request = SessionRequest(
            source: .manual, reason: .standard(.manual, .indefinite), endCondition: .indefinite)
        try engine.toggle(request)
        try engine.toggle(request)
        engine.stopAll(source: .manual, cause: .stoppedByUser)
        engine.stopAll(source: .url, cause: .stoppedByUser)
        #expect(engine.sessions.map(\.source) == [.rule])
    }

    @Test func editingAnActiveRuleStartsTheNewSessionBeforeEndingTheOld() async {
        var building = rule("Building", [.appRunning(Self.xcode)])
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        var events = engine.events().makeAsyncIterator()

        building.name = "Compiling"
        building.modes = [.system, .display]
        rules.setRules([building])

        guard case .started(let new)? = await events.next(), case .ended(let old)? = await events.next() else {
            Issue.record("expected the new session to start, then the old one to end")
            return
        }
        #expect(new.reason == .rule(name: "Compiling"))
        #expect(old.reason == .rule(name: "Building"))
        #expect(names == ["uawake: Rule: Compiling"])
        #expect(assertions.live.count == 2)
        #expect(rules.statuses[building.id] == .matching)
        #expect(rules.sessionID(for: building.id) == new.id)
    }

    @Test func editingARuleSoItNoLongerMatchesEndsItsSession() {
        var building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        building.conditions = [.appRunning(Self.keynote)]
        rules.setRules([building])
        #expect(engine.sessions.isEmpty)
        #expect(rules.statuses[building.id] == .idle)
    }

    @Test func disablingOrDeletingARuleEndsItsSessionAtOnce() {
        var building = rule([.appRunning(Self.xcode)])
        let other = rule("Other", [.appRunning(Self.xcode)])
        let rules = makeRules([building, other])
        rules.update(apps([Self.xcode]))
        building.enabled = false
        rules.setRules([building, other])
        #expect(rules.statuses[building.id] == .off)
        #expect(names == ["uawake: Rule: Other"])
        rules.setRules([building])
        #expect(engine.sessions.isEmpty)
        #expect(rules.statuses[other.id] == nil)
    }

    @Test func togglingARuleRearmsItAfterAUserStop() async throws {
        var building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        engine.stop(try #require(engine.sessions.first).id, cause: .stoppedByUser)
        await settle()
        building.enabled = false
        rules.setRules([building])
        building.enabled = true
        rules.setRules([building])
        #expect(engine.sessions.count == 1)
    }

    // MARK: Pause

    @Test func pauseEndsRuleSessionsLeavesManualOnesAndResumesOnTime() async throws {
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        try engine.start(
            SessionRequest(source: .manual, reason: .standard(.manual, .indefinite), endCondition: .indefinite))

        rules.setPause(.until(clock.now + 3600))
        #expect(engine.sessions.map(\.source) == [.manual])
        #expect(rules.statuses[building.id] == .paused)
        #expect(rules.neededSignals.isEmpty)
        await advance(rules, by: 3599)
        #expect(engine.sessions.count == 1)
        await advance(rules, by: 1)
        #expect(rules.pause == nil)
        #expect(Set(engine.sessions.map(\.source)) == [.manual, .rule])
    }

    @Test func pauseUntilResumedHoldsUntilTurnedBackOn() async {
        let rules = makeRules([rule([.appRunning(Self.xcode)])], pause: .indefinitely)
        rules.update(apps([Self.xcode]))
        await advance(rules, by: 7 * 86_400)
        #expect(engine.sessions.isEmpty)
        rules.setPause(nil)
        #expect(engine.sessions.count == 1)
    }

    @Test func untilTomorrowIsSixOClockOnTheNextCalendarDay() {
        // Monday 10:00 → Tuesday 06:00; Tuesday 02:00 → Wednesday 06:00.
        #expect(RulePause.untilTomorrowMorning(from: Self.start, calendar: Self.utc) == .until(Self.start + 20 * 3600))
        #expect(
            RulePause.untilTomorrowMorning(from: Self.start + 16 * 3600, calendar: Self.utc)
                == .until(Self.start + 44 * 3600))
    }

    // MARK: Permissions

    @Test func aRuleMissingAPermissionStaysInactiveEvenInAnyMode() {
        let office = rule([.appRunning(Self.xcode), .wifi(ssid: "Office")], match: .any)
        let plain = rule("Plain", [.appRunning(Self.xcode)])
        let rules = makeRules([office, plain])
        rules.update(apps([Self.xcode]))
        rules.update(.wifi("Office"))
        #expect(rules.statuses[office.id] == .needsPermission(.location))
        #expect(rules.statuses[plain.id] == .matching, "other rules are not blocked")
        #expect(rules.readings(for: office).last?.state == .unavailable(.location))
        #expect(rules.neededSignals == [.apps], "no monitor is started without its permission")

        rules.permissions = [.location: .denied]
        #expect(rules.statuses[office.id] == .needsPermission(.location))
        rules.permissions = [.location: .granted]
        #expect(rules.statuses[office.id] == .matching)
        #expect(rules.neededSignals == [.apps, .wifi])
    }

    // MARK: Lifecycle

    @Test func nothingStartsOrEndsWhileTheUserSessionIsInactive() async {
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        rules.update(apps([Self.xcode]))
        engine.handle(.userSessionDidResignActive)
        rules.handle(.userSessionDidResignActive)
        #expect(assertions.live.isEmpty, "the session engine paused the rule session")
        rules.update(apps([]))
        await advance(rules, by: 600)
        #expect(engine.sessions.count == 1)

        engine.handle(.userSessionDidBecomeActive)
        rules.handle(.userSessionDidBecomeActive)
        #expect(rules.statuses[building.id] == .lingering(until: clock.now + 120))
        await advance(rules, by: 120)
        #expect(engine.sessions.isEmpty)
    }

    @Test func wakeDiscardsSamplesAndSettlesAgain() async {
        let busy = rule("CPU", [.cpuBusy(percent: 50, windowSeconds: 30)], linger: 0)
        let call = rule("Call", [.call(camera: true, microphone: true)], linger: 0)
        let rules = makeRules([busy, call])
        rules.update(.mediaUse(MediaUse(cameraInUse: true, microphoneInUse: false)))
        await feed(rules, samples: 3, cpu: 90)
        #expect(engine.sessions.count == 2)
        rules.handle(.systemDidWake)
        #expect(engine.sessions.isEmpty)
        await advance(rules, by: 3)
        #expect(names == ["uawake: Rule: Call"])
    }

    // MARK: Failures and outputs

    @Test func aFailedAssertionIsRetriedAtTheNextEvaluation() {
        let building = rule([.appRunning(Self.xcode)])
        let rules = makeRules([building])
        assertions.failure = -1
        rules.update(apps([Self.xcode]))
        #expect(rules.statuses[building.id] == .failed)
        assertions.failure = nil
        rules.update(apps([Self.xcode, Self.keynote]))
        #expect(rules.statuses[building.id] == .matching)
    }

    @Test func neededSignalsCoverEnabledRulesAndThePreview() {
        var off = rule("Off", [.audioPlaying])
        off.enabled = false
        let rules = makeRules([
            rule([.appRunning(Self.xcode), .cpuBusy(percent: 50, windowSeconds: 60), .powerAdapter]), off,
            rule(
                "Clock",
                [
                    .schedule(
                        WeeklyWindow(days: [.mon], start: .init(hour: 9, minute: 0)!, end: .init(hour: 10, minute: 0)!))
                ]),
        ])
        #expect(rules.neededSignals == [.apps, .load])
        rules.preview = off
        #expect(rules.neededSignals == [.apps, .load, .audioPlaying])
        #expect(rules.conditionsMatch(off) == false)
    }

    @Test func resettingASignalForgetsItsLastValue() async {
        let all: [Condition] = [
            .appRunning(Self.xcode), .call(camera: true, microphone: true), .audioPlaying,
            .cpuBusy(percent: 50, windowSeconds: 30), .externalDisplay(name: nil),
            .device(kind: .usb, id: "1", name: "1"), .device(kind: .bluetooth, id: "2", name: "2"),
            .wifi(ssid: "Office"),
            .calendarEvent(calendarID: nil, calendarName: nil, keyword: nil),
        ]
        let rules = makeRules(all.map { rule("\($0.kind)-\($0.signal?.rawValue ?? "")", [$0], linger: 0) })
        rules.permissions = [.bluetooth: .granted, .location: .granted, .calendar: .granted]
        rules.update(apps([Self.xcode]))
        rules.update(.mediaUse(MediaUse(cameraInUse: true, microphoneInUse: true)))
        rules.update(.audioPlaying(true))
        rules.update(.displays([DisplayInfo(name: "TV", isBuiltIn: false)]))
        rules.update(.usbDevices([ConnectedDevice(id: "1", name: "1")]))
        rules.update(.bluetoothDevices([ConnectedDevice(id: "2", name: "2")]))
        rules.update(.wifi("Office"))
        rules.update(.calendar([CalendarEvent(start: Self.start, end: Self.start + 9000, calendarID: "c", title: "t")]))
        await feed(rules, samples: 3, cpu: 90)
        #expect(engine.sessions.count == all.count)
        for kind in SignalKind.allCases { rules.reset(kind) }
        #expect(engine.sessions.isEmpty)
    }

    @Test func readingsShowLiveValues() {
        let rules = makeRules([])
        rules.update(apps([Self.xcode], frontmost: Self.xcode))
        rules.update(.displays([DisplayInfo(name: "Studio Display", isBuiltIn: false)]))
        let draft = rule([.appFrontmost(Self.keynote), .externalDisplay(name: nil), .audioPlaying])
        #expect(
            rules.readings(for: draft) == [
                .init(state: .notMet, value: .text("com.apple.dt.Xcode")),
                .init(state: .met, value: .names(["Studio Display"])),
                .init(state: .notMet, value: .flag(false)),
            ])
    }
}
