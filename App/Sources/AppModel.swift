import AppKit
import ServiceManagement
import UAwakeCore
import UAwakeIPC
import UAwakeSystem
import os

/// Owns the engine and connects it to settings, system monitors, the URL scheme,
/// the global shortcut and notifications.
@MainActor
final class AppModel {
    static let logger = Logger(subsystem: "com.underscoretec.uawake", category: "app")

    let engine: DefaultSessionEngine
    let settings: UAwakeSettings
    let popover: PopoverViewModel
    let notifications: NotificationController
    let hotKey = HotKeyController()
    let updates: UpdatesModel
    /// Why the current shortcut could not be registered, or `nil`.
    private(set) var shortcutProblem: String?

    /// `settingsSuite` keeps settings in a throwaway domain (cleared at launch), so UI tests
    /// and acceptance runs never touch real settings. `fixedDeviceState` replaces the real
    /// power monitor (UI tests and screenshots).
    init(settingsSuite: String? = nil, fixedDeviceState: DeviceState? = nil) {
        let defaults: UserDefaults
        if let settingsSuite, let testDefaults = UserDefaults(suiteName: settingsSuite) {
            testDefaults.removePersistentDomain(forName: settingsSuite)
            defaults = testDefaults
        } else {
            defaults = .standard
        }
        let settings = UAwakeSettings(defaults: defaults)
        self.settings = settings
        let engine = DefaultSessionEngine(
            assertions: IOKitAssertionProvider(),
            clock: SystemClock(),
            guards: DefaultSessionEngine.standardGuards,
            policy: settings.policy,
            endWarning: settings.endWarning
        )
        self.engine = engine
        popover = PopoverViewModel(engine: engine, settings: settings)
        notifications = NotificationController(engine: engine, settings: settings)
        updates = UpdatesModel(settings: settings)

        if let fixedDeviceState {
            engine.apply(fixedDeviceState)
        } else {
            let deviceState = SystemDeviceStateMonitor()
            Task { for await state in deviceState.updates() { engine.apply(state) } }
        }
        let lifecycle = SystemSessionLifecycleMonitor()
        Task { for await event in lifecycle.events() { engine.handle(event) } }
        Task { [notifications, popover] in
            for await event in engine.events() {
                notifications.handle(event)
                popover.handle(event)
            }
        }
        // Posted for every in-process change, including @AppStorage writes from Settings.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                engine.apply(settings)
                self?.registerShortcut()
            }
        }
        hotKey.onPress = { [weak self] in self?.popover.toggle() }
        registerShortcut()
    }

    func open(_ url: URL) {
        URLRouter.route(url, to: engine, defaultCondition: settings.primaryClickAction)
    }

    /// Ends every session with `.appQuit` so history (from 1.2) records why.
    func quit() {
        for session in engine.sessions { engine.stop(session.id, cause: .appQuit) }
    }

    private var registeredShortcut: GlobalShortcut?

    func registerShortcut() {
        let shortcut = settings.globalShortcut
        guard shortcut != registeredShortcut else { return }
        registeredShortcut = shortcut
        hotKey.unregister()
        shortcutProblem = nil
        guard let shortcut else { return }
        let status = hotKey.register(shortcut)
        if status != noErr {
            shortcutProblem = String(
                localized: "That shortcut is already in use. Choose another.",
                comment: "Settings: global shortcut could not be registered")
            Self.logger.warning("Shortcut registration failed: \(status)")
        }
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Self.logger.error("Launch at login change failed: \(String(describing: error), privacy: .public)")
        }
    }
}
