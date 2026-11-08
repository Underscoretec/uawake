import AppKit
import UAwakeCore
import UAwakeIPC
import UAwakeSystem

/// Owns the engine and connects it to settings, system monitors and the URL scheme.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let engine: DefaultSessionEngine
    let settings = UAwakeSettings()

    private init() {
        let settings = settings
        let engine = DefaultSessionEngine(
            assertions: IOKitAssertionProvider(),
            clock: SystemClock(),
            guards: DefaultSessionEngine.standardGuards,
            policy: settings.policy,
            endWarning: settings.endWarning
        )
        self.engine = engine
        let deviceState = SystemDeviceStateMonitor()
        let lifecycle = SystemSessionLifecycleMonitor()
        Task { for await state in deviceState.updates() { engine.apply(state) } }
        Task { for await event in lifecycle.events() { engine.handle(event) } }
        // Posted for every in-process change, including @AppStorage writes from Settings.
        Task {
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                engine.apply(settings)
            }
        }
    }

    /// The primary-click session.
    var defaultRequest: SessionRequest {
        let condition = settings.primaryClickAction
        return SessionRequest(source: .manual, reason: .standard(.manual, condition), endCondition: condition)
    }

    func open(_ url: URL) {
        URLRouter.route(url, to: engine, defaultCondition: settings.primaryClickAction)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppModel.shared.open(url) }
    }
}
