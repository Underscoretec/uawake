import Foundation
import IOBluetooth
import UAwakeCore
import os

private let logger = Logger(subsystem: "com.underscoretec.uawake", category: "system")

/// Connected paired Bluetooth devices, re-read 1 s after the last connect or disconnect.
/// Creating it can show the Bluetooth permission prompt: create it only once permission is granted.
public final class SystemBluetoothMonitor: SignalMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<[ConnectedDevice]>()
    private let lock = NSLock()
    private var devices: [ConnectedDevice]
    private let observer: BluetoothObserver

    /// IOBluetooth is main-thread API.
    @MainActor public init() {
        devices = Self.read(connectedOnly: true)
        observer = BluetoothObserver()
        observer.onChange = { [weak self] in self?.update(Self.read(connectedOnly: true)) }
        observer.start()
    }

    deinit {
        let observer = observer
        Task { @MainActor in observer.stop() }
    }

    public func updates() -> AsyncStream<[ConnectedDevice]> {
        broadcaster.stream(startingWith: lock.withLock { devices })
    }

    /// Every paired device, connected or not, for the rule editor's picker.
    @MainActor public static func pairedDevices() -> [ConnectedDevice] {
        read(connectedOnly: false)
    }

    private func update(_ new: [ConnectedDevice]) {
        let changed = lock.withLock {
            defer { devices = new }
            return devices != new
        }
        if changed { broadcaster.yield(new) }
    }

    @MainActor static func read(connectedOnly: Bool) -> [ConnectedDevice] {
        let paired = IOBluetoothDevice.pairedDevices()?.compactMap { $0 as? IOBluetoothDevice } ?? []
        return ConnectedDevice.normalized(
            paired.filter { !connectedOnly || $0.isConnected() }.compactMap {
                bluetoothDevice(address: $0.addressString, name: $0.name)
            })
    }

    /// `A4:83:E7:12:34:56` or `a4-83-e7-12-34-56` → `a4-83-e7-12-34-56`.
    static func bluetoothID(address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ":", with: "-")
    }

    static func bluetoothDevice(address: String?, name: String?) -> ConnectedDevice? {
        guard let address, !address.isEmpty else { return nil }
        let id = bluetoothID(address: address)
        return ConnectedDevice(id: id, name: ConnectedDevice.firstName(name) ?? id)
    }
}

/// Receives IOBluetooth's selector-based notifications on the main thread.
@MainActor private final class BluetoothObserver: NSObject {
    var onChange: (@MainActor () -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var pending: Task<Void, Never>?

    func start() {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(connected(_:device:)))
        if connectNotification == nil { logger.warning("Bluetooth: connect notification registration failed") }
        for device in IOBluetoothDevice.pairedDevices()?.compactMap({ $0 as? IOBluetoothDevice }) ?? []
        where device.isConnected() {
            watch(device)
        }
    }

    func stop() {
        pending?.cancel()
        connectNotification?.unregister()
        connectNotification = nil
        for notification in disconnectNotifications.values { notification.unregister() }
        disconnectNotifications = [:]
        onChange = nil
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        watch(device)
        scheduleRead()
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        if let address = device.addressString { disconnectNotifications[address] = nil }
        scheduleRead()
    }

    private func watch(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, disconnectNotifications[address] == nil else { return }
        if let notification = device.register(
            forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        {
            disconnectNotifications[address] = notification
        } else {
            logger.warning("Bluetooth: disconnect notification registration failed")
        }
    }

    private func scheduleRead() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
