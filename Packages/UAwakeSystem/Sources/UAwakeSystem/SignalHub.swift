import UAwakeCore

/// Runs a system monitor only while its signal is needed, and forwards what it reports.
/// The app keeps `setNeeded` in step with `RuleEngine.neededSignals`, so with no rules
/// nothing runs. Stopping a signal releases its monitor.
@MainActor
public final class SignalHub {
    public typealias Source = @MainActor () -> AsyncStream<Signal>

    private let sources: [SignalKind: Source]
    private let deliver: @MainActor (Signal) -> Void
    private let stopped: @MainActor (SignalKind) -> Void
    private var tasks: [SignalKind: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - deliver: receives every signal, e.g. `RuleEngine.update`.
    ///   - stopped: called when a signal's monitor stops, e.g. `RuleEngine.reset`.
    public init(
        sources: [SignalKind: Source] = SignalHub.systemSources,
        deliver: @escaping @MainActor (Signal) -> Void,
        stopped: @escaping @MainActor (SignalKind) -> Void = { _ in }
    ) {
        self.sources = sources
        self.deliver = deliver
        self.stopped = stopped
    }

    public var running: Set<SignalKind> { Set(tasks.keys) }

    public func setNeeded(_ kinds: Set<SignalKind>) {
        for (kind, task) in tasks where !kinds.contains(kind) {
            task.cancel()
            tasks[kind] = nil
            stopped(kind)
        }
        for kind in kinds where tasks[kind] == nil {
            guard let stream = sources[kind]?() else { continue }
            tasks[kind] = Task { [deliver] in
                for await signal in stream { deliver(signal) }
            }
        }
    }

    /// Recreates a running monitor so it reads afresh (after wake, or once a permission is granted).
    public func restart(_ kind: SignalKind) {
        guard tasks[kind] != nil else { return }
        setNeeded(running.subtracting([kind]))
        setNeeded(running.union([kind]))
    }

    /// A stream of `monitor`'s values as signals. It keeps the monitor alive until the
    /// stream's consumer stops.
    public static func stream<Monitor: SignalMonitor>(
        _ monitor: Monitor, _ wrap: @escaping @Sendable (Monitor.Value) -> Signal
    ) -> AsyncStream<Signal> {
        AsyncStream { continuation in
            let task = Task {
                for await value in monitor.updates() { continuation.yield(wrap(value)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The production monitors. `.power` is absent: the app already runs `DeviceStateMonitor`.
    public static let systemSources: [SignalKind: Source] = [
        .apps: { stream(SystemAppsMonitor()) { .apps($0) } },
        .mediaUse: { stream(SystemMediaUseMonitor()) { .mediaUse($0) } },
        .audioPlaying: { stream(SystemAudioOutputMonitor()) { .audioPlaying($0) } },
        .load: { stream(SystemLoadMonitor()) { .load($0) } },
        .displays: { stream(SystemDisplayMonitor()) { .displays($0) } },
        .usbDevices: { stream(SystemUSBMonitor()) { .usbDevices($0) } },
        .bluetoothDevices: { stream(SystemBluetoothMonitor()) { .bluetoothDevices($0) } },
        .wifi: { stream(SystemWiFiMonitor()) { .wifi($0) } },
        .calendar: { stream(SystemCalendarMonitor()) { .calendar($0) } },
    ]
}
