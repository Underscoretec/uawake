import Foundation
import IOKit
import UAwakeCore
import os

private let logger = Logger(subsystem: "com.underscoretec.uawake", category: "system")

/// Connected USB devices (`IOUSBHostDevice`), re-read 1 s after the last attach or detach.
public final class SystemUSBMonitor: SignalMonitor, @unchecked Sendable {
    /// Weak hop for the C callback, so a callback racing `deinit` never touches a freed monitor.
    private final class Target: @unchecked Sendable {
        weak var monitor: SystemUSBMonitor?
    }

    private let broadcaster = Broadcaster<[ConnectedDevice]>()
    private let lock = NSLock()
    private var devices: [ConnectedDevice]
    private let queue = DispatchQueue(label: "com.underscoretec.uawake.usb")
    private let target = Target()
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    /// Touched only on `queue`.
    private var pending: DispatchWorkItem?

    public init() {
        devices = Self.read()
        target.monitor = self
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.warning("USB: IONotificationPortCreate failed")
            return
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, queue)
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            SystemUSBMonitor.drain(iterator)
            guard let refcon else { return }
            Unmanaged<Target>.fromOpaque(refcon).takeUnretainedValue().monitor?.scheduleRefresh()
        }
        let refcon = Unmanaged.passUnretained(target).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching("IOUSBHostDevice"), callback, refcon, &iterator)
            guard status == KERN_SUCCESS else {
                logger.warning("USB: IOServiceAddMatchingNotification failed: \(status)")
                continue
            }
            iterators.append(iterator)
            Self.drain(iterator)  // Arms the notification.
        }
        update(Self.read())  // Catches a device that came or went while arming.
    }

    deinit {
        if let port { IONotificationPortDestroy(port) }
        for iterator in iterators { IOObjectRelease(iterator) }
        // A callback already running on `queue` finishes before this releases `target`.
        queue.async { [target] in withExtendedLifetime(target) {} }
    }

    public func updates() -> AsyncStream<[ConnectedDevice]> {
        broadcaster.stream(startingWith: lock.withLock { devices })
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.update(Self.read()) }
        pending = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func update(_ new: [ConnectedDevice]) {
        let changed = lock.withLock {
            defer { devices = new }
            return devices != new
        }
        if changed { broadcaster.yield(new) }
    }

    static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
    }

    /// The USB devices attached right now, for the rule editor's picker.
    public static func read() -> [ConnectedDevice] {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        guard status == KERN_SUCCESS else {
            logger.warning("USB: IOServiceGetMatchingServices failed: \(status)")
            return []
        }
        defer { IOObjectRelease(iterator) }
        var found: [ConnectedDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            var entryName = [CChar](repeating: 0, count: 128)
            let entry =
                IORegistryEntryGetName(service, &entryName) == KERN_SUCCESS
                ? String(decoding: entryName.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self) : nil
            if let device = usbDevice(
                vendor: property("idVendor") as? Int,
                product: property("idProduct") as? Int,
                productName: property("USB Product Name") as? String,
                entryName: entry
            ) {
                found.append(device)
            }
        }
        return ConnectedDevice.normalized(found)
    }

    /// `05ac:8104`: lowercase, four hex digits each.
    static func usbID(vendor: Int, product: Int) -> String {
        String(format: "%04x:%04x", vendor & 0xFFFF, product & 0xFFFF)
    }

    static func usbDevice(vendor: Int?, product: Int?, productName: String?, entryName: String?) -> ConnectedDevice? {
        guard let vendor, let product else { return nil }
        let id = usbID(vendor: vendor, product: product)
        return ConnectedDevice(id: id, name: ConnectedDevice.firstName(productName, entryName) ?? id)
    }
}

extension ConnectedDevice {
    /// One entry per id (the first wins), sorted by name, then id.
    static func normalized(_ devices: [ConnectedDevice]) -> [ConnectedDevice] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.id).inserted }.sorted {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.id < $1.id
            }
        }
    }

    /// The first candidate that isn't empty or whitespace, trimmed.
    static func firstName(_ candidates: String?...) -> String? {
        candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}
