import Foundation
import UAwakeCore
import UserNotifications

/// "About to end" warnings with Extend and Stop actions, and a notice naming the guard
/// whenever a guard or the maximum cap ends a session.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let engine: DefaultSessionEngine
    private let settings: UAwakeSettings
    private var center: UNUserNotificationCenter { .current() }

    private static let endingCategory = "SESSION_ENDING"
    private static let extendShort = "EXTEND_15"
    private static let extendLong = "EXTEND_60"
    private static let stopAction = "STOP"

    init(engine: DefaultSessionEngine, settings: UAwakeSettings) {
        self.engine = engine
        self.settings = settings
        super.init()
        guard Bundle.main.bundleIdentifier != nil, !ProcessInfo.processInfo.arguments.contains("-UITesting") else {
            return
        }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.endingCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.extendShort,
                        title: String(localized: "+15 min", comment: "Notification action")),
                    UNNotificationAction(
                        identifier: Self.extendLong, title: String(localized: "+1 hr", comment: "Notification action")),
                    UNNotificationAction(
                        identifier: Self.stopAction, title: String(localized: "Stop", comment: "Notification action"),
                        options: .destructive),
                ],
                intentIdentifiers: [])
        ])
    }

    /// Asks once; later calls return the current answer without a prompt.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func handle(_ event: SessionEvent) {
        switch event {
        case .started:
            break
        case .aboutToEnd(let session):
            guard let deadline = session.deadline else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Session ending soon", comment: "Notification title")
            let remaining = Duration.seconds(max(60, deadline.timeIntervalSinceNow.rounded()))
                .formatted(.units(allowed: [.hours, .minutes], width: .wide))
            content.body = String(
                localized: "\(session.reason.localizedDescription) ends in \(remaining).",
                comment: "Notification body: reason, time left")
            content.categoryIdentifier = Self.endingCategory
            content.userInfo = ["session": session.id.uuidString]
            post(content, id: Self.warningID(session.id))
        case .ended(let session):
            center.removeDeliveredNotifications(withIdentifiers: [Self.warningID(session.id)])
            guard case .ended(let cause) = session.state, let text = cause.guardText(settings: settings) else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = String(
                localized: "\(session.reason.localizedDescription) ended. \(text.detail)",
                comment: "Notification body: reason, then why the guard ended it")
            post(content, id: "ended-\(session.id.uuidString)")
        }
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private static func warningID(_ id: Session.ID) -> String { "warning-\(id.uuidString)" }

    private func perform(action: String, sessionID: String?) {
        guard let sessionID, let id = UUID(uuidString: sessionID) else { return }
        switch action {
        case Self.extendShort: try? engine.extend(id, by: .seconds(900))
        case Self.extendLong: try? engine.extend(id, by: .seconds(3600))
        case Self.stopAction: engine.stop(id, cause: .stoppedByUser)
        default: break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let sessionID = response.notification.request.content.userInfo["session"] as? String
        await MainActor.run { perform(action: action, sessionID: sessionID) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
