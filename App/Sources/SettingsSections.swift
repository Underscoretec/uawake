import SwiftUI
import UAwakeCore

struct GeneralSettingsView: View {
    /// Shared with the rule editor's option of the same name.
    static let onPowerHelp = String(
        localized:
            "While your Mac is on the power adapter, sessions also stop it sleeping on its own, like caffeinate -s. On battery, they go back to normal. Closing the lid still sleeps your Mac unless an external display is connected.",
        comment: "Settings and rule editor: help for “On the power adapter, prevent all sleep”")

    let model: AppModel
    @State private var launchesAtLogin = false
    @State private var shortcut: GlobalShortcut?
    @State private var shortcutProblem: String?
    @AppStorage(SettingsKey.primaryClickAction.rawValue) private var primaryClickAction = "indefinite"
    @AppStorage(SettingsKey.preventSleepOnPower.rawValue) private var preventSleepOnPower = false
    @AppStorage(SettingsKey.allowDisplaySleep.rawValue) private var allowDisplaySleep = false

    var body: some View {
        Form {
            Toggle("Open uawake at login", isOn: $launchesAtLogin)
                .onChange(of: launchesAtLogin) { _, enabled in
                    if enabled != model.launchesAtLogin { model.setLaunchesAtLogin(enabled) }
                }
            Picker("Click the menu bar icon to keep awake for", selection: $primaryClickAction) {
                ForEach(model.settings.presets, id: \.self) { preset in
                    Text(preset.chipTitle).tag(preset.presetText ?? "indefinite")
                }
            }
            LabeledContent("Shortcut to turn uawake on or off") {
                VStack(alignment: .trailing) {
                    ShortcutRecorder(shortcut: $shortcut)
                    if let shortcutProblem {
                        Text(shortcutProblem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .onChange(of: shortcut) { _, new in shortcutProblem = model.setShortcut(new) }
            Section {
                Toggle("Allow the display to sleep during sessions", isOn: $allowDisplaySleep)
            } footer: {
                Text("Sessions you start keep the screen on unless this is on. Rules choose for themselves.")
            }
            Section {
                Toggle("On the power adapter, prevent all sleep", isOn: $preventSleepOnPower)
            } footer: {
                Text(Self.onPowerHelp)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchesAtLogin = model.launchesAtLogin
            shortcut = model.settings.globalShortcut
        }
    }
}

struct DurationsSettingsView: View {
    let settings: UAwakeSettings
    @State private var presets: [EndCondition] = []
    @State private var text = ""
    @State private var editing: Int?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                ForEach(Array(presets.enumerated()), id: \.element) { index, preset in
                    HStack {
                        Text(preset.chipTitle)
                        Spacer()
                        Button("Edit") {
                            editing = index
                            text = preset.presetText ?? ""
                        }
                        .accessibilityLabel(Text("Edit \(preset.chipTitle)"))
                        Button {
                            run { () throws(PresetError) in try settings.movePreset(from: index, to: index - 1) }
                        } label: {
                            Label("Move Up", systemImage: "chevron.up")
                        }
                        .disabled(index == 0)
                        .accessibilityLabel(Text("Move \(preset.chipTitle) up"))
                        Button {
                            run { () throws(PresetError) in try settings.movePreset(from: index, to: index + 1) }
                        } label: {
                            Label("Move Down", systemImage: "chevron.down")
                        }
                        .disabled(index == presets.count - 1)
                        .accessibilityLabel(Text("Move \(preset.chipTitle) down"))
                        Button {
                            run { () throws(PresetError) in try settings.removePreset(at: index) }
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                        .accessibilityLabel(Text("Remove \(preset.chipTitle)"))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Presets")
            } footer: {
                Button("Restore Defaults") { run { () throws(PresetError) in settings.resetPresets() } }
            }
            Section {
                HStack {
                    TextField(
                        editing == nil ? "Add a duration" : "Change duration", text: $text,
                        prompt: Text("e.g. 45m, 1h30m or indefinite")
                    )
                    .onSubmit(save)
                    Button(editing == nil ? "Add" : "Save", action: save)
                        .disabled(text.isEmpty)
                    if editing != nil {
                        Button("Cancel") {
                            editing = nil
                            text = ""
                        }
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { presets = settings.presets }
    }

    private func save() {
        guard let preset = EndCondition(presetText: text.trimmingCharacters(in: .whitespaces).lowercased()) else {
            problem = String(
                localized: "Use hours, minutes and seconds in that order, like 45m or 1h30m.",
                comment: "Durations settings: invalid entry")
            return
        }
        run { () throws(PresetError) in
            if let editing {
                try settings.replacePreset(at: editing, with: preset)
            } else {
                try settings.addPreset(preset)
            }
            editing = nil
            text = ""
        }
    }

    private func run(_ change: () throws(PresetError) -> Void) {
        do {
            try change()
            problem = nil
        } catch {
            problem = error.localizedMessage
        }
        presets = settings.presets
    }
}

struct SafetySettingsView: View {
    @AppStorage(SettingsKey.batteryGuardEnabled.rawValue) private var batteryEnabled = true
    @AppStorage(SettingsKey.batteryGuardThreshold.rawValue) private var batteryThreshold = 20
    @AppStorage(SettingsKey.lowPowerModeGuardEnabled.rawValue) private var lowPowerMode = true
    @AppStorage(SettingsKey.thermalGuardEnabled.rawValue) private var thermal = true
    @AppStorage(SettingsKey.maximumCapEnabled.rawValue) private var capEnabled = true
    @AppStorage(SettingsKey.maximumCapHours.rawValue) private var capHours = 24
    @AppStorage(SettingsKey.endWarningMinutes.rawValue) private var warningMinutes = 5

    var body: some View {
        Form {
            Section {
                Toggle("Stop at low battery", isOn: $batteryEnabled)
                Stepper(value: $batteryThreshold, in: 5...95, step: 5) {
                    Text("Battery limit: \(batteryThreshold)%")
                }
                .disabled(!batteryEnabled)
                Toggle("Stop when Low Power Mode turns on", isOn: $lowPowerMode)
                Toggle("Stop when your Mac gets too warm", isOn: $thermal)
            } footer: {
                Text("The battery limit applies only on battery power.")
            }
            Section {
                Toggle("Limit sessions without an end time", isOn: $capEnabled)
                Stepper(value: $capHours, in: 1...72) {
                    Text("Maximum: \(capHours) hours")
                }
                .disabled(!capEnabled)
            } footer: {
                Text("Applies to indefinite and battery-level sessions, counted from when they start.")
            }
            Section {
                Stepper(value: $warningMinutes, in: 0...60) {
                    if warningMinutes == 0 {
                        Text("Warn before a session ends: off")
                    } else {
                        Text("Warn \(warningMinutes) min before a session ends")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettingsView: View {
    let model: AppModel
    @AppStorage(SettingsKey.iconStyle.rawValue) private var iconStyle = IconStyle.uawake.rawValue
    @AppStorage(SettingsKey.showsCountdown.rawValue) private var showsCountdown = false
    @AppStorage(SettingsKey.watermarkEnabled.rawValue) private var watermark = false
    @AppStorage(SettingsKey.watermarkStyle.rawValue) private var style = WatermarkStyle.centred.rawValue
    @AppStorage(SettingsKey.watermarkTextColour.rawValue) private var textColour = "blue"
    @AppStorage(SettingsKey.watermarkTimerColour.rawValue) private var timerColour = "blue"
    @AppStorage(SettingsKey.watermarkOpacity.rawValue) private var opacity = 12
    @AppStorage(SettingsKey.watermarkSize.rawValue) private var size = WatermarkSize.medium.rawValue
    @AppStorage(SettingsKey.watermarkHiddenFromCapture.rawValue) private var hiddenFromCapture = true
    @AppStorage(SettingsKey.watermarkHiddenInFullScreen.rawValue) private var hiddenInFullScreen = true
    @AppStorage(SettingsKey.watermarkDrifts.rawValue) private var drifts = true
    @State private var shortcut: GlobalShortcut?
    @State private var shortcutProblem: String?

    var body: some View {
        Form {
            Section {
                Picker("Menu bar icon", selection: $iconStyle) {
                    ForEach(IconStyle.allCases, id: \.self) { style in
                        Label {
                            Text(style.localizedName)
                        } icon: {
                            Image(nsImage: StatusItemController.symbolImage(style: style, active: true))
                                .renderingMode(.template)
                        }
                        .tag(style.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Show remaining time in the menu bar", isOn: $showsCountdown)
            }
            Section {
                Toggle("Show watermark on screen", isOn: $watermark)
                Group {
                    Picker("Style", selection: $style) {
                        Text("Centred").tag(WatermarkStyle.centred.rawValue)
                        Text("Tiled").tag(WatermarkStyle.tiled.rawValue)
                        Text("Bouncing").tag(WatermarkStyle.bouncing.rawValue)
                    }
                    .pickerStyle(.segmented)
                    WatermarkColourPicker(title: "Text colour", value: $textColour)
                    WatermarkColourPicker(title: "Timer colour", value: $timerColour)
                    LabeledContent("Opacity: \(opacity)%") {
                        Slider(
                            value: Binding(get: { Double(opacity) }, set: { opacity = Int($0.rounded()) }), in: 5...40,
                            step: 1)
                    }
                    Picker("Size", selection: $size) {
                        Text("Small").tag(WatermarkSize.small.rawValue)
                        Text("Medium").tag(WatermarkSize.medium.rawValue)
                        Text("Large").tag(WatermarkSize.large.rawValue)
                    }
                    Toggle("Hide from screen sharing, screenshots and recordings", isOn: $hiddenFromCapture)
                    Toggle("Hide while presenting or when a full-screen app is in front", isOn: $hiddenInFullScreen)
                    Toggle("Drift slowly (centred style)", isOn: $drifts)
                        .disabled(style != WatermarkStyle.centred.rawValue)
                }
                .disabled(!watermark)
                LabeledContent("Shortcut to show or hide the watermark") {
                    VStack(alignment: .trailing) {
                        ShortcutRecorder(shortcut: $shortcut)
                        if let shortcutProblem {
                            Text(shortcutProblem).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .onChange(of: shortcut) { _, new in shortcutProblem = model.setWatermarkShortcut(new) }
            } header: {
                Text("Watermark")
            } footer: {
                Text(
                    "Shows that your Mac is being kept awake, on every display, while a session is active. Clicks pass through it. Reduce Motion turns drift and bouncing off."
                )
            }
        }
        .formStyle(.grouped)
        .onAppear { shortcut = model.settings.watermarkShortcut }
    }
}

/// A watermark colour: a preset, or Custom with a colour well. Stored as a preset name or `#RRGGBB`.
private struct WatermarkColourPicker: View {
    let title: LocalizedStringKey
    @Binding var value: String

    var body: some View {
        HStack {
            Picker(
                title,
                selection: Binding(
                    get: { value.hasPrefix("#") ? "custom" : value },
                    set: {
                        value = $0 == "custom" ? WatermarkController.hexText(WatermarkController.colour(value)) : $0
                    })
            ) {
                ForEach(WatermarkController.colourPresets, id: \.value) { preset in
                    Text(preset.name).tag(preset.value)
                }
                Text("Custom").tag("custom")
            }
            if value.hasPrefix("#") {
                ColorPicker(
                    title,
                    selection: Binding(
                        get: { WatermarkController.colour(value) }, set: { value = WatermarkController.hexText($0) }),
                    supportsOpacity: false
                )
                .labelsHidden()
            }
        }
    }
}

struct AboutView: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        VStack(spacing: 8) {
            // The catalog image draws at once; applicationIconImage can show IconServices'
            // grid placeholder until its async render finishes.
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("uawake — keep your Mac awake").font(.headline)
            Text("Version \(version) (\(build))")
            Text("Created by Abhijit Roy · Underscore Technology")
            Text("Free and open source under the MIT licence.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct UpdatesSettingsView: View {
    let updates: UpdatesModel
    @AppStorage(SettingsKey.updateChannel.rawValue) private var channel = UpdateChannel.stable.rawValue
    @State private var automaticallyChecks = false

    var body: some View {
        Form {
            if !updates.isConfigured {
                Label {
                    Text("Updates aren't set up in this build. Release builds check for updates automatically.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(Color.secondaryText)
            }
            Toggle("Check for updates automatically", isOn: $automaticallyChecks)
                .onChange(of: automaticallyChecks) { _, value in updates.automaticallyChecks = value }
            Picker("Update channel", selection: $channel) {
                Text("Stable").tag(UpdateChannel.stable.rawValue)
                Text("Beta").tag(UpdateChannel.beta.rawValue)
            }
            LabeledContent("Last checked") {
                if let date = updates.lastCheck {
                    Text(date, format: .dateTime)
                } else {
                    Text("Never")
                }
            }
            Button("Check for Updates…", action: updates.checkForUpdates)
        }
        .formStyle(.grouped)
        .disabled(!updates.isConfigured)
        .onAppear { automaticallyChecks = updates.automaticallyChecks }
    }
}
