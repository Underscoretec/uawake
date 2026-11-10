import AppKit
import UAwakeCore

/// Running and frontmost apps from `NSWorkspace` launch, terminate and activate notifications.
public final class SystemAppsMonitor: SignalMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<AppsState>()
    private let lock = NSLock()
    private var state: AppsState
    private var observers: [any NSObjectProtocol] = []

    public init() {
        state = Self.read()
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    self?.refresh(Self.read())
                })
        }
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    public var current: AppsState { lock.withLock { state } }

    public func updates() -> AsyncStream<AppsState> {
        broadcaster.stream(startingWith: current)
    }

    /// Stores `new` and yields it unless it equals the current value.
    func refresh(_ new: AppsState) {
        let changed = lock.withLock {
            defer { state = new }
            return state != new
        }
        if changed { broadcaster.yield(new) }
    }

    static func read() -> AppsState {
        let workspace = NSWorkspace.shared
        return state(
            bundleIDs: workspace.runningApplications.map(\.bundleIdentifier),
            frontmost: workspace.frontmostApplication?.bundleIdentifier)
    }

    /// Apps without a bundle identifier are skipped.
    static func state(bundleIDs: [String?], frontmost: String?) -> AppsState {
        AppsState(running: Set(bundleIDs.compactMap { $0 }), frontmost: frontmost)
    }
}
