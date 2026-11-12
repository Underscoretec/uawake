import Foundation

/// Every 0.1 setting, stored in `UserDefaults` under the stable keys documented in
/// `docs/SETTINGS.md`. Plain property-list types only, so an MDM profile can set and
/// lock them from 1.3. Out-of-range values (from a profile or `defaults write`) are
/// clamped on read; values of the wrong type read as the default.
///
/// SwiftUI binds with `@AppStorage(SettingsKey.x.rawValue)`; the defaults are registered
/// in `init`, so both paths agree.
public struct UAwakeSettings {
    public let defaults: UserDefaults

    public static let defaultPresets = ["15m", "30m", "1h", "2h", "5h", "indefinite"]
    public static let maximumPresetCount = 12

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            SettingsKey.batteryGuardEnabled.rawValue: true,
            SettingsKey.batteryGuardThreshold.rawValue: 20,
            SettingsKey.lowPowerModeGuardEnabled.rawValue: true,
            SettingsKey.thermalGuardEnabled.rawValue: true,
            SettingsKey.maximumCapEnabled.rawValue: true,
            SettingsKey.maximumCapHours.rawValue: 24,
            SettingsKey.durationPresets.rawValue: Self.defaultPresets,
            SettingsKey.primaryClickAction.rawValue: "indefinite",
            SettingsKey.endWarningMinutes.rawValue: 5,
            SettingsKey.showsCountdown.rawValue: false,
            SettingsKey.preventSleepOnPower.rawValue: false,
            SettingsKey.allowDisplaySleep.rawValue: false,
            SettingsKey.updateChannel.rawValue: UpdateChannel.stable.rawValue,
            SettingsKey.iconStyle.rawValue: IconStyle.uawake.rawValue,
            SettingsKey.firstRunCompleted.rawValue: false,
            SettingsKey.watermarkEnabled.rawValue: false,
            SettingsKey.watermarkStyle.rawValue: WatermarkStyle.centred.rawValue,
            SettingsKey.watermarkTextColour.rawValue: "blue",
            SettingsKey.watermarkTimerColour.rawValue: "blue",
            SettingsKey.watermarkOpacity.rawValue: 12,
            SettingsKey.watermarkSize.rawValue: WatermarkSize.medium.rawValue,
            SettingsKey.watermarkHiddenFromCapture.rawValue: true,
            SettingsKey.watermarkHiddenInFullScreen.rawValue: true,
            SettingsKey.watermarkDrifts.rawValue: true,
        ])
    }

    /// True when an MDM profile forces this key (1.3 shows "Managed by your organisation").
    public func isManaged(_ key: SettingsKey) -> Bool {
        defaults.objectIsForced(forKey: key.rawValue)
    }

    // MARK: Rules

    /// "Pause all rules", kept across relaunches. `RulesPaused` without a
    /// `RulesPausedUntil` date means until resumed.
    public var rulesPause: RulePause? {
        get {
            guard bool(.rulesPaused, default: false) else { return nil }
            return (defaults.object(forKey: SettingsKey.rulesPausedUntil.rawValue) as? Date).map { .until($0) }
                ?? .indefinitely
        }
        nonmutating set {
            set(newValue != nil, .rulesPaused)
            if case .until(let date) = newValue {
                set(date, .rulesPausedUntil)
            } else {
                defaults.removeObject(forKey: SettingsKey.rulesPausedUntil.rawValue)
            }
        }
    }

    // MARK: Safety

    public var batteryGuardEnabled: Bool {
        get { bool(.batteryGuardEnabled, default: true) }
        nonmutating set { set(newValue, .batteryGuardEnabled) }
    }

    /// 5–95 %.
    public var batteryGuardThreshold: Int {
        get { int(.batteryGuardThreshold, default: 20, in: 5...95) }
        nonmutating set { set(newValue.clamped(to: 5...95), .batteryGuardThreshold) }
    }

    public var lowPowerModeGuardEnabled: Bool {
        get { bool(.lowPowerModeGuardEnabled, default: true) }
        nonmutating set { set(newValue, .lowPowerModeGuardEnabled) }
    }

    public var thermalGuardEnabled: Bool {
        get { bool(.thermalGuardEnabled, default: true) }
        nonmutating set { set(newValue, .thermalGuardEnabled) }
    }

    public var maximumCapEnabled: Bool {
        get { bool(.maximumCapEnabled, default: true) }
        nonmutating set { set(newValue, .maximumCapEnabled) }
    }

    /// 1–72 h.
    public var maximumCapHours: Int {
        get { int(.maximumCapHours, default: 24, in: 1...72) }
        nonmutating set { set(newValue.clamped(to: 1...72), .maximumCapHours) }
    }

    /// The engine's guard policy, built from the safety settings.
    public var policy: GuardPolicy {
        var policy = GuardPolicy()
        policy.batteryThreshold = batteryGuardEnabled ? batteryGuardThreshold : nil
        policy.endOnLowPowerMode = lowPowerModeGuardEnabled
        policy.endOnThermalPressure = thermalGuardEnabled
        policy.maximumCap = maximumCapEnabled ? .seconds(maximumCapHours * 3600) : nil
        return policy
    }

    // MARK: General and notifications

    /// The default session for the primary click and `uawake://toggle`: a preset.
    public var primaryClickAction: EndCondition {
        get {
            (defaults.string(forKey: SettingsKey.primaryClickAction.rawValue)).flatMap(EndCondition.init(presetText:))
                ?? .indefinite
        }
        nonmutating set { if let text = newValue.presetText { set(text, .primaryClickAction) } }
    }

    /// Minutes before a timed session ends to warn; 0 turns the warning off. 0–60.
    public var endWarningMinutes: Int {
        get { int(.endWarningMinutes, default: 5, in: 0...60) }
        nonmutating set { set(newValue.clamped(to: 0...60), .endWarningMinutes) }
    }

    public var endWarning: Duration? {
        endWarningMinutes > 0 ? .seconds(endWarningMinutes * 60) : nil
    }

    /// "On the power adapter, prevent all sleep" (`caffeinate -s`). Off by default.
    public var preventSleepOnPower: Bool {
        get { bool(.preventSleepOnPower, default: false) }
        nonmutating set { set(newValue, .preventSleepOnPower) }
    }

    /// "Allow the display to sleep during sessions". Off by default: manual and URL
    /// sessions keep the display awake too.
    public var allowDisplaySleep: Bool {
        get { bool(.allowDisplaySleep, default: false) }
        nonmutating set { set(newValue, .allowDisplaySleep) }
    }

    /// Modes for manual and URL sessions (unless a URL sets `display=`).
    public var sessionModes: Set<AwakeMode> {
        allowDisplaySleep ? [.system] : [.system, .display]
    }

    // MARK: Appearance and updates

    public var showsCountdown: Bool {
        get { bool(.showsCountdown, default: false) }
        nonmutating set { set(newValue, .showsCountdown) }
    }

    public var iconStyle: IconStyle {
        get { defaults.string(forKey: SettingsKey.iconStyle.rawValue).flatMap(IconStyle.init) ?? .uawake }
        nonmutating set { set(newValue.rawValue, .iconStyle) }
    }

    /// `nil` when no shortcut is set (the default).
    public var globalShortcut: GlobalShortcut? {
        get { shortcut(.globalShortcutKeyCode, .globalShortcutModifiers) }
        nonmutating set { setShortcut(newValue, .globalShortcutKeyCode, .globalShortcutModifiers) }
    }

    /// Shows or hides the watermark. `nil` when not set (the default).
    public var watermarkShortcut: GlobalShortcut? {
        get { shortcut(.watermarkShortcutKeyCode, .watermarkShortcutModifiers) }
        nonmutating set { setShortcut(newValue, .watermarkShortcutKeyCode, .watermarkShortcutModifiers) }
    }

    private func shortcut(_ keyCodeKey: SettingsKey, _ modifiersKey: SettingsKey) -> GlobalShortcut? {
        guard let keyCode = defaults.object(forKey: keyCodeKey.rawValue) as? Int,
            let modifiers = defaults.object(forKey: modifiersKey.rawValue) as? Int,
            (0...0xFFFF).contains(keyCode), modifiers > 0
        else { return nil }
        return GlobalShortcut(keyCode: keyCode, carbonModifiers: modifiers)
    }

    private func setShortcut(_ shortcut: GlobalShortcut?, _ keyCodeKey: SettingsKey, _ modifiersKey: SettingsKey) {
        if let shortcut {
            set(shortcut.keyCode, keyCodeKey)
            set(shortcut.carbonModifiers, modifiersKey)
        } else {
            defaults.removeObject(forKey: keyCodeKey.rawValue)
            defaults.removeObject(forKey: modifiersKey.rawValue)
        }
    }

    /// Set when the welcome window is dismissed. An MDM profile can force it to skip first run.
    public var firstRunCompleted: Bool {
        get { bool(.firstRunCompleted, default: false) }
        nonmutating set { set(newValue, .firstRunCompleted) }
    }

    public var updateChannel: UpdateChannel {
        get { defaults.string(forKey: SettingsKey.updateChannel.rawValue).flatMap(UpdateChannel.init) ?? .stable }
        nonmutating set { set(newValue.rawValue, .updateChannel) }
    }

    // MARK: Watermark

    /// "Show watermark on screen" (Appearance). Off by default.
    public var watermarkEnabled: Bool {
        get { bool(.watermarkEnabled, default: false) }
        nonmutating set { set(newValue, .watermarkEnabled) }
    }

    public var watermarkStyle: WatermarkStyle {
        get { defaults.string(forKey: SettingsKey.watermarkStyle.rawValue).flatMap(WatermarkStyle.init) ?? .centred }
        nonmutating set { set(newValue.rawValue, .watermarkStyle) }
    }

    /// A preset name (`blue`, `amber`, `green`, `red`, `white`) or `#RRGGBB`. Anything else reads as `blue`.
    public var watermarkTextColour: String {
        get { colour(.watermarkTextColour) }
        nonmutating set { set(newValue, .watermarkTextColour) }
    }

    public var watermarkTimerColour: String {
        get { colour(.watermarkTimerColour) }
        nonmutating set { set(newValue, .watermarkTimerColour) }
    }

    /// 5–40 %.
    public var watermarkOpacity: Int {
        get { int(.watermarkOpacity, default: 12, in: 5...40) }
        nonmutating set { set(newValue.clamped(to: 5...40), .watermarkOpacity) }
    }

    public var watermarkSize: WatermarkSize {
        get { defaults.string(forKey: SettingsKey.watermarkSize.rawValue).flatMap(WatermarkSize.init) ?? .medium }
        nonmutating set { set(newValue.rawValue, .watermarkSize) }
    }

    /// Hidden from screen sharing, screenshots and recordings. On by default.
    public var watermarkHiddenFromCapture: Bool {
        get { bool(.watermarkHiddenFromCapture, default: true) }
        nonmutating set { set(newValue, .watermarkHiddenFromCapture) }
    }

    /// Hidden while presenting or when a full-screen app is in front. On by default.
    public var watermarkHiddenInFullScreen: Bool {
        get { bool(.watermarkHiddenInFullScreen, default: true) }
        nonmutating set { set(newValue, .watermarkHiddenInFullScreen) }
    }

    /// The centred watermark moves a little every few minutes. On by default; Reduce Motion stops it.
    public var watermarkDrifts: Bool {
        get { bool(.watermarkDrifts, default: true) }
        nonmutating set { set(newValue, .watermarkDrifts) }
    }

    /// The preset names a colour setting accepts besides `#RRGGBB`.
    public static let watermarkColourPresets = ["blue", "amber", "green", "red", "white"]

    /// `#RRGGBB` as 0xRRGGBB, or `nil` for anything else.
    public static func hexColour(_ text: String) -> UInt32? {
        guard text.count == 7, text.first == "#", let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return value
    }

    private func colour(_ key: SettingsKey) -> String {
        let text = defaults.string(forKey: key.rawValue) ?? "blue"
        return Self.watermarkColourPresets.contains(text) || Self.hexColour(text) != nil ? text : "blue"
    }

    // MARK: Presets

    /// Durations and `indefinite`, in display order. Unreadable entries are skipped.
    public var presets: [EndCondition] {
        get {
            let texts = defaults.stringArray(forKey: SettingsKey.durationPresets.rawValue) ?? Self.defaultPresets
            return texts.compactMap(EndCondition.init(presetText:))
        }
        nonmutating set { set(newValue.compactMap(\.presetText), .durationPresets) }
    }

    public func addPreset(_ preset: EndCondition) throws(PresetError) {
        var list = presets
        try validate(preset, in: list)
        guard list.count < Self.maximumPresetCount else { throw .tooMany }
        list.append(preset)
        presets = list
    }

    public func replacePreset(at index: Int, with preset: EndCondition) throws(PresetError) {
        var list = presets
        guard list.indices.contains(index) else { throw .indexOutOfRange }
        if list[index] == preset { return }
        try validate(preset, in: list)
        list[index] = preset
        presets = list
    }

    public func removePreset(at index: Int) throws(PresetError) {
        var list = presets
        guard list.indices.contains(index) else { throw .indexOutOfRange }
        list.remove(at: index)
        presets = list
    }

    /// Moves the preset at `source` so it ends up at index `destination`.
    public func movePreset(from source: Int, to destination: Int) throws(PresetError) {
        var list = presets
        guard list.indices.contains(source), list.indices.contains(destination) else { throw .indexOutOfRange }
        list.insert(list.remove(at: source), at: destination)
        presets = list
    }

    public func resetPresets() {
        defaults.removeObject(forKey: SettingsKey.durationPresets.rawValue)
    }

    private func validate(_ preset: EndCondition, in list: [EndCondition]) throws(PresetError) {
        guard preset.presetText != nil else { throw .unsupported }
        guard !list.contains(preset) else { throw .duplicate }
    }

    // MARK: Storage

    private func bool(_ key: SettingsKey, default fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    private func int(_ key: SettingsKey, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        (defaults.object(forKey: key.rawValue) as? Int ?? fallback).clamped(to: range)
    }

    private func set(_ value: Any, _ key: SettingsKey) {
        defaults.set(value, forKey: key.rawValue)
    }
}

