import Foundation
import IOKit.ps
import UAwakeCore

/// Battery and power source from IOKit power-source notifications; Low Power Mode
/// and thermal state from `ProcessInfo` notifications.
public final class SystemDeviceStateMonitor: DeviceStateMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<DeviceState>()
    private let lock = NSLock()
    private var state: DeviceState
    private var observers: [any NSObjectProtocol] = []
    private var runLoopSource: CFRunLoopSource?

    public init() {
        state = Self.read()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refresh() })
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                Unmanaged<SystemDeviceStateMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }, context)?.takeRetainedValue()
        {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    public var current: DeviceState { lock.withLock { state } }

    public func updates() -> AsyncStream<DeviceState> {
        broadcaster.stream(startingWith: current)
    }

    private func refresh() {
        let new = Self.read()
        let changed = lock.withLock {
            defer { state = new }
            return state != new
        }
        if changed { broadcaster.yield(new) }
    }

    static func read() -> DeviceState {
        let info = ProcessInfo.processInfo
        var level: Int?
        var source = PowerSource.unknown
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            switch IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? {
            case kIOPSACPowerValue: source = .ac
            case kIOPSBatteryPowerValue: source = .battery
            default: break
            }
            let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for item in list {
                guard
                    let description = IOPSGetPowerSourceDescription(snapshot, item)?.takeUnretainedValue()
                        as? [String: Any],
                    description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                    let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                    let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0
                else { continue }
                level = currentCapacity * 100 / maxCapacity
            }
        }
        return DeviceState(
            batteryLevel: level,
            powerSource: source,
            isLowPowerModeEnabled: info.isLowPowerModeEnabled,
            thermalState: info.thermalState
        )
    }
}
