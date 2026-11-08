import Foundation

/// Real time. `Task.sleep(for:)` runs on `ContinuousClock`, which keeps counting
/// while the Mac sleeps, so a deadline that passed during sleep fires on wake.
public struct SystemClock: SessionClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        if interval > 0 { try await Task.sleep(for: .seconds(interval)) }
    }
}
