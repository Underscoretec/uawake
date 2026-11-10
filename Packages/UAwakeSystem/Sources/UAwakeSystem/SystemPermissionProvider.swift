import CoreBluetooth
import CoreLocation
import EventKit
import Foundation
import UAwakeCore

/// Calendar, Location and Bluetooth authorization. `status` never prompts; `request`
/// prompts only when the status is `.notDetermined`.
public final class SystemPermissionProvider: PermissionProvider {
    public init() {}

    public func status(_ permission: RulePermission) -> PermissionStatus {
        switch permission {
        case .calendar: Self.status(EKEventStore.authorizationStatus(for: .event))
        // No delegate, so creating the manager off the main thread is fine.
        case .location: Self.status(CLLocationManager().authorizationStatus)
        case .bluetooth: Self.status(CBCentralManager.authorization)
        }
    }

    public func request(_ permission: RulePermission) async -> PermissionStatus {
        let current = status(permission)
        guard current == .notDetermined else { return current }
        switch permission {
        case .calendar:
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToEvents()
        case .location:
            await LocationRequest.shared.run()
        case .bluetooth:
            await BluetoothRequest.shared.run()
        }
        return status(permission)
    }

    static func status(_ status: EKAuthorizationStatus) -> PermissionStatus {
        status == .fullAccess ? .granted : status == .notDetermined ? .notDetermined : .denied
    }

    /// On macOS `.authorizedAlways` is the only granted state (`.authorized` is its alias).
    static func status(_ status: CLAuthorizationStatus) -> PermissionStatus {
        status == .authorizedAlways ? .granted : status == .notDetermined ? .notDetermined : .denied
    }

    static func status(_ status: CBManagerAuthorization) -> PermissionStatus {
        status == .allowedAlways ? .granted : status == .notDetermined ? .notDetermined : .denied
    }
}

/// Holds the manager and delegate until the prompt is answered. Concurrent requests share
/// one prompt; each waiter is resumed exactly once because the list is cleared on resume.
@MainActor
private final class LocationRequest: NSObject, CLLocationManagerDelegate {
    static let shared = LocationRequest()
    private var manager: CLLocationManager?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard manager == nil else { return }
            let manager = CLLocationManager()
            self.manager = manager
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            // The first callback reports the initial status, before the user answers.
            guard status != .notDetermined else { return }
            finish()
        }
    }

    private func finish() {
        manager?.delegate = nil
        manager = nil
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
private final class BluetoothRequest: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothRequest()
    private var manager: CBCentralManager?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard manager == nil else { return }
            // Creating the manager shows the prompt; delegate calls arrive on the main queue.
            manager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard CBCentralManager.authorization != .notDetermined else { return }
            manager?.delegate = nil
            manager = nil
            let waiters = self.waiters
            self.waiters = []
            for waiter in waiters { waiter.resume() }
        }
    }
}
