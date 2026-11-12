import Foundation
import Testing
import UAwakeCoreTesting

@testable import UAwakeCore

@MainActor
struct SessionEngineTests {
    let clock = FakeClock()
    let assertions = FakeAssertionProvider()
    let engine: DefaultSessionEngine

    init() {
        engine = DefaultSessionEngine(assertions: assertions, clock: clock, guards: DefaultSessionEngine.standardGuards)
    }

    func request(_ condition: EndCondition, source: SessionSource = .manual, modes: Set<AwakeMode> = [.system])
        -> SessionRequest
    {
        SessionRequest(source: source, reason: .standard(source, condition), modes: modes, endCondition: condition)
    }

    /// Advances the fake clock and, if the engine's timer is now due, waits for it.
    func advance(by seconds: TimeInterval) async {
        let timer = engine.timerTask
        clock.advance(by: seconds)
        if let wake = engine.nextWake, wake <= clock.now { await timer?.value }
    }

    // MARK: Start, stop, events

    @Test func startAcquiresNamedAssertionsAndStopReleasesThem() throws {
        let session = try engine.start(request(.duration(.seconds(7200)), modes: [.display]))
        #expect(Set(assertions.live.values) == ["uawake: Manual: 2 hours"])
        #expect(assertions.live.count == 2)
        #expect(session.modes == [.system, .display])
        engine.stop(session.id, cause: .stoppedByUser)
        #expect(assertions.live.isEmpty)
        #expect(engine.sessions.isEmpty)
    }

