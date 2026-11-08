import Foundation

/// Real time. Waits run on `ContinuousClock`, which keeps counting while the Mac
/// sleeps, so a deadline that passed during sleep fires on wake.
///
/// App Nap coalesces a background menu bar app's timers by up to ~10 s. So the wait is
/// split: a relaxed sleep until ``precisionWindow`` before the deadline, then a precise
/// sleep under a latency-critical activity. The activity allows idle system sleep, so it
/// never keeps the Mac awake itself, and it is held only for that final window.
public struct SystemClock: SessionClock {
    public static let precisionWindow: TimeInterval = 60

    private let currentDate: @Sendable () -> Date
    private let wait: @Sendable (_ seconds: TimeInterval, _ precise: Bool) async throws -> Void

    public init() {
        self.init(now: { Date() }, wait: Self.realWait)
    }

    /// For tests: `wait` receives each sleep and whether it holds the activity.
    init(
        now: @escaping @Sendable () -> Date,
        wait: @escaping @Sendable (_ seconds: TimeInterval, _ precise: Bool) async throws -> Void
    ) {
        currentDate = now
        self.wait = wait
    }

    public var now: Date { currentDate() }

    public func sleep(until deadline: Date) async throws {
        let relaxed = deadline.timeIntervalSince(now) - Self.precisionWindow
        if relaxed > 0 { try await wait(relaxed, false) }
        let remaining = deadline.timeIntervalSince(now)
        if remaining > 0 { try await wait(remaining, true) }
    }

    private static func realWait(_ seconds: TimeInterval, precise: Bool) async throws {
        guard precise else {
            try await Task.sleep(for: .seconds(seconds))
            return
        }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Waiting for a uawake session deadline"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try await Task.sleep(for: .seconds(seconds), tolerance: .zero)
    }
}
