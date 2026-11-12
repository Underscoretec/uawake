import Foundation
import Testing
import UAwakeCoreTesting

@testable import UAwakeCore

@MainActor
struct SettingsTests {
    let suite = "uawake-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: UAwakeSettings

    init() {
        defaults = UserDefaults(suiteName: suite)!
        settings = UAwakeSettings(defaults: defaults)
    }

    @Test func rulesPauseSurvivesARelaunch() {
        #expect(settings.rulesPause == nil)
        let until = Date(timeIntervalSinceReferenceDate: 1000)
        settings.rulesPause = .until(until)
        #expect(UAwakeSettings(defaults: defaults).rulesPause == .until(until))
        #expect(defaults.bool(forKey: "RulesPaused"))
        settings.rulesPause = .indefinitely
        #expect(UAwakeSettings(defaults: defaults).rulesPause == .indefinitely)
        #expect(defaults.object(forKey: "RulesPausedUntil") == nil)
        settings.rulesPause = nil
        #expect(UAwakeSettings(defaults: defaults).rulesPause == nil)
    }

    @Test func defaultsMatchTheSpec() {
        #expect(settings.policy == GuardPolicy())
        #expect(settings.policy.batteryThreshold == 20)
        #expect(settings.policy.maximumCap == .seconds(24 * 3600))
        #expect(
            settings.presets == [
                .duration(.seconds(900)), .duration(.seconds(1800)), .duration(.seconds(3600)),
                .duration(.seconds(7200)), .duration(.seconds(18000)), .indefinite,
            ])
        #expect(settings.primaryClickAction == .indefinite)
        #expect(settings.endWarning == .seconds(300))
        #expect(settings.showsCountdown == false)
        #expect(settings.preventSleepOnPower == false)
        #expect(settings.updateChannel == .stable)
        #expect(!settings.isManaged(.batteryGuardThreshold))
    }

    @Test func keysAreStable() {
        #expect(
            SettingsKey.allCases.map(\.rawValue) == [
                "BatteryGuardEnabled", "BatteryGuardThreshold", "LowPowerModeGuardEnabled", "ThermalGuardEnabled",
                "MaximumCapEnabled", "MaximumCapHours", "DurationPresets", "PrimaryClickAction", "EndWarningMinutes",
                "ShowsCountdown", "UpdateChannel", "IconStyle", "GlobalShortcutKeyCode", "GlobalShortcutModifiers",
                "FirstRunCompleted", "RulesPaused", "RulesPausedUntil", "PreventSleepOnPower",
            ])
    }

    @Test func outOfRangeAndWrongTypeValuesAreSafe() {
        defaults.set(200, forKey: "BatteryGuardThreshold")
        defaults.set(0, forKey: "MaximumCapHours")
        defaults.set("lots", forKey: "EndWarningMinutes")
        defaults.set("yes", forKey: "ThermalGuardEnabled")
        defaults.set("2 days", forKey: "PrimaryClickAction")
        defaults.set("nightly", forKey: "UpdateChannel")
        #expect(settings.batteryGuardThreshold == 95)
        #expect(settings.maximumCapHours == 1)
        #expect(settings.endWarningMinutes == 5)
        #expect(settings.thermalGuardEnabled)
        #expect(settings.primaryClickAction == .indefinite)
        #expect(settings.updateChannel == .stable)
        settings.batteryGuardThreshold = 1
        #expect(defaults.integer(forKey: "BatteryGuardThreshold") == 5)
    }

    @Test func policyFollowsSafetySettings() {
        settings.batteryGuardEnabled = false
        settings.lowPowerModeGuardEnabled = false
        settings.thermalGuardEnabled = false
        settings.maximumCapHours = 2
        #expect(settings.policy.batteryThreshold == nil)
        #expect(!settings.policy.endOnLowPowerMode)
        #expect(!settings.policy.endOnThermalPressure)
        #expect(settings.policy.maximumCap == .seconds(7200))
        settings.maximumCapEnabled = false
        #expect(settings.policy.maximumCap == nil)
        settings.endWarningMinutes = 0
        #expect(settings.endWarning == nil)
    }

    @Test func otherSettingsRoundTrip() {
        settings.primaryClickAction = .duration(.seconds(5400))
        #expect(defaults.string(forKey: "PrimaryClickAction") == "1h30m")
        #expect(settings.primaryClickAction == .duration(.seconds(5400)))
        settings.primaryClickAction = .batteryLevel(10)  // Not a preset: ignored.
        #expect(settings.primaryClickAction == .duration(.seconds(5400)))
        settings.showsCountdown = true
        settings.updateChannel = .beta
        #expect(settings.showsCountdown)
        #expect(defaults.string(forKey: "UpdateChannel") == "beta")
    }

    @Test func appearanceShortcutAndFirstRun() {
        #expect(settings.iconStyle == .uawake)
        #expect(settings.globalShortcut == nil)
        #expect(!settings.firstRunCompleted)
        settings.iconStyle = .bolt
        settings.globalShortcut = GlobalShortcut(keyCode: 32, carbonModifiers: 0x1900)
        settings.firstRunCompleted = true
        #expect(defaults.string(forKey: "IconStyle") == "bolt")
        #expect(settings.globalShortcut == GlobalShortcut(keyCode: 32, carbonModifiers: 0x1900))
        #expect(settings.firstRunCompleted)
        defaults.set(0, forKey: "GlobalShortcutModifiers")  // No modifier: unusable.
        #expect(settings.globalShortcut == nil)
        settings.globalShortcut = nil
        #expect(defaults.object(forKey: "GlobalShortcutKeyCode") == nil)
        defaults.set("rainbow", forKey: "IconStyle")
        #expect(settings.iconStyle == .uawake)
    }

    // MARK: Presets

    @Test func addEditRemoveReorderPresets() throws {
        try settings.addPreset(.duration(.seconds(2700)))
        #expect(settings.presets.last == .duration(.seconds(2700)))
        #expect(defaults.stringArray(forKey: "DurationPresets")?.last == "45m")
        try settings.replacePreset(at: 0, with: .duration(.seconds(600)))
        #expect(settings.presets.first == .duration(.seconds(600)))
        try settings.replacePreset(at: 0, with: .duration(.seconds(600)))  // Same value: no-op.
        try settings.removePreset(at: 1)
        #expect(settings.presets.count == 6)
        try settings.movePreset(from: 5, to: 0)
        #expect(settings.presets.first == .duration(.seconds(2700)))
        settings.resetPresets()
        #expect(settings.presets.count == 6)
        #expect(settings.presets.first == .duration(.seconds(900)))
    }

    @Test func presetValidation() throws {
        #expect(throws: PresetError.duplicate) { try settings.addPreset(.indefinite) }
        #expect(throws: PresetError.unsupported) { try settings.addPreset(.batteryLevel(30)) }
        #expect(throws: PresetError.unsupported) {
            try settings.addPreset(.until(ClockTime(hour: 18, minute: 30)!))
        }
        #expect(throws: PresetError.duplicate) { try settings.replacePreset(at: 0, with: .indefinite) }
        #expect(throws: PresetError.indexOutOfRange) { try settings.removePreset(at: 6) }
        #expect(throws: PresetError.indexOutOfRange) { try settings.replacePreset(at: -1, with: .indefinite) }
        #expect(throws: PresetError.indexOutOfRange) { try settings.movePreset(from: 0, to: 9) }
        for minutes in 1...6 { try settings.addPreset(.duration(.seconds(minutes * 60))) }
        #expect(throws: PresetError.tooMany) { try settings.addPreset(.duration(.seconds(7 * 60))) }
    }

    @Test func unreadablePresetsAreSkipped() {
        defaults.set(["10m", "soon", "until 18:30", "indefinite"], forKey: "DurationPresets")
        #expect(settings.presets == [.duration(.seconds(600)), .indefinite])
    }

    // MARK: Applying to the engine

    @Test func settingsChangesApplyToRunningSessions() async throws {
        let clock = FakeClock()
        let engine = DefaultSessionEngine(
            assertions: FakeAssertionProvider(), clock: clock, guards: DefaultSessionEngine.standardGuards)
        engine.apply(settings)
        #expect(engine.endWarning == .seconds(300))
        try engine.start(SessionRequest(source: .manual, reason: .custom("Test"), endCondition: .indefinite))
        clock.advance(by: 3 * 3600)
        settings.maximumCapHours = 2
        engine.apply(settings)
        #expect(engine.sessions.isEmpty)
    }

    @Test func durationText() {
        #expect(DurationText.parse("1h30m") == .seconds(5400))
        #expect(DurationText.parse("45s") == .seconds(45))
        for bad in ["", "0", "0m", "30m1h", "1h1h", "1.5h", "-5m", "9999999h", "90"] {
            #expect(DurationText.parse(bad) == nil, "\(bad)")
        }
        #expect(DurationText.format(.seconds(5400)) == "1h30m")
        #expect(DurationText.format(.seconds(3723)) == "1h2m3s")
        #expect(DurationText.format(.zero) == "0s")
        #expect(EndCondition(presetText: "indefinite") == .indefinite)
        #expect(EndCondition.until(ClockTime(hour: 1, minute: 2)!).presetText == nil)
    }
}
