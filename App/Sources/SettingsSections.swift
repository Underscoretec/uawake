import SwiftUI
import UAwakeCore

struct GeneralSettingsView: View {
    let model: AppModel
    @State private var launchesAtLogin = false
    @State private var shortcut: GlobalShortcut?
    @State private var shortcutProblem: String?
    @AppStorage(SettingsKey.primaryClickAction.rawValue) private var primaryClickAction = "indefinite"

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
    @AppStorage(SettingsKey.iconStyle.rawValue) private var iconStyle = IconStyle.cup.rawValue
    @AppStorage(SettingsKey.showsCountdown.rawValue) private var showsCountdown = false

    var body: some View {
        Form {
            Picker("Menu bar icon", selection: $iconStyle) {
                ForEach(IconStyle.allCases, id: \.self) { style in
                    Label(style.localizedName, systemImage: StatusItemController.symbols(style).active)
                        .tag(style.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            Toggle("Show remaining time in the menu bar", isOn: $showsCountdown)
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
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
