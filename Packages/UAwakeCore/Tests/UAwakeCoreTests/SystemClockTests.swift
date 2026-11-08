import Foundation
import Testing

@testable import UAwakeCore

struct SystemClockTests {
    /// Records each wait and advances a fake "now" by it (plus `lateBy` for relaxed waits,
    /// as App Nap coalescing would).
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var time = Date(timeIntervalSinceReferenceDate: 0)
        var waits: [(seconds: TimeInterval, precise: Bool)] = []
        let lateBy: TimeInterval

        init(lateBy: TimeInterval = 0) { self.lateBy = lateBy }

        var clock: SystemClock {
            SystemClock(now: { self.lock.withLock { self.time } }) { seconds, precise in
                self.lock.withLock {
                    self.waits.append((seconds, precise))
                    self.time += seconds + (precise ? 0 : self.lateBy)
                }
            }
        }
    }

    @Test func activityIsHeldOnlyInTheFinalMinute() async throws {
        let recorder = Recorder()
        try await recorder.clock.sleep(until: recorder.time + 7200)
        #expect(recorder.waits.map(\.seconds) == [7140, 60])
        #expect(recorder.waits.map(\.precise) == [false, true])
        #expect(recorder.waits.filter(\.precise).allSatisfy { $0.seconds <= SystemClock.precisionWindow })
    }

    @Test func shortWaitsArePreciseThroughout() async throws {
        let recorder = Recorder()
        try await recorder.clock.sleep(until: recorder.time + 30)
        #expect(recorder.waits.map(\.seconds) == [30])
        #expect(recorder.waits.map(\.precise) == [true])
    }

    @Test func lateRelaxedWakeShortensThePreciseWait() async throws {
        let recorder = Recorder(lateBy: 8)
        try await recorder.clock.sleep(until: recorder.time + 120)
        #expect(recorder.waits.map(\.seconds) == [60, 52])
        #expect(recorder.waits.map(\.precise) == [false, true])
    }

    @Test func pastDeadlinesReturnAtOnce() async throws {
        let recorder = Recorder()
        try await recorder.clock.sleep(until: recorder.time - 5)
        #expect(recorder.waits.isEmpty)
    }
}
