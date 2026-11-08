import Foundation
import Testing

@testable import UAwakeCore

@MainActor
struct SessionEngineTests {
    let clock = FakeClock()
    let assertions = FakeAssertionProvider()
    let engine: DefaultSessionEngine

    init() {
        engine = DefaultSessionEngine(assertions: assertions, clock: clock)
    }

    func request(_ condition: EndCondition, source: SessionSource = .manual, modes: Set<AwakeMode> = [.system])
        -> SessionRequest
    {
        SessionRequest(source: source, reason: .standard(source, condition), modes: modes, endCondition: condition)
    }

    /// Advances the fake clock and, if a deadline is now due, waits for the engine's timer.
    func advance(by seconds: TimeInterval) async {
        let timer = engine.timerTask
        clock.advance(by: seconds)
        let next = engine.sessions.filter { $0.state == .active }.compactMap(\.deadline).min()
        if let next, next <= clock.now { await timer?.value }
    }

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

    @Test func durationSessionExpires() async throws {
        let ended = engine.endedSessions()
        try engine.start(request(.duration(.seconds(60))))
        await advance(by: 59)
        #expect(engine.sessions.count == 1)
        await advance(by: 1)
        #expect(engine.sessions.isEmpty)
        #expect(assertions.live.isEmpty)
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next()?.state == .ended(.expired))
    }

    @Test func overlappingSessionsEndIndependently() async throws {
        try engine.start(request(.duration(.seconds(60))))
        try engine.start(request(.duration(.seconds(120))))
        await advance(by: 60)
        #expect(engine.sessions.count == 1)
        await advance(by: 60)
        #expect(engine.sessions.isEmpty)
    }

    @Test func indefiniteSessionEndsAtMaximumCap() async throws {
        let ended = engine.endedSessions()
        let session = try engine.start(request(.indefinite))
        #expect(session.deadline == clock.now + 24 * 3600)
        await advance(by: 24 * 3600)
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next()?.state == .ended(.maximumCap))
    }

    @Test func timedSessionsIgnoreTheCap() throws {
        let session = try engine.start(request(.duration(.seconds(48 * 3600))))
        #expect(session.deadline == clock.now + 48 * 3600)
    }

    @Test func policyChangeRecomputesCapAndEndsPastSessions() async throws {
        let ended = engine.endedSessions()
        let session = try engine.start(request(.batteryLevel(30)))
        await advance(by: 2 * 3600)
        engine.policy.maximumCap = .seconds(3 * 3600)
        #expect(engine.sessions.first?.deadline == session.startedAt + 3 * 3600)
        engine.policy.maximumCap = nil
        #expect(engine.sessions.first?.deadline == nil)
        engine.policy.maximumCap = .seconds(3600)
        #expect(engine.sessions.isEmpty)
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next()?.state == .ended(.maximumCap))
    }

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

    @Test func untilTimeRollsToTomorrowWhenPassed() throws {
        let calendar = Calendar.current
        let now = clock.now
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let time = try #require(ClockTime(hour: hour, minute: minute))
        let session = try engine.start(request(.until(time)))
        let deadline = try #require(session.deadline)
        #expect(deadline > now && deadline <= now + 24 * 3600)
    }

    @Test func batteryLevelEndsOnlyOnBatteryAtOrBelowThreshold() throws {
        try engine.start(request(.batteryLevel(30)))
        engine.apply(
            DeviceState(batteryLevel: 10, powerSource: .ac, isLowPowerModeEnabled: false, thermalState: .nominal))
        #expect(engine.sessions.count == 1)
        engine.apply(
            DeviceState(batteryLevel: 31, powerSource: .battery, isLowPowerModeEnabled: false, thermalState: .nominal))
        #expect(engine.sessions.count == 1)
        engine.apply(
            DeviceState(batteryLevel: 30, powerSource: .battery, isLowPowerModeEnabled: false, thermalState: .nominal))
        #expect(engine.sessions.isEmpty)
    }

    @Test func toggleCountsOnlyManualAndURLSessions() throws {
        let rule = try engine.start(
            SessionRequest(source: .rule, reason: .rule(name: "On a call"), endCondition: .indefinite))
        let started = try engine.toggle(request(.indefinite))
        #expect(started != nil)
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

    @Test func wakeEndsSessionsWhoseDeadlinePassedDuringSleep() throws {
        try engine.start(request(.duration(.seconds(60))))
        engine.handle(.systemWillSleep)
        clock.advance(by: 3600)
        engine.handle(.systemDidWake)
        #expect(engine.sessions.isEmpty)
    }

    @Test func englishReasons() {
        #expect(
            SessionReason.standard(.manual, .duration(.seconds(5400))).englishDescription == "Manual: 1 hour 30 minutes"
        )
        #expect(
            SessionReason.standard(.url, .until(ClockTime(hour: 8, minute: 5)!)).englishDescription
                == "URL: until 08:05")
        #expect(SessionReason.standard(.manual, .batteryLevel(20)).englishDescription == "Manual: until battery 20%")
        #expect(SessionReason.custom("Render").englishDescription == "Render")
    }
}
