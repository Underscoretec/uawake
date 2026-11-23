import AppKit
import UAwakeCore

/// Fast user switching and sleep/wake from `NSWorkspace` notifications, and screen lock and
/// unlock from the distributed notifications `com.apple.screenIsLocked` and `screenIsUnlocked`
/// (verified from the sandbox in `docs/SANDBOX-SPIKE.md`). Use the notifications, not
/// `CGSessionCopyCurrentDictionary`: its lock flag still reads locked when `screenIsUnlocked` arrives.
public final class SystemSessionLifecycleMonitor: SessionLifecycleMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<SessionLifecycleEvent>()
    private var observers: [any NSObjectProtocol] = []
    private let center: NotificationCenter
    private var distributedObservers: [any NSObjectProtocol] = []

    @MainActor
    public init() {
        center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, SessionLifecycleEvent)] = [
            (NSWorkspace.sessionDidResignActiveNotification, .userSessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .userSessionDidBecomeActive),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
        ]
        let distributed: [(String, SessionLifecycleEvent)] = [
            ("com.apple.screenIsLocked", .screenDidLock), ("com.apple.screenIsUnlocked", .screenDidUnlock),
        ]
        for (name, event) in distributed {
            distributedObservers.append(
                DistributedNotificationCenter.default().addObserver(
                    forName: NSNotification.Name(name), object: nil, queue: nil
                ) { [broadcaster] _ in broadcaster.yield(event) })
        }
        for (name, event) in events {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [broadcaster] _ in broadcaster.yield(event)
                })
        }
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    public func events() -> AsyncStream<SessionLifecycleEvent> {
        broadcaster.stream()
    }
}
