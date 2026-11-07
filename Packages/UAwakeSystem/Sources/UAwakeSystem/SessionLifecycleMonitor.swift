import UAwakeCore

/// Observes fast user switching and system sleep/wake. The production conformer
/// uses `NSWorkspace` session and sleep notifications; tests use a fake.
/// The app forwards each event to ``SessionEngine/handle(_:)``.
public protocol SessionLifecycleMonitor: Sendable {
    /// Each call returns a new stream of events from now on. The stream ends
    /// when the consuming task is cancelled.
    func events() -> AsyncStream<SessionLifecycleEvent>
}
