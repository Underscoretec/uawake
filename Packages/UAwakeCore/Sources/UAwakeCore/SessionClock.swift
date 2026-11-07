import Foundation

/// Wall-clock time and waiting, injected so the engine is testable without real time.
///
/// Named `SessionClock` rather than `Clock` to avoid shadowing Swift's `Clock` protocol.
/// Deadlines are wall-clock `Date`s because "until 18:30" is wall-clock and
/// sessions must keep their deadline across system sleep.
public protocol SessionClock: Sendable {
    /// The current time.
    var now: Date { get }

    /// Suspends until `deadline` (returns immediately if it has passed).
    /// - Throws: `CancellationError` if the calling task is cancelled.
    func sleep(until deadline: Date) async throws
}
