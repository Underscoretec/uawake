import CoreWLAN
import Foundation
import Network
import os

/// The current Wi-Fi network name. `nil` when not associated or when Location is not
/// granted. Re-read on network path changes and, when CoreWLAN delivers them, on SSID
/// change events. No polling.
public final class SystemWiFiMonitor: SignalMonitor, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.underscoretec.uawake", category: "system")
    private let broadcaster = Broadcaster<String?>()
    private let lock = NSLock()
    private var ssid: String?
    private let pathMonitor = NWPathMonitor()
    private let client = CWWiFiClient()
    private let eventDelegate = EventDelegate()

    public init() {
        ssid = Self.read()
        pathMonitor.pathUpdateHandler = { [weak self] _ in self?.refresh() }
        pathMonitor.start(queue: DispatchQueue(label: "com.underscoretec.uawake.wifi"))
        eventDelegate.onChange = { [weak self] in self?.refresh() }
        client.delegate = eventDelegate
        do {
            try client.startMonitoringEvent(with: .ssidDidChange)
        } catch {
            Self.logger.warning("Wi-Fi SSID events unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        pathMonitor.cancel()
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    public var current: String? { lock.withLock { ssid } }

    public func updates() -> AsyncStream<String?> {
        lock.withLock { broadcaster.stream(startingWith: ssid) }
    }

    /// Re-reads the SSID, e.g. after Location access is granted.
    public func refresh() {
        lock.withLock {
            let new = Self.read()
            guard new != ssid else { return }
            ssid = new
            broadcaster.yield(new)
        }
    }

    /// The current network name; `nil` without Location access or when not associated.
    public static func read() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    private final class EventDelegate: NSObject, CWEventDelegate, @unchecked Sendable {
        var onChange: (@Sendable () -> Void)?

        func ssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    }
}