/// The documented `UserDefaults` keys. Renaming one breaks MDM profiles: add, never rename.
public enum SettingsKey: String, CaseIterable, Sendable {
    case batteryGuardEnabled = "BatteryGuardEnabled"
    case batteryGuardThreshold = "BatteryGuardThreshold"
    case lowPowerModeGuardEnabled = "LowPowerModeGuardEnabled"
    case thermalGuardEnabled = "ThermalGuardEnabled"
    case maximumCapEnabled = "MaximumCapEnabled"
    case maximumCapHours = "MaximumCapHours"
    case durationPresets = "DurationPresets"
    case primaryClickAction = "PrimaryClickAction"
    case endWarningMinutes = "EndWarningMinutes"
    case showsCountdown = "ShowsCountdown"
    case updateChannel = "UpdateChannel"
    case iconStyle = "IconStyle"
    case globalShortcutKeyCode = "GlobalShortcutKeyCode"
    case globalShortcutModifiers = "GlobalShortcutModifiers"
    case firstRunCompleted = "FirstRunCompleted"
    case rulesPaused = "RulesPaused"
    case rulesPausedUntil = "RulesPausedUntil"
    case preventSleepOnPower = "PreventSleepOnPower"
    case allowDisplaySleep = "AllowDisplaySleep"
    case watermarkEnabled = "WatermarkEnabled"
    case watermarkStyle = "WatermarkStyle"
    case watermarkTextColour = "WatermarkTextColour"
    case watermarkTimerColour = "WatermarkTimerColour"
    case watermarkOpacity = "WatermarkOpacity"
    case watermarkSize = "WatermarkSize"
    case watermarkHiddenFromCapture = "WatermarkHiddenFromCapture"
    case watermarkHiddenInFullScreen = "WatermarkHiddenInFullScreen"
    case watermarkDrifts = "WatermarkDrifts"
    case watermarkShortcutKeyCode = "WatermarkShortcutKeyCode"
    case watermarkShortcutModifiers = "WatermarkShortcutModifiers"
}

