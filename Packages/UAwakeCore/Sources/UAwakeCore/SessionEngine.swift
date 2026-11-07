import Foundation

/// The only component that holds power assertions. Every entry point starts, stops
/// or limits sessions through this protocol.
///
/// Isolated to the main actor. Conforming types are expected to be `@Observable`
/// so SwiftUI tracks ``sessions`` directly.
@MainActor
public protocol SessionEngine: AnyObject {
    /// Sessions that are active or paused, oldest first. Ended sessions are removed.
    var sessions: [Session] { get }

    /// Guard thresholds and the maximum cap. Setting it recomputes the cap deadline
    /// of active indefinite and battery-level sessions, ending any now past it
    /// with ``EndCause/maximumCap``.
    var policy: GuardPolicy { get set }

    /// Starts a session and acquires its assertions before returning.
    /// - Throws: ``SessionEngineError/assertionFailed(code:)`` if IOKit refuses;
    ///   no session is created in that case.
    @discardableResult
    func start(_ request: SessionRequest) throws(SessionEngineError) -> Session

    /// Ends one session and releases its assertions immediately.
    /// Unknown ids are ignored.
    func stop(_ id: Session.ID, cause: EndCause)

    /// Ends every session from `source`, e.g. `uawake://deactivate` calls this
    /// for `.manual` and `.url`.
    func stopAll(source: SessionSource, cause: EndCause)

    /// The menu bar primary click and `uawake://toggle`. Only `.manual` and `.url`
    /// sessions count as "on": if any exist (active or paused) they are all stopped
    /// with ``EndCause/stoppedByUser`` and this returns `nil`; otherwise `request`
    /// is started and returned. Rule, CLI and other sessions are never touched.
    @discardableResult
    func toggle(_ request: SessionRequest) throws(SessionEngineError) -> Session?

    /// Moves the deadline of a `duration` or `until` session forward by `amount`.
    /// - Throws: ``SessionEngineError/notExtendable`` for indefinite and
    ///   battery-level sessions; the UI hides the control for them.
    func extend(_ id: Session.ID, by amount: Duration) throws(SessionEngineError)

    /// Releases a session's assertions and freezes its remaining time.
    func pause(_ id: Session.ID) throws(SessionEngineError)

    /// Re-acquires assertions and restarts the countdown with the frozen remaining time.
    func resume(_ id: Session.ID) throws(SessionEngineError)

    /// Applies a device-state change: ends battery-level sessions whose level is
    /// reached on battery power, then ends whatever the guards return.
    func apply(_ state: DeviceState)

    /// Applies a user-session or sleep/wake event (see ``SessionLifecycleEvent``).
    func handle(_ event: SessionLifecycleEvent)

    /// Each call returns a new stream that yields every session as it ends, with
    /// its ``EndCause``. Used for guard notifications and, from 1.2, history.
    func endedSessions() -> AsyncStream<Session>
}

public enum SessionEngineError: Error, Equatable, Sendable {
    case sessionNotFound
    /// The session is not in a state that allows the operation (e.g. resuming an active one).
    case invalidState
    /// Only `duration` and `until` sessions can be extended.
    case notExtendable
    /// IOKit returned a non-success `IOReturn`.
    case assertionFailed(code: Int32)
}
