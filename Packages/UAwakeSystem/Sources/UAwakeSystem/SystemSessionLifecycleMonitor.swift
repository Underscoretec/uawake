import AppKit
import UAwakeCore

/// Fast user switching and sleep/wake from `NSWorkspace` notifications.
public final class SystemSessionLifecycleMonitor: SessionLifecycleMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<SessionLifecycleEvent>()
    private var observers: [any NSObjectProtocol] = []
    private let center: NotificationCenter

    @MainActor
    public init() {
        center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, SessionLifecycleEvent)] = [
            (NSWorkspace.sessionDidResignActiveNotification, .userSessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .userSessionDidBecomeActive),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
        ]
        for (name, event) in events {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [broadcaster] _ in broadcaster.yield(event)
                })
        }
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    public func events() -> AsyncStream<SessionLifecycleEvent> {
        broadcaster.stream()
    }
}
