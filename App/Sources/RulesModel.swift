import AppKit
import UAwakeCore
import UAwakeSystem
import os

enum PauseChoice: CaseIterable {
    case oneHour, untilTomorrow, untilResumed
}

/// A starter rule offered in the Rules section. Templates open in the editor as drafts;
/// none is installed automatically.
struct RuleTemplate: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let rule: Rule
}

/// Owns the rules: the file, the rule engine, the monitors it needs and permissions.
@MainActor
@Observable
final class RulesModel {
    let engine: RuleEngine
    /// Why the rules file could not be used as it is, if so.
    private(set) var problem: RuleStore.Problem?
    /// The last change could not be written to disk; it is still in effect until quit.
    private(set) var saveFailed = false
    /// Rules in the file that this version can't read. They are kept, never run.
    private(set) var unsupportedCount: Int

    /// Screenshots: open the editor on the first rule, on this tab, when the Rules section appears.
    enum UITestEditor: String { case edit, test }
    @ObservationIgnored var uiTestEditor: UITestEditor?

    @ObservationIgnored private var document: RuleDocument
    @ObservationIgnored private let store: RuleStore
    @ObservationIgnored private let settings: UAwakeSettings
    @ObservationIgnored private let permissions: any PermissionProvider
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private var hub: SignalHub?

    /// `monitors: nil` runs no system monitors: tests and screenshots feed signals themselves.
    init(
        sessions: any SessionEngine, clock: any SessionClock, settings: UAwakeSettings, store: RuleStore,
        permissions: any PermissionProvider, monitors: [SignalKind: SignalHub.Source]? = SignalHub.systemSources
    ) {
        let loaded = store.load(now: clock.now)
        document = loaded.document
        problem = loaded.problem
        unsupportedCount = loaded.document.unsupported.count
        self.store = store
        self.settings = settings
        self.permissions = permissions
        self.clock = clock
        engine = RuleEngine(engine: sessions, clock: clock, rules: loaded.document.rules, pause: settings.rulesPause)
        if case .corrupt(let path) = loaded.problem {
            AppModel.logger.error("rules.json was not readable; moved to \(path ?? "nowhere", privacy: .public)")
        }
        refreshPermissions()
        if let monitors {
            let engine = engine
            hub = SignalHub(sources: monitors, deliver: { engine.update($0) }, stopped: { engine.reset($0) })
            syncMonitors()
        }
    }

    var rules: [Rule] { engine.rules }

    /// A file from a newer uawake must not be written over.
    var isReadOnly: Bool {
        if case .newerVersion = problem { true } else { false }
    }

    var matchingCount: Int {
        engine.statuses.values.count {
            if case .matching = $0 { true } else if case .lingering = $0 { true } else { false }
        }
    }

    func status(of rule: Rule) -> RuleStatus { engine.statuses[rule.id] ?? .off }

    // MARK: Editing

    /// Adds the rule, or replaces the one with the same id.
    func save(_ rule: Rule) {
        guard !isReadOnly, rule.isValid else { return }
        if let index = document.rules.firstIndex(where: { $0.id == rule.id }) {
            document.rules[index] = rule
        } else {
            document.rules.append(rule)
        }
        commit()
    }

    func delete(_ id: Rule.ID) {
        guard !isReadOnly else { return }
        document.rules.removeAll { $0.id == id }
        commit()
    }

    func setEnabled(_ enabled: Bool, for id: Rule.ID) {
        guard !isReadOnly, let index = document.rules.firstIndex(where: { $0.id == id }),
            document.rules[index].enabled != enabled
        else { return }
        document.rules[index].enabled = enabled
        commit()
    }

    /// `base`, or `base 2`, `base 3`… so that rule names stay unique.
    func uniqueName(_ base: String, excluding id: Rule.ID? = nil) -> String {
        let taken = Set(document.rules.filter { $0.id != id }.map(\.name))
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
    }