/// The on-screen watermark's layout: one large label (with drift), text tiled diagonally,
/// or a label bouncing around the screen.
public enum WatermarkStyle: String, CaseIterable, Sendable {
    case centred, tiled, bouncing
}

public enum WatermarkSize: String, CaseIterable, Sendable {
    case small, medium, large
}

/// Menu bar icon family. The app maps each to an active and an inactive image: the uawake
/// cup from the asset catalog, the others SF Symbols.
public enum IconStyle: String, CaseIterable, Sendable {
    case uawake, cup, eye, bolt
}

/// A global shortcut as a virtual key code and a Carbon modifier mask
/// (`cmdKey | optionKey | controlKey | shiftKey`). At least one modifier.
public struct GlobalShortcut: Hashable, Sendable {
    public let keyCode: Int
    public let carbonModifiers: Int

    public init(keyCode: Int, carbonModifiers: Int) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}

public enum UpdateChannel: String, CaseIterable, Sendable {
    case stable, beta
}

public enum PresetError: Error, Equatable, Sendable {
    /// Presets hold durations and `indefinite` only.
    case unsupported
    case duplicate
    case tooMany
    case indexOutOfRange
}

extension DefaultSessionEngine {
    /// Applies the current settings to running sessions: guard policy (cap and guards
    /// re-evaluated) and the end-warning lead time. Call on every settings change.
    public func apply(_ settings: UAwakeSettings) {
        policy = settings.policy
        endWarning = settings.endWarning
        preventsSleepOnPower = settings.preventSleepOnPower
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
