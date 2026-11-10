import AppKit
import SwiftUI
import UAwakeCore
import UAwakeSystem
import UniformTypeIdentifiers

/// One condition in the rule editor: its title, a remove button, the permission note if
/// access is missing, and the controls for its parameters.
struct ConditionRowView: View {
    let model: RulesModel
    @Binding var condition: Condition
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(condition.kind.title, systemImage: condition.kind.symbol)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: remove) {
                    Label("Remove Condition", systemImage: "minus.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove condition: \(description)"))
            }
            if let permission = condition.permission, model.permissionStatus(permission) != .granted {
                PermissionNote(model: model, permission: permission)
            }
            ConditionControls(model: model, condition: $condition)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var description: String { condition.isComplete ? condition.summary : condition.kind.title }
}

private struct ConditionControls: View {
    let model: RulesModel
    @Binding var condition: Condition

    var body: some View {
        switch condition {
        case .appRunning(let app):
            AppPicker(app: app) { condition = .appRunning($0) }
        case .appFrontmost(let app):
            AppPicker(app: app) { condition = .appFrontmost($0) }
        case .call(let camera, let microphone):
            Toggle(
                "Camera", isOn: Binding(get: { camera }, set: { condition = .call(camera: $0, microphone: microphone) })
            )
            .disabled(camera && !microphone)
            Toggle(
                "Microphone",
                isOn: Binding(get: { microphone }, set: { condition = .call(camera: camera, microphone: $0) })
            )
            .disabled(microphone && !camera)
            Caption("Also true while dictation or a recording uses the microphone.")
        case .audioPlaying:
            Caption("True while an app has audio output running, even if it is silent.")
        case .cpuBusy(let percent, let window):
            CPUControls(percent: percent, window: window) { condition = .cpuBusy(percent: $0, windowSeconds: $1) }
        case .networkBusy(let rate, let direction, let window):
            NetworkControls(rate: rate, direction: direction, window: window) {
                condition = .networkBusy(bytesPerSecond: $0, direction: $1, windowSeconds: $2)
            }
        case .powerAdapter:
            EmptyView()
        case .externalDisplay(let name):
            DisplayPicker(name: name) { condition = .externalDisplay(name: $0) }
        case .device(let kind, let id, let name):
            DevicePicker(model: model, kind: kind, id: id, name: name) {
                condition = .device(kind: $0, id: $1, name: $2)
            }
        case .wifi(let ssid):
            WiFiField(model: model, ssid: ssid) { condition = .wifi(ssid: $0) }
        case .calendarEvent(let calendarID, let calendarName, let keyword):
            CalendarControls(model: model, calendarID: calendarID, calendarName: calendarName, keyword: keyword) {
                condition = .calendarEvent(calendarID: $0, calendarName: $1, keyword: $2)
            }
        case .schedule(let window):
            WeeklyWindowEditor(window: Binding(get: { window }, set: { condition = .schedule($0) }))
        }
    }
}

