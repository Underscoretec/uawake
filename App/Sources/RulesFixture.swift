import UAwakeCore
import UAwakeSystem

/// A fixed set of rules and signals for screenshots and UI tests (`-UITestRules`), so the
/// Rules section shows the same states on any Mac. No system monitor runs.
@MainActor
enum RulesFixture {
    struct Permissions: PermissionProvider {
        func status(_ permission: RulePermission) -> PermissionStatus {
            permission == .location ? .denied : .granted
        }

        func request(_ permission: RulePermission) async -> PermissionStatus { status(permission) }
    }

    static let permissions: any PermissionProvider = Permissions()

    static func load(into rules: RulesModel, sessions: any SessionEngine) {
        var templates = RulesModel.templates.map(\.rule)
        // Presenting and Building match, On a call does not, Downloading is off and the
        // office rule needs Location, which the fixture denies.
        templates[3].enabled = false
        // No active hours here: the fixture must look the same at any time of day.
        templates[4].conditions = [.powerAdapter, .wifi(ssid: "Office")]
        for rule in templates { rules.save(rule) }
        rules.engine.update(
            .apps(
                AppsState(
                    running: ["com.apple.iWork.Keynote", "com.apple.dt.Xcode", "com.apple.finder"],
                    frontmost: "com.apple.iWork.Keynote")))
        rules.engine.update(.mediaUse(MediaUse(cameraInUse: false, microphoneInUse: false)))
        rules.engine.update(
            .load(LoadSample(cpuPercent: 34, bytesInPerSecond: 240_000, bytesOutPerSecond: 12_000, interval: 60)))
    }
}