    private func commit() {
        engine.setRules(document.rules)
        do {
            try store.save(document)
            saveFailed = false
        } catch {
            saveFailed = true
            AppModel.logger.error("Saving rules failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Pause

    func pause(_ choice: PauseChoice) {
        let pause: RulePause =
            switch choice {
            case .oneHour: .until(clock.now + 3600)
            case .untilTomorrow: .untilTomorrowMorning(from: clock.now, calendar: .current)
            case .untilResumed: .indefinitely
            }
        engine.setPause(pause)
        settings.rulesPause = pause
    }

    func resume() {
        engine.setPause(nil)
        settings.rulesPause = nil
    }

    // MARK: Permissions

    func permissionStatus(_ permission: RulePermission) -> PermissionStatus {
        engine.permissions[permission] ?? .notDetermined
    }

    /// Shows the system prompt if the permission has never been asked for.
    func request(_ permission: RulePermission) async {
        _ = await permissions.request(permission)
        refreshPermissions()
        // A monitor created before the grant reads nothing; start it afresh.
        hub?.restart(permission.signal)
    }

    func refreshPermissions() {
        engine.permissions = Dictionary(
            uniqueKeysWithValues: RulePermission.allCases.map { ($0, permissions.status($0)) })
    }

    // MARK: App events

    func handle(_ event: SessionEvent) { engine.handle(event) }

    func handle(_ event: SessionLifecycleEvent) {
        engine.handle(event)
        if event == .systemDidWake { hub?.restart(.calendar) }
    }

    func apply(_ state: DeviceState) { engine.update(.power(state)) }

    /// Keeps the running monitors equal to what the rules (and the editor's draft) need,
    /// re-arming itself whenever that set changes.
    private func syncMonitors() {
        let needed = withObservationTracking {
            engine.neededSignals
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncMonitors() }
        }
        hub?.setNeeded(needed)
    }

    // MARK: Templates

    static var templates: [RuleTemplate] {
        func app(_ bundleID: String, _ name: String) -> AppRef { AppRef(bundleID: bundleID, name: name) }
        return [
            RuleTemplate(
                id: "presenting",
                title: String(localized: "Presenting", comment: "Rule template name"),
                detail: String(localized: "Keynote or PowerPoint is in front", comment: "Rule template description"),
                symbol: "play.rectangle.fill",
                rule: Rule(
                    name: String(localized: "Presenting", comment: "Rule template name"), match: .any,
                    conditions: [
                        .appFrontmost(app("com.apple.iWork.Keynote", "Keynote")),
                        .appFrontmost(app("com.microsoft.Powerpoint", "PowerPoint")),
                    ], modes: [.system, .display])),
            RuleTemplate(
                id: "call",
                title: String(localized: "On a call", comment: "Rule template name"),
                detail: String(localized: "The camera or microphone is in use", comment: "Rule template description"),
                symbol: "video.fill",
                rule: Rule(
                    name: String(localized: "On a call", comment: "Rule template name"), match: .any,
                    conditions: [.call(camera: true, microphone: true)], modes: [.system, .display])),
            RuleTemplate(
                id: "building",
                title: String(localized: "Building", comment: "Rule template name"),
                detail: String(
                    localized: "Xcode is open, or the processor is busy", comment: "Rule template description"),
                symbol: "hammer.fill",
                rule: Rule(
                    name: String(localized: "Building", comment: "Rule template name"), match: .any,
                    conditions: [
                        .appRunning(app("com.apple.dt.Xcode", "Xcode")), .cpuBusy(percent: 50, windowSeconds: 60),
                    ])),
            RuleTemplate(
                id: "downloading",
                title: String(localized: "Downloading", comment: "Rule template name"),
                detail: String(localized: "The network is busy downloading", comment: "Rule template description"),
                symbol: "arrow.down.circle.fill",
                rule: Rule(
                    name: String(localized: "Downloading", comment: "Rule template name"),
                    conditions: [.networkBusy(bytesPerSecond: 1_000_000, direction: .download, windowSeconds: 60)])),
            RuleTemplate(
                id: "office",
                title: String(localized: "Plugged in at the office", comment: "Rule template name"),
                detail: String(
                    localized: "On power and on a Wi-Fi network you choose", comment: "Rule template description"),
                symbol: "building.2.fill",
                rule: Rule(
                    name: String(localized: "Plugged in at the office", comment: "Rule template name"),
                    conditions: [.powerAdapter, .wifi(ssid: "")])),
        ]
    }
}

extension RulePermission {
    /// The monitor that needs this permission.
    var signal: SignalKind {
        switch self {
        case .bluetooth: .bluetoothDevices
        case .location: .wifi
        case .calendar: .calendar
        }
    }
}