private struct Caption: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(Color.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Apps

private struct AppPicker: View {
    let app: AppRef
    let set: (AppRef) -> Void

    var body: some View {
        Menu {
            ForEach(runningApps, id: \.bundleID) { candidate in
                Button {
                    set(candidate)
                } label: {
                    if let icon = Self.icon(for: candidate.bundleID) {
                        Label {
                            Text(verbatim: candidate.name)
                        } icon: {
                            Image(nsImage: icon)
                        }
                    } else {
                        Text(verbatim: candidate.name)
                    }
                }
            }
            Divider()
            Button("Other…", action: chooseOther)
        } label: {
            HStack {
                if let icon = Self.icon(for: app.bundleID) {
                    Image(nsImage: icon).accessibilityHidden(true)
                }
                if app.bundleID.isEmpty {
                    Text("Choose an App")
                } else {
                    Text(verbatim: app.name)
                }
            }
        }
        .fixedSize()
        .accessibilityLabel(Text("App"))
        .accessibilityValue(app.bundleID.isEmpty ? Text("None chosen") : Text(verbatim: app.name))
    }

    /// Regular apps running now, one per bundle id, by name.
    private var runningApps: [AppRef] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { running in
                guard let id = running.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return AppRef(bundleID: id, name: running.localizedName ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func icon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let image = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        let display = FileManager.default.displayName(atPath: url.path)
        set(AppRef(bundleID: id, name: display.hasSuffix(".app") ? String(display.dropLast(4)) : display))
    }
}

// MARK: - Load

private struct CPUControls: View {
    let percent: Int
    let window: Int
    let set: (Int, Int) -> Void

    var body: some View {
        let text = RuleText.percent(Double(percent))
        HStack {
            Slider(
                value: Binding(get: { Double(percent) }, set: { set(Int($0.rounded()), window) }),
                in: Double(Condition.percentRange.lowerBound)...Double(Condition.percentRange.upperBound), step: 5
            ) {
                Text("Above")
            }
            .accessibilityLabel(Text("Processor threshold"))
            .accessibilityValue(Text(verbatim: text))
            Text(verbatim: text).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
        DurationPicker(
            title: String(localized: "For at least", comment: "Rule editor: averaging window"),
            seconds: Binding(get: { window }, set: { set(percent, $0) }), options: DurationPicker.windowOptions)
    }
}

private struct NetworkControls: View {
    let rate: Int
    let direction: NetworkDirection
    let window: Int
    let set: (Int, NetworkDirection, Int) -> Void

    var body: some View {
        let text = RuleText.rate(Double(rate))
        Picker("Direction", selection: Binding(get: { direction }, set: { set(rate, $0, window) })) {
            Text("Download").tag(NetworkDirection.download)
            Text("Upload").tag(NetworkDirection.upload)
            Text("Both").tag(NetworkDirection.both)
        }
        .pickerStyle(.segmented)
        HStack {
            // log10: 100 kB/s (5) to 100 MB/s (8).
            Slider(
                value: Binding(get: { log10(Double(max(rate, 1))) }, set: { set(Self.rounded($0), direction, window) }),
                in: 5...8
            ) {
                Text("Above")
            }
            .accessibilityLabel(Text("Network threshold"))
            .accessibilityValue(Text(verbatim: text))
            Text(verbatim: text).monospacedDigit().frame(minWidth: 80, alignment: .trailing)
                .accessibilityHidden(true)
        }
        DurationPicker(
            title: String(localized: "For at least", comment: "Rule editor: averaging window"),
            seconds: Binding(get: { window }, set: { set(rate, direction, $0) }), options: DurationPicker.windowOptions)
    }

    /// 10^exponent, rounded to two significant figures (1.2 MB/s, 35 MB/s).
    private static func rounded(_ exponent: Double) -> Int {
        let value = pow(10, exponent)
        let unit = pow(10, floor(log10(value)) - 1)
        return Int((value / unit).rounded() * unit)
    }
}

/// A picker of durations; the current value is listed even when it is not one of the options.
struct DurationPicker: View {
    static let windowOptions = [30, 60, 120, 300, 600]

    let title: String
    @Binding var seconds: Int
    let options: [Int]

    var body: some View {
        Picker(title, selection: $seconds) {
            ForEach(Set(options + [seconds]).sorted(), id: \.self) { value in
                Text(verbatim: RuleText.window(value)).tag(value)
            }
        }
    }
}

// MARK: - Devices

private struct DisplayPicker: View {
    let name: String?
    let set: (String?) -> Void
    @State private var connected: [String] = []

    var body: some View {
        Picker("Display", selection: Binding(get: { name }, set: { set($0) })) {
            Text("Any display").tag(String?.none)
            ForEach(names, id: \.self) { display in
                Text(verbatim: display).tag(String?.some(display))
            }
        }
        .onAppear { connected = SystemDisplayMonitor.read().filter { !$0.isBuiltIn }.map(\.name) }
    }

    private var names: [String] {
        guard let name, !connected.contains(name) else { return connected }
        return connected + [name]
    }
}

private struct DevicePicker: View {
    let model: RulesModel
    let kind: DeviceKind
    let id: String
    let name: String
    let set: (DeviceKind, String, String) -> Void
    @State private var devices: [ConnectedDevice] = []

    var body: some View {
        Picker("Connection", selection: Binding(get: { kind }, set: { set($0, "", "") })) {
            Text("USB").tag(DeviceKind.usb)
            Text("Bluetooth").tag(DeviceKind.bluetooth)
        }
        .pickerStyle(.segmented)
        // Reload when the type changes or Bluetooth access arrives.
        .task(id: kind == .bluetooth ? (bluetoothGranted ? 2 : 1) : 0) { reload() }
        Menu {
            ForEach(devices, id: \.id) { device in
                Button {
                    set(kind, device.id, device.name)
                } label: {
                    Text(verbatim: device.name)
                }
            }
        } label: {
            if id.isEmpty {
                Text("Choose a Device")
            } else {
                Text(verbatim: name)
            }
        }
        .fixedSize()
        .disabled(devices.isEmpty)
        .accessibilityLabel(Text("Device"))
        .accessibilityValue(id.isEmpty ? Text("None chosen") : Text(verbatim: name))
        if devices.isEmpty {
            Caption("No devices found. Connect it, then choose it here.")
        }
    }

    private var bluetoothGranted: Bool { model.permissionStatus(.bluetooth) == .granted }

    private func reload() {
        switch kind {
        case .usb: devices = SystemUSBMonitor.read()
        // Reading paired devices before access is granted would show the system prompt.
        case .bluetooth: devices = bluetoothGranted ? SystemBluetoothMonitor.pairedDevices() : []
        }
    }
}

private struct WiFiField: View {
    let model: RulesModel
    let ssid: String
    let set: (String) -> Void
    @State private var current: String?

    var body: some View {
        TextField("Network name", text: Binding(get: { ssid }, set: { set($0) }))
            .task(id: model.permissionStatus(.location)) { current = SystemWiFiMonitor.read() }
        if let current, current != ssid {
            Button("Use “\(current)”") { set(current) }
        }
    }
}

private struct CalendarControls: View {
    let model: RulesModel
    let calendarID: String?
    let calendarName: String?
    let keyword: String?
    let set: (String?, String?, String?) -> Void
    @State private var calendars: [CalendarInfo] = []

    var body: some View {
        Picker("Calendar", selection: Binding(get: { calendarID }, set: { choose($0) })) {
            Text("Any calendar").tag(String?.none)
            ForEach(calendars, id: \.id) { calendar in
                Text(verbatim: calendar.title).tag(String?.some(calendar.id))
            }
            if let calendarID, !calendars.contains(where: { $0.id == calendarID }) {
                Text(verbatim: calendarName ?? calendarID).tag(String?.some(calendarID))
            }
        }
        .task(id: model.permissionStatus(.calendar)) { calendars = SystemCalendarMonitor.calendars() }
        TextField(
            "Title contains (optional)",
            text: Binding(
                get: { keyword ?? "" },
                set: { set(calendarID, calendarName, $0.isEmpty ? nil : $0) }))
        Caption("All-day, declined and free events are ignored.")
    }

    private func choose(_ id: String?) {
        let name =
            id.flatMap { id in calendars.first { $0.id == id }?.title } ?? (id == calendarID ? calendarName : nil)
        set(id, name, keyword)
    }
}

// MARK: - Schedule

/// Weekday chips and start and end times; used by the Schedule condition and active hours.
struct WeeklyWindowEditor: View {
    @Binding var window: WeeklyWindow

    /// The days in the order of the user's week.
    private var days: [Weekday] {
        let sundayFirst: [Weekday] = [.sun, .mon, .tue, .wed, .thu, .fri, .sat]
        let first = Calendar.current.firstWeekday - 1
        return Array(sundayFirst[first...] + sundayFirst[..<first])
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let selected = window.days.contains(day)
                Button {
                    if selected { window.days.remove(day) } else { window.days.insert(day) }
                } label: {
                    Text(verbatim: day.shortName)
                }
                .buttonStyle(PillButtonStyle(selected: selected, compact: true))
                .accessibilityLabel(Text(verbatim: day.fullName))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        DatePicker("Starts", selection: time(\.start), displayedComponents: .hourAndMinute)
        DatePicker("Ends", selection: time(\.end), displayedComponents: .hourAndMinute)
        Caption("\(window.summary). An end time before the start runs past midnight.")
    }

    private func time(_ keyPath: WritableKeyPath<WeeklyWindow, ClockTime>) -> Binding<Date> {
        Binding(
            get: {
                let time = window[keyPath: keyPath]
                let today = Calendar.current.startOfDay(for: .now)
                return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: today)
                    ?? today
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                window[keyPath: keyPath] = ClockTime(clampingHour: parts.hour ?? 0, minute: parts.minute ?? 0)
            })
    }
}

// MARK: - Permissions

/// Shown above a condition's controls while its permission is missing.
private struct PermissionNote: View {
    let model: RulesModel
    let permission: RulePermission

    var body: some View {
        let denied = model.permissionStatus(permission) == .denied
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: denied ? "exclamationmark.triangle.fill" : "lock.fill")
                .foregroundStyle(denied ? Tone.caution.color : Color(nsColor: Palette.blue))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(permission.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                if denied {
                    Text("The rule stays off until access is allowed.")
                        .font(.callout).foregroundStyle(Color.secondaryText)
                }
                PermissionActionButton(model: model, permission: permission, firstAskTitle: .continue)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .card(radius: 10, tint: denied ? Tone.caution.color : Color(nsColor: Palette.blue))
        .accessibilityElement(children: .contain)
    }
}

/// "Continue" / "Grant Access" (shows the system prompt) before the first ask, otherwise
/// "Open System Settings". The only places uawake requests a permission.
struct PermissionActionButton: View {
    enum FirstAskTitle { case `continue`, grantAccess }

    let model: RulesModel
    let permission: RulePermission
    let firstAskTitle: FirstAskTitle
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if model.permissionStatus(permission) == .notDetermined {
                Button {
                    Task { await model.request(permission) }
                } label: {
                    switch firstAskTitle {
                    case .continue: Text("Continue")
                    case .grantAccess: Text("Grant Access")
                    }
                }
                .accessibilityLabel(Text("Allow \(permission.name) access"))
            } else {
                Button("Open System Settings") {
                    if let url = permission.settingsURL { openURL(url) }
                }
                .accessibilityLabel(Text("Open System Settings for \(permission.name) access"))
            }
        }
        .buttonStyle(PillButtonStyle(compact: true))
    }
}
