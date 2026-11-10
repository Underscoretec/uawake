import UAwakeCore

/// One system observation feeding the rule engine (running apps, displays, load…).
/// A monitor observes from `init` to `deinit` and must release every system resource
/// in `deinit`: the app creates one only while a rule needs it.
public protocol SignalMonitor<Value>: Sendable {
    associatedtype Value: Sendable

    /// Each call returns a new stream that yields the current value immediately (when
    /// one exists), then every change. Equal consecutive values are not repeated.
    func updates() -> AsyncStream<Value>
}

/// Reads and requests the privacy permissions rules can need.
public protocol PermissionProvider: Sendable {
    /// Never prompts.
    func status(_ permission: RulePermission) -> PermissionStatus

    /// Shows the system prompt when the status is `.notDetermined`; otherwise returns the status.
    func request(_ permission: RulePermission) async -> PermissionStatus
}
