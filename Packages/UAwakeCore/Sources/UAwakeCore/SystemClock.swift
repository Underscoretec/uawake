import Foundation

/// Real time. `Task.sleep(for:)` runs on `ContinuousClock`, which keeps counting
/// while the Mac sleeps, so a deadline that passed during sleep fires on wake.
public struct SystemClock: SessionClock {
    public init() {}

    public var now: Date { Date() }

    /// Holds a latency-critical activity while waiting: without it App Nap coalesces
    /// a background menu bar app's timers and deadlines fire up to ~10 s late.
    /// The activity allows idle system sleep, so it never keeps the Mac awake itself.
    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Waiting for a uawake session deadline"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try await Task.sleep(for: .seconds(interval), tolerance: .zero)
    }
}
