import Foundation
import Testing
import UAwakeCore
import UAwakeCoreTesting
import UAwakeSystem

@testable import uawake

@MainActor
struct LockDimModelTests {
    final class Knobs: IdleTimeProvider, DisplayAssertionProbe, @unchecked Sendable {
        var idle: TimeInterval = 0
        var playing = false
        func secondsSinceLastInput() -> TimeInterval { idle }
        func othersHoldDisplay() -> Bool { playing }
    }

    struct FixedLocker: ScreenLocker {
        let requirement: PasswordRequirement
        func lock() async -> LockMethod? { .displaySleep }
        func passwordRequirement() async -> PasswordRequirement { requirement }
    }

    let knobs = Knobs()
    let engine = DefaultSessionEngine(assertions: FakeAssertionProvider(), clock: FakeClock())
    let settings = UAwakeSettings(defaults: UserDefaults(suiteName: "lockdim-app-\(UUID().uuidString)")!)

    func model(_ requirement: PasswordRequirement = .immediate) -> LockDimModel {
        LockDimModel(
            engine: engine, settings: settings, idle: knobs, displays: knobs,
            locker: FixedLocker(requirement: requirement))
    }

    func startSession() throws {
        try engine.start(
            SessionRequest(
                source: .manual, reason: .standard(.manual, .indefinite), modes: [.system, .display],
                endCondition: .indefinite))
    }

    @Test func dimShowsAtTheThresholdAndGoesOnInput() throws {
        settings.dimEnabled = true
        settings.dimMinutes = 2
        let lockDim = model()
        try startSession()
        lockDim.refresh()
        knobs.idle = 119
        lockDim.tick()
        #expect(!lockDim.isDimmed)
        knobs.idle = 120
        lockDim.tick()
        #expect(lockDim.isDimmed)
        knobs.idle = 0.01
        lockDim.tick()
        #expect(!lockDim.isDimmed)
    }

    @Test func noDimWithoutASessionOrWhilePlaying() throws {
        settings.dimEnabled = true
        let lockDim = model()
        knobs.idle = 9999
        lockDim.tick()
        #expect(!lockDim.isDimmed)
        try startSession()
        knobs.playing = true
        lockDim.tick()
        #expect(!lockDim.isDimmed)
    }

    @Test func buttonNeverSaysLockWhenNoPasswordIsAsked() async {
        for requirement in [PasswordRequirement.never, .delay(seconds: 300)] {
            let lockDim = model(requirement)
            await lockDim.refreshRequirement()
            #expect(lockDim.buttonTitle == "Screen off (no password required)")
            #expect(!lockDim.buttonTitle.contains("Lock"))
            #expect(lockDim.caption != nil && lockDim.autoLockCaption != nil)
        }
        let prompt = model(.immediate)
        await prompt.refreshRequirement()
        #expect(prompt.buttonTitle == "Lock now" && prompt.caption == nil)
    }

    @Test func statusTextUsesScreenOffWhenNothingLocks() async {
        settings.dimEnabled = true
        settings.autoLockEnabled = true
        let lockDim = model(.never)
        await lockDim.refreshRequirement()
        #expect(lockDim.statusText == "Dims after 5 min idle · Screen off after 10 min idle")
    }
}