    @Test func failedAcquireCreatesNoSession() {
        assertions.failure = -536_870_212
        #expect(throws: SessionEngineError.assertionFailed(code: -536_870_212)) {
            try engine.start(request(.indefinite))
        }
        #expect(engine.sessions.isEmpty)
    }

    @Test func eventsReportStartAndExpiry() async throws {
        var events = engine.events().makeAsyncIterator()
        let session = try engine.start(request(.duration(.seconds(60))))
        await advance(by: 59)
        #expect(engine.sessions.count == 1)
        await advance(by: 1)
        #expect(engine.sessions.isEmpty)
        #expect(assertions.live.isEmpty)
        #expect(await events.next() == .started(session))
        var ended = session
        ended.state = .ended(.expired)
        #expect(await events.next() == .ended(ended))
    }

    @Test func overlappingSessionsEndIndependently() async throws {
        try engine.start(request(.duration(.seconds(60))))
        try engine.start(request(.duration(.seconds(120))))
        await advance(by: 60)
        #expect(engine.sessions.count == 1)
        await advance(by: 60)
        #expect(engine.sessions.isEmpty)
    }

    // MARK: Maximum cap

    @Test func indefiniteSessionEndsAtMaximumCap() async throws {
        let session = try engine.start(request(.indefinite))
        var events = engine.events().makeAsyncIterator()
        #expect(session.deadline == clock.now + 24 * 3600)
        await advance(by: 24 * 3600)
        #expect(await events.next()?.endCause == .maximumCap)
    }

    @Test func timedSessionsIgnoreTheCap() throws {
        let session = try engine.start(request(.duration(.seconds(48 * 3600))))
        #expect(session.deadline == clock.now + 48 * 3600)
    }

    @Test func policyChangeRecomputesCapAndEndsPastSessions() async throws {
        let session = try engine.start(request(.batteryLevel(30)))
        var events = engine.events().makeAsyncIterator()
        await advance(by: 2 * 3600)
        engine.policy.maximumCap = .seconds(3 * 3600)
        #expect(engine.sessions.first?.deadline == session.startedAt + 3 * 3600)
        engine.policy.maximumCap = nil
        #expect(engine.sessions.first?.deadline == nil)
        engine.policy.maximumCap = .seconds(3600)
        #expect(engine.sessions.isEmpty)
        #expect(await events.next()?.endCause == .maximumCap)
    }

    @Test func pausedTimeCountsTowardTheCap() async throws {
        try engine.start(request(.indefinite))
        engine.handle(.userSessionDidResignActive)
        #expect(engine.sessions[0].state == .paused(remaining: nil))
        await advance(by: 25 * 3600)
        engine.handle(.userSessionDidBecomeActive)
        #expect(engine.sessions.isEmpty)
    }

    // MARK: Guards

    @Test func batteryGuardEndsSessionsOnlyOnBatteryAtThreshold() throws {
        try engine.start(request(.indefinite))
        engine.apply(.test(battery: 10, source: .ac))
        engine.apply(.test(battery: 21, source: .battery))
        #expect(engine.sessions.count == 1)
        engine.apply(.test(battery: 20, source: .battery))
        #expect(engine.sessions.isEmpty)
    }

    @Test func batteryGuardReportsItsCause() async throws {
        try engine.start(request(.indefinite))
        var events = engine.events().makeAsyncIterator()
        engine.apply(.test(battery: 5, source: .battery))
        #expect(await events.next()?.endCause == .batteryGuard)
    }

    @Test func batteryGuardOffWhenThresholdIsNil() throws {
        engine.policy.batteryThreshold = nil
        try engine.start(request(.indefinite))
        engine.apply(.test(battery: 1, source: .battery))
        #expect(engine.sessions.count == 1)
    }

    @Test func batteryGuardIgnoresMacsWithoutBattery() throws {
        try engine.start(request(.indefinite))
        engine.apply(.test(battery: nil, source: .battery))
        #expect(engine.sessions.count == 1)
    }

    @Test func lowPowerModeGuard() async throws {
        try engine.start(request(.indefinite))
        var events = engine.events().makeAsyncIterator()
        engine.apply(.test(lowPowerMode: true))
        #expect(await events.next()?.endCause == .lowPowerMode)
    }

    @Test(arguments: [ProcessInfo.ThermalState.serious, .critical])
    func thermalGuardEndsAtSeriousOrCritical(state: ProcessInfo.ThermalState) async throws {
        try engine.start(request(.indefinite))
        var events = engine.events().makeAsyncIterator()
        engine.apply(.test(thermal: .fair))
        #expect(engine.sessions.count == 1)
        engine.apply(.test(thermal: state))
        #expect(await events.next()?.endCause == .thermalGuard)
    }

    @Test func disabledGuardsDoNothing() throws {
        engine.policy.endOnLowPowerMode = false
        engine.policy.endOnThermalPressure = false
        try engine.start(request(.indefinite))
        engine.apply(.test(lowPowerMode: true, thermal: .critical))
        #expect(engine.sessions.count == 1)
    }

    @Test func guardsEndPausedSessionsToo() throws {
        try engine.start(request(.duration(.seconds(600))))
        engine.handle(.userSessionDidResignActive)
        engine.apply(.test(lowPowerMode: true))
        #expect(engine.sessions.isEmpty)
    }

    @Test func enablingAGuardAppliesToRunningSessions() async throws {
        engine.policy.endOnLowPowerMode = false
        engine.apply(.test(lowPowerMode: true))
        try engine.start(request(.indefinite))
        var events = engine.events().makeAsyncIterator()
        engine.policy.endOnLowPowerMode = true
        #expect(await events.next()?.endCause == .lowPowerMode)
    }

    @Test func raisingBatteryThresholdAppliesToRunningSessions() throws {
        engine.apply(.test(battery: 30, source: .battery))
        try engine.start(request(.indefinite))
        engine.policy.batteryThreshold = 40
        #expect(engine.sessions.isEmpty)
    }

    @Test func startIsRefusedWhileAGuardApplies() {
        engine.apply(.test(thermal: .serious))
        #expect(throws: SessionEngineError.wouldEndImmediately(.thermalGuard)) {
            try engine.start(request(.indefinite))
        }
        #expect(engine.sessions.isEmpty)
        #expect(assertions.live.isEmpty)
    }

    // MARK: Battery-level sessions

    @Test func batteryLevelEndsOnlyOnBatteryAtOrBelowThreshold() async throws {
        try engine.start(request(.batteryLevel(30)))
        var events = engine.events().makeAsyncIterator()
        engine.apply(.test(battery: 10, source: .ac))
        engine.apply(.test(battery: 31, source: .battery))
        #expect(engine.sessions.count == 1)
        engine.apply(.test(battery: 30, source: .battery))
        #expect(await events.next()?.endCause == .expired)
    }

    @Test func batteryLevelAlreadyReachedRefusesStart() {
        engine.apply(.test(battery: 25, source: .battery))
        #expect(throws: SessionEngineError.wouldEndImmediately(.expired)) {
            try engine.start(request(.batteryLevel(30)))
        }
    }

    // MARK: End warning

    @Test func warnsBeforeATimedSessionEnds() async throws {
        engine.endWarning = .seconds(300)
        let session = try engine.start(request(.duration(.seconds(3600))))
        var events = engine.events().makeAsyncIterator()
        await advance(by: 3299)
        await advance(by: 1)
        #expect(await events.next() == .aboutToEnd(session))
        await advance(by: 300)
        #expect(await events.next()?.endCause == .expired)
    }

    @Test func extendingRearmsTheWarning() async throws {
        engine.endWarning = .seconds(300)
        let session = try engine.start(request(.duration(.seconds(600))))
        var events = engine.events().makeAsyncIterator()
        await advance(by: 300)
        #expect(await events.next() == .aboutToEnd(session))
        try engine.extend(session.id, by: .seconds(900))
        await advance(by: 900)
        guard case .aboutToEnd(let warned) = await events.next() else {
            Issue.record("expected a second warning")
            return
        }
        #expect(warned.deadline == session.startedAt + 1500)
    }

    @Test func noWarningForShortOrUncappedSessions() async throws {
        engine.endWarning = .seconds(300)
        try engine.start(request(.duration(.seconds(120))))
        try engine.start(request(.indefinite))
        var events = engine.events().makeAsyncIterator()
        await advance(by: 120)
        #expect(await events.next()?.endCause == .expired)
        #expect(engine.nextWake == clock.now + 24 * 3600 - 120)
    }

    // MARK: Extend, until, toggle, lifecycle

    @Test func extendOnlyTimedSessions() throws {
        let timed = try engine.start(request(.duration(.seconds(60))))
        try engine.extend(timed.id, by: .seconds(900))
        #expect(engine.sessions[0].deadline == clock.now + 960)
        let indefinite = try engine.start(request(.indefinite))
        #expect(throws: SessionEngineError.notExtendable) { try engine.extend(indefinite.id, by: .seconds(900)) }
        let battery = try engine.start(request(.batteryLevel(20)))
        #expect(throws: SessionEngineError.notExtendable) { try engine.extend(battery.id, by: .seconds(900)) }
        #expect(throws: SessionEngineError.sessionNotFound) { try engine.extend(UUID(), by: .seconds(1)) }
    }

    @Test func extendWhilePausedAddsToRemaining() throws {
        let session = try engine.start(request(.duration(.seconds(600))))
        try engine.pause(session.id)
        try engine.extend(session.id, by: .seconds(60))
        #expect(engine.sessions[0].state == .paused(remaining: .seconds(660)))
        #expect(throws: SessionEngineError.invalidState) { try engine.pause(session.id) }
    }

    @Test func untilTimeRollsToTomorrowWhenPassed() throws {
        let calendar = Calendar.current
        let now = clock.now
        let time = try #require(
            ClockTime(hour: calendar.component(.hour, from: now), minute: calendar.component(.minute, from: now)))
        let session = try engine.start(request(.until(time)))
        let deadline = try #require(session.deadline)
        #expect(deadline > now && deadline <= now + 24 * 3600)
    }

    @Test func toggleCountsOnlyManualAndURLSessions() throws {
        let rule = try engine.start(
            SessionRequest(source: .rule, reason: .rule(name: "On a call"), endCondition: .indefinite))
        #expect(try engine.toggle(request(.indefinite)) != nil)
        #expect(engine.sessions.count == 2)
        try engine.start(request(.duration(.seconds(60)), source: .url))
        #expect(try engine.toggle(request(.indefinite)) == nil)
        #expect(engine.sessions.map(\.id) == [rule.id])
    }

    @Test func fastUserSwitchingPausesAndResumesWithRemainingTime() async throws {
        let session = try engine.start(request(.duration(.seconds(3600))))
        await advance(by: 600)
        engine.handle(.userSessionDidResignActive)
        #expect(engine.sessions[0].state == .paused(remaining: .seconds(3000)))
        #expect(assertions.live.isEmpty)
        await advance(by: 7200)
        #expect(engine.sessions.count == 1)
        engine.handle(.userSessionDidBecomeActive)
        #expect(engine.sessions[0].state == .active)
        #expect(engine.sessions[0].deadline == clock.now + 3000)
        #expect(assertions.live.count == 1)
        #expect(throws: SessionEngineError.invalidState) { try engine.resume(session.id) }
    }

    @Test func pauseAndResumeAreReportedAsEvents() async throws {
        let session = try engine.start(request(.duration(.seconds(600))))
        var events = engine.events().makeAsyncIterator()
        engine.handle(.userSessionDidResignActive)
        engine.handle(.userSessionDidBecomeActive)
        guard case .paused(let paused) = await events.next(), case .resumed(let resumed) = await events.next() else {
            Issue.record("expected paused then resumed")
            return
        }
        #expect(paused.id == session.id && paused.state == .paused(remaining: .seconds(600)))
        #expect(resumed.state == .active)
    }

    @Test func wakeEndsSessionsWhoseDeadlinePassedDuringSleep() throws {
        try engine.start(request(.duration(.seconds(60))))
        engine.handle(.systemWillSleep)
        clock.advance(by: 3600)
        engine.handle(.systemDidWake)
        #expect(engine.sessions.isEmpty)
    }

    @Test func englishReasons() {
        #expect(
            SessionReason.standard(.manual, .duration(.seconds(5400))).englishDescription
                == "Manual: 1 hour 30 minutes")
        #expect(
            SessionReason.standard(.url, .until(ClockTime(hour: 8, minute: 5)!)).englishDescription
                == "URL: until 08:05")
        #expect(SessionReason.standard(.manual, .batteryLevel(20)).englishDescription == "Manual: until battery 20%")
        #expect(SessionReason.rule(name: "On a call").englishDescription == "Rule: On a call")
        #expect(SessionReason.custom("Render").englishDescription == "Render")
    }

    // MARK: On power

    @Test func onPowerHoldsPreventSystemSleepOnlyOnACAndOnlyWhileActive() throws {
        let onPower = "uawake: Manual: indefinite (on power)"
        engine.apply(.test(source: .ac))
        let session = try engine.start(request(.indefinite))
        #expect(assertions.live.count == 1)  // Setting off.
        engine.preventsSleepOnPower = true
        #expect(Set(assertions.live.values) == ["uawake: Manual: indefinite", onPower])
        engine.apply(.test(source: .battery))
        #expect(Array(assertions.live.values) == ["uawake: Manual: indefinite"])
        engine.apply(.test(source: .ac))
        #expect(assertions.live.values.contains(onPower))
        try engine.pause(session.id)
        #expect(assertions.live.isEmpty)
        try engine.resume(session.id)
        #expect(assertions.live.count == 2)
        engine.preventsSleepOnPower = false
        #expect(assertions.live.count == 1)
        engine.preventsSleepOnPower = true
        engine.stop(session.id, cause: .stoppedByUser)
        #expect(assertions.live.isEmpty)
    }

    @Test func onPowerSettingSkipsRuleSessionsButTheRuleFlagHoldsIt() throws {
        engine.apply(.test(source: .ac))
        engine.preventsSleepOnPower = true
        try engine.start(SessionRequest(source: .rule, reason: .rule(name: "A"), endCondition: .indefinite))
        #expect(assertions.live.count == 1)
        engine.preventsSleepOnPower = false
        try engine.start(
            SessionRequest(
                source: .rule, reason: .rule(name: "B"), endCondition: .indefinite, preventsSleepOnPower: true))
        #expect(assertions.live.values.contains("uawake: Rule: B (on power)"))
        #expect(assertions.live.count == 3)
    }

    @Test func failedOnPowerAcquireKeepsTheSession() throws {
        let session = try engine.start(request(.indefinite))
        engine.preventsSleepOnPower = true
        assertions.failure = -1
        engine.apply(.test(source: .ac))
        #expect(engine.sessions.map(\.id) == [session.id])
        assertions.failure = nil
        engine.apply(.test(source: .ac))
        #expect(assertions.live.count == 2)
    }
}

extension SessionEvent {
    var endCause: EndCause? {
        if case .ended(let session) = self, case .ended(let cause) = session.state { return cause }
        return nil
    }
}
