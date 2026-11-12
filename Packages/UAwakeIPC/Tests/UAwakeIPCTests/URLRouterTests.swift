import Foundation
import Testing
import UAwakeCore
import UAwakeCoreTesting
import UAwakeIPC

@MainActor
struct URLRouterTests {
    let clock = FakeClock()
    let assertions = FakeAssertionProvider()
    let engine: DefaultSessionEngine

    init() {
        engine = DefaultSessionEngine(assertions: assertions, clock: clock, guards: DefaultSessionEngine.standardGuards)
    }

    @discardableResult
    func route(
        _ string: String, defaultCondition: EndCondition = .indefinite,
        defaultModes: Set<AwakeMode> = [.system, .display]
    ) -> Bool {
        URLRouter.route(
            URL(string: string)!, to: engine, defaultCondition: defaultCondition, defaultModes: defaultModes)
    }

    @Test func activateIndefinite() throws {
        #expect(route("uawake://activate"))
        let session = try #require(engine.sessions.first)
        #expect(session.source == .url)
        #expect(session.endCondition == .indefinite)
        #expect(session.modes == [.system, .display])
        #expect(Set(assertions.live.values) == ["uawake: URL: indefinite"])
    }

    @Test func toggleUsesTheDefaultModes() {
        route("uawake://toggle", defaultModes: [.system])
        #expect(engine.sessions.map(\.modes) == [[.system]])
    }

    @Test func displayZeroIsSystemOnly() throws {
        route("uawake://activate?display=0")
        route("uawake://activate?display=1", defaultModes: [.system])
        route("uawake://activate", defaultModes: [.system])
        #expect(engine.sessions.map(\.modes) == [[.system], [.system, .display], [.system]])
    }

    @Test func activateDuration() throws {
        route("uawake://activate?duration=1h30m")
        let session = try #require(engine.sessions.first)
        #expect(session.endCondition == .duration(.seconds(5400)))
        #expect(session.deadline == clock.now + 5400)
    }

    @Test func activateUntil() throws {
        route("uawake://activate?until=18:30")
        #expect(engine.sessions.first?.endCondition == .until(ClockTime(hour: 18, minute: 30)!))
    }

    @Test func activateWithDisplayAndReason() throws {
        route("uawake://activate?display=1&reason=Render")
        let session = try #require(engine.sessions.first)
        #expect(session.modes == [.system, .display])
        #expect(session.reason == .custom("Render"))
        #expect(Set(assertions.live.values) == ["uawake: Render"])
    }

    @Test func deactivateEndsManualAndURLSessionsOnly() throws {
        try engine.start(SessionRequest(source: .manual, reason: .custom("m"), endCondition: .indefinite))
        try engine.start(SessionRequest(source: .rule, reason: .rule(name: "r"), endCondition: .indefinite))
        route("uawake://activate")
        #expect(route("uawake://deactivate"))
        #expect(engine.sessions.map(\.source) == [.rule])
    }

    @Test func toggleStartsTheDefaultSessionThenStopsIt() throws {
        try engine.start(SessionRequest(source: .cli, reason: .custom("build"), endCondition: .indefinite))
        #expect(route("uawake://toggle", defaultCondition: .duration(.seconds(3600))))
        let started = try #require(engine.sessions.last)
        #expect(started.source == .url)
        #expect(started.endCondition == .duration(.seconds(3600)))
        route("uawake://toggle")
        #expect(engine.sessions.map(\.source) == [.cli])
    }

    @Test(arguments: [
        "https://activate", "uawake://sleep", "uawake://activate?duration=0", "uawake://activate?disk=1",
        "uawake://activate?duration=1h&until=18:30", "uawake://toggle?x=1",
    ])
    func invalidURLsChangeNothing(url: String) throws {
        try engine.start(SessionRequest(source: .manual, reason: .custom("keep"), endCondition: .indefinite))
        let before = engine.sessions
        #expect(!route(url))
        #expect(engine.sessions == before)
        #expect(assertions.live.count == 1)
    }

    @Test func refusedStartChangesNothing() {
        engine.apply(.test(lowPowerMode: true))
        #expect(!route("uawake://activate"))
        #expect(engine.sessions.isEmpty)
    }
}
