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
    let rules: RulesModel
    /// Why the current shortcut could not be registered, or `nil`.
    private(set) var shortcutProblem: String?

    /// `settingsSuite` keeps settings in a throwaway domain (cleared at launch), so UI tests
    /// and acceptance runs never touch real settings. `fixedDeviceState` replaces the real
    /// power monitor (UI tests and screenshots).
    /// `rulesFile` names a file in the rules folder (acceptance and soak runs); otherwise
    /// isolated runs keep their rules in a throwaway folder. `rulesFixture` loads the
    /// screenshot rules with scripted signals and no system monitors.
    init(
        settingsSuite: String? = nil, fixedDeviceState: DeviceState? = nil, rulesFile: String? = nil,
        rulesFixture: Bool = false
    ) {
        let defaults: UserDefaults
        if let settingsSuite, let testDefaults = UserDefaults(suiteName: settingsSuite) {
            testDefaults.removePersistentDomain(forName: settingsSuite)
            defaults = testDefaults
        } else {
            defaults = .standard
        }
        let settings = UAwakeSettings(defaults: defaults)
        self.settings = settings
        let clock = SystemClock()
        let engine = DefaultSessionEngine(
            assertions: IOKitAssertionProvider(),
            clock: clock,
            guards: DefaultSessionEngine.standardGuards
        )
        engine.apply(settings)  // Every setting the engine reads, as on each later change.
        self.engine = engine
        popover = PopoverViewModel(engine: engine, settings: settings)
        notifications = NotificationController(engine: engine, settings: settings)
        updates = UpdatesModel(settings: settings)

        var rulesURL = RuleStore.defaultURL()
        if let rulesFile {
            rulesURL = rulesURL.deletingLastPathComponent().appendingPathComponent(rulesFile)
        } else if settingsSuite != nil {
            rulesURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("uawake-rules-\(UUID().uuidString)").appendingPathComponent("rules.json")
        }
        let rules = RulesModel(
            sessions: engine, clock: clock, settings: settings, store: RuleStore(url: rulesURL),
            permissions: rulesFixture ? RulesFixture.permissions : SystemPermissionProvider(),
            monitors: rulesFixture ? nil : SignalHub.systemSources)
        self.rules = rules
        popover.rules = rules

        // The rule engine sees each device state after the session engine has applied it,
        // so a guard has already ended its sessions when it looks.
        if let fixedDeviceState {
            engine.apply(fixedDeviceState)
            rules.apply(fixedDeviceState)
        } else {
            let deviceState = SystemDeviceStateMonitor()
            Task {
                for await state in deviceState.updates() {
                    engine.apply(state)
                    rules.apply(state)
                }
            }
        }
        let lifecycle = SystemSessionLifecycleMonitor()
        Task {
            for await event in lifecycle.events() {
                engine.handle(event)
                rules.handle(event)
            }
        }
        // Subscribed before any rule session can start, so no event is missed.
        let events = engine.events()
        Task { [notifications, popover] in
            for await event in events {
                notifications.handle(event)
                popover.handle(event)
                rules.handle(event)
            }
        }
        // Active hours and schedules follow the wall clock and the time zone.
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            Task { for await _ in NotificationCenter.default.notifications(named: name) { rules.engine.reevaluate() } }
        }
        // A permission may have been changed in System Settings while uawake was in the background.
        Task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                rules.refreshPermissions()
            }
        }
        if rulesFixture { RulesFixture.load(into: rules, sessions: engine) }
        // Posted for every in-process change, including @AppStorage writes from Settings.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                engine.apply(settings)
                rules.engine.reevaluate()  // The guard policy may have changed.
                self?.registerShortcut()
            }
        }
        hotKey.onPress = { [weak self] in self?.popover.toggle() }
        registerShortcut()
    }

    func open(_ url: URL) {
        URLRouter.route(
            url, to: engine, defaultCondition: settings.primaryClickAction, defaultModes: settings.sessionModes)
    }

    /// Ends every session with `.appQuit` so history (from 1.2) records why.
    func quit() {
        // Freeze the rules first, or they would restart the sessions ended here.
        rules.handle(.userSessionDidResignActive)
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
