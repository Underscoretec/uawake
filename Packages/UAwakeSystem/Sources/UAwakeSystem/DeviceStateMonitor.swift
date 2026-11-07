import UAwakeCore

/// Observes battery level, power source, Low Power Mode and thermal state.
/// The production conformer uses IOKit power-source notifications and
/// `ProcessInfo` notifications; tests replay recorded sequences through a fake.
public protocol DeviceStateMonitor: Sendable {
    /// The latest known state.
    var current: DeviceState { get }

    /// Each call returns a new stream that yields `current` immediately, then
    /// every change. The stream ends when the consuming task is cancelled.
    func updates() -> AsyncStream<DeviceState>
}
