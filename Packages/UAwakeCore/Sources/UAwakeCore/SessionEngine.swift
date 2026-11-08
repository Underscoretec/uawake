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
    /// with ``EndCause/maximumCap``, and re-runs the guards on the last device state.
    var policy: GuardPolicy { get set }

    /// How long before a `duration` or `until` session ends to emit
    /// ``SessionEvent/aboutToEnd(_:)``; `nil` turns the warning off. Sessions shorter
    /// than the lead time are not warned.
    var endWarning: Duration? { get set }

    /// Starts a session and acquires its assertions before returning.
    /// - Throws: ``SessionEngineError/wouldEndImmediately(_:)`` if a guard or the
    ///   session's own battery level already applies to the last device state;
    ///   ``SessionEngineError/assertionFailed(code:)`` if IOKit refuses.
    ///   No session is created in either case.
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

    /// Each call returns a new stream of ``SessionEvent``s from now on. Notifications
    /// and the UI consume it; from 1.2, history too.
    func events() -> AsyncStream<SessionEvent>
}

/// What happened to a session. Sessions are snapshots taken at the time of the event.
public enum SessionEvent: Equatable, Sendable {
    case started(Session)
    /// A `duration` or `until` session reached ``SessionEngine/endWarning`` before its deadline.
    case aboutToEnd(Session)
    /// The session's state is `.ended(cause)`.
    case ended(Session)
}

public enum SessionEngineError: Error, Equatable, Sendable {
    case sessionNotFound
    /// The session is not in a state that allows the operation (e.g. resuming an active one).
    case invalidState
    /// Only `duration` and `until` sessions can be extended.
    case notExtendable
    /// Starting now would end the session at once with this cause (a guard, or
    /// `.expired` for a battery level already reached).
    case wouldEndImmediately(EndCause)
    /// IOKit returned a non-success `IOReturn`.
    case assertionFailed(code: Int32)
}
