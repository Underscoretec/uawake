import Foundation
import UAwakeCore

// Localized text for rules: condition summaries, status pills, readings and permissions.
// Everything a user reads about a rule comes from here, so the list, the editor, the Test
// view and the popover say the same thing.

struct RuleStatusPill: Equatable {
    let text: String
    let symbol: String
    let tone: Tone
}

extension ConditionKind {
    var title: String {
        switch self {
        case .appRunning: String(localized: "App is open", comment: "Condition type")
        case .appFrontmost: String(localized: "App is in front", comment: "Condition type")
        case .call: String(localized: "Call in progress", comment: "Condition type")
        case .audioPlaying: String(localized: "Audio is playing", comment: "Condition type")
        case .cpuBusy: String(localized: "Processor is busy", comment: "Condition type")
        case .networkBusy: String(localized: "Network is busy", comment: "Condition type")
        case .powerAdapter: String(localized: "Power adapter connected", comment: "Condition type")
        case .externalDisplay: String(localized: "External display connected", comment: "Condition type")
        case .device: String(localized: "USB or Bluetooth device connected", comment: "Condition type")
        case .wifi: String(localized: "On a Wi-Fi network", comment: "Condition type")
        case .calendarEvent: String(localized: "Calendar event in progress", comment: "Condition type")
        case .schedule: String(localized: "Schedule", comment: "Condition type")
        }
    }

    var symbol: String {
        switch self {
        case .appRunning: "app.badge.checkmark"
        case .appFrontmost: "macwindow"
        case .call: "video.fill"
        case .audioPlaying: "speaker.wave.2.fill"
        case .cpuBusy: "cpu.fill"
        case .networkBusy: "arrow.up.arrow.down"
        case .powerAdapter: "powerplug.fill"
        case .externalDisplay: "display"
        case .device: "cable.connector"
        case .wifi: "wifi"
        case .calendarEvent: "calendar"
        case .schedule: "clock.fill"
        }
    }

    /// A new, possibly incomplete, row for the editor.
    var blank: Condition {
        switch self {
        case .appRunning: .appRunning(AppRef(bundleID: "", name: ""))
        case .appFrontmost: .appFrontmost(AppRef(bundleID: "", name: ""))
        case .call: .call(camera: true, microphone: true)
        case .audioPlaying: .audioPlaying
        case .cpuBusy: .cpuBusy(percent: 50, windowSeconds: 60)
        case .networkBusy: .networkBusy(bytesPerSecond: 1_000_000, direction: .download, windowSeconds: 60)
        case .powerAdapter: .powerAdapter
        case .externalDisplay: .externalDisplay(name: nil)
        case .device: .device(kind: .usb, id: "", name: "")
        case .wifi: .wifi(ssid: "")
        case .calendarEvent: .calendarEvent(calendarID: nil, calendarName: nil, keyword: nil)
        case .schedule: .schedule(.workHours)
        }
    }
}

extension WeeklyWindow {
    /// Weekdays 9:00–19:00, the spec's example.
    static var workHours: WeeklyWindow {
        WeeklyWindow(
            days: Weekday.workdays, start: ClockTime(clampingHour: 9, minute: 0),
            end: ClockTime(clampingHour: 19, minute: 0))
    }

    /// "Weekdays 9:00–19:00", "Mon, Wed 22:00–2:00", "Every day, all day".
    var summary: String {
        let dayText: String
        if days.count == 7 {
            dayText = String(localized: "Every day", comment: "Schedule days")
        } else if days == Weekday.workdays {
            dayText = String(localized: "Weekdays", comment: "Schedule days")
        } else if days == [.sat, .sun] {
            dayText = String(localized: "Weekends", comment: "Schedule days")
        } else {
            dayText = Weekday.allCases.filter(days.contains).map(\.shortName).formatted(
                .list(type: .and, width: .narrow))
        }
        if start == end {
            return String(localized: "\(dayText), all day", comment: "Schedule: days, whole day")
        }
        return String(
            localized: "\(dayText) \(start.localizedText)–\(end.localizedText)", comment: "Schedule: days, start–end")
    }
}

extension Weekday {
    /// 1 = Sunday, as `Calendar` numbers them.
    var calendarIndex: Int { [.sun, .mon, .tue, .wed, .thu, .fri, .sat].firstIndex(of: self) ?? 0 }

    var shortName: String { Calendar.current.shortWeekdaySymbols[calendarIndex] }

    var fullName: String { Calendar.current.weekdaySymbols[calendarIndex] }
}

extension ClockTime {
    /// The time in the user's format, e.g. "9:00" or "9:00 AM".
    var localizedText: String {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute))?
            .formatted(date: .omitted, time: .shortened) ?? text
    }
}

enum RuleText {
    /// "1 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let bytes = Int64(bytesPerSecond).formatted(.byteCount(style: .decimal))
        return String(localized: "\(bytes)/s", comment: "Network rate, e.g. 1 MB/s")
    }

    /// "1 min", "30 sec".
    static func window(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

extension Condition {
    /// One line saying when the condition is met, e.g. "Keynote is in front".
    var summary: String {
        switch self {
        case .appRunning(let app):
            return String(localized: "\(app.name) is open", comment: "Condition summary")
        case .appFrontmost(let app):
            return String(localized: "\(app.name) is in front", comment: "Condition summary")
        case .call(let camera, let microphone):
            if camera && microphone {
                return String(localized: "Camera or microphone in use", comment: "Condition summary")
            }
            return camera
                ? String(localized: "Camera in use", comment: "Condition summary")
                : String(localized: "Microphone in use", comment: "Condition summary")
        case .audioPlaying:
            return String(localized: "Audio is playing", comment: "Condition summary")
        case .cpuBusy(let percent, let window):
            return String(
                localized: "Processor above \(RuleText.percent(Double(percent))) for \(RuleText.window(window))",
                comment: "Condition summary: CPU above 50% for 1 min")
        case .networkBusy(let rate, let direction, let window):
            let amount = RuleText.rate(Double(rate))
            let time = RuleText.window(window)
            switch direction {
            case .download:
                return String(localized: "Downloading above \(amount) for \(time)", comment: "Condition summary")
            case .upload:
                return String(localized: "Uploading above \(amount) for \(time)", comment: "Condition summary")
            case .both:
                return String(localized: "Network above \(amount) for \(time)", comment: "Condition summary")
            }
        case .powerAdapter:
            return String(localized: "Power adapter connected", comment: "Condition summary")
        case .externalDisplay(let name):
            return name.map { String(localized: "\($0) connected", comment: "Condition summary: a named display") }
                ?? String(localized: "External display connected", comment: "Condition summary")
        case .device(_, _, let name):
            return String(localized: "\(name) connected", comment: "Condition summary: a named device")
        case .wifi(let ssid):
            return String(localized: "On Wi-Fi “\(ssid)”", comment: "Condition summary")
        case .calendarEvent(_, let calendar, let keyword):
            switch (calendar, keyword) {
            case (nil, nil):
                return String(localized: "Calendar event in progress", comment: "Condition summary")
            case (let calendar?, nil):
                return String(localized: "Event in “\(calendar)” in progress", comment: "Condition summary")
            case (nil, let keyword?):
                return String(localized: "Event matching “\(keyword)” in progress", comment: "Condition summary")
            case (let calendar?, let keyword?):
                return String(
                    localized: "Event in “\(calendar)” matching “\(keyword)” in progress", comment: "Condition summary")
            }
        case .schedule(let window):
            return window.summary
        }
    }
}

extension Rule {
    /// "Any of: Keynote is in front, PowerPoint is in front · Display awake · Weekdays 9:00–19:00".
    var summary: String {
        let list = conditions.map(\.summary).formatted(.list(type: .and, width: .narrow))
        var parts: [String]
        if conditions.count < 2 {
            parts = [list]
        } else if match == .all {
            parts = [String(localized: "All of: \(list)", comment: "Rule summary")]
        } else {
            parts = [String(localized: "Any of: \(list)", comment: "Rule summary")]
        }
        if modes.contains(.display) { parts.append(String(localized: "Display awake", comment: "Rule summary")) }
        if let activeHours { parts.append(activeHours.summary) }
        return parts.joined(separator: " · ")
    }
}

extension RulePermission {
    var name: String {
        switch self {
        case .bluetooth: String(localized: "Bluetooth", comment: "Permission name")
        case .location: String(localized: "Location", comment: "Permission name")
        case .calendar: String(localized: "Calendar", comment: "Permission name")
        }
    }

    /// Why uawake asks, shown before the system prompt.
    var explanation: String {
        switch self {
        case .bluetooth:
            String(
                localized: "uawake needs Bluetooth access to see which of your devices are connected.",
                comment: "Permission explanation")
        case .location:
            String(
                localized:
                    "macOS only shares the Wi-Fi network name with apps that have Location access. uawake never reads where you are.",
                comment: "Permission explanation")
        case .calendar:
            String(
                localized:
                    "uawake needs Calendar access to know when an event is in progress. Events never leave your Mac.",
                comment: "Permission explanation")
        }
    }

    /// The matching pane of System Settings › Privacy & Security.
    var settingsURL: URL? {
        let pane =
            switch self {
            case .bluetooth: "Privacy_Bluetooth"
            case .location: "Privacy_LocationServices"
            case .calendar: "Privacy_Calendars"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

extension RuleStatus {
    @MainActor func pill(now: Date) -> RuleStatusPill {
        func left(_ date: Date) -> String { PopoverViewModel.countdownText(date.timeIntervalSince(now)) }
        switch self {
        case .off:
            return RuleStatusPill(
                text: String(localized: "Off", comment: "Rule status"), symbol: "power", tone: .neutral)
        case .paused:
            return RuleStatusPill(
                text: String(localized: "Paused", comment: "Rule status"), symbol: "pause.fill", tone: .neutral)
        case .idle:
            return RuleStatusPill(
                text: String(localized: "Not matching", comment: "Rule status"), symbol: "circle", tone: .neutral)
        case .outsideHours:
            return RuleStatusPill(
                text: String(localized: "Outside active hours", comment: "Rule status"), symbol: "clock", tone: .neutral
            )
        case .needsPermission(let permission):
            return RuleStatusPill(
                text: String(localized: "Needs \(permission.name)", comment: "Rule status: missing permission"),
                symbol: "exclamationmark.triangle.fill", tone: .caution)
        case .matching:
            return RuleStatusPill(
                text: String(localized: "Matching now", comment: "Rule status"), symbol: "checkmark.circle.fill",
                tone: .good)
        case .lingering(let until):
            return RuleStatusPill(
                text: String(localized: "Ends in \(left(until))", comment: "Rule status: linger countdown"),
                symbol: "hourglass", tone: .caution)
        case .stoppedByUser:
            return RuleStatusPill(
                text: String(localized: "Stopped by you", comment: "Rule status"), symbol: "stop.circle.fill",
                tone: .critical)
        case .waiting(_, let until?):
            return RuleStatusPill(
                text: String(localized: "Waiting: restarts in \(left(until))", comment: "Rule status: guard cool-down"),
                symbol: "timer", tone: .caution)
        case .waiting(let cause, nil):
            let text =
                switch cause {
                case .thermalGuard: String(localized: "Waiting: Mac cooling down", comment: "Rule status")
                case .lowPowerMode: String(localized: "Waiting: Low Power Mode is on", comment: "Rule status")
                default: String(localized: "Waiting: battery low", comment: "Rule status")
                }
            return RuleStatusPill(text: text, symbol: "exclamationmark.shield.fill", tone: .critical)
        case .failed:
            return RuleStatusPill(
                text: String(localized: "Couldn't keep awake", comment: "Rule status: assertion failed"),
                symbol: "xmark.octagon.fill", tone: .critical)
        }
    }

    /// Holding a session (matching or lingering).
    var isActive: Bool {
        switch self {
        case .matching, .lingering: true
        default: false
        }
    }
}

extension ConditionReading {
    /// The live value for the Test view, e.g. "Now 34% · needs 50%".
    func text(for condition: Condition) -> String {
        if case .unavailable(let permission) = state {
            return String(localized: "Needs \(permission.name) access", comment: "Test view: missing permission")
        }
        switch (condition, value) {
        case (.cpuBusy, .level(let current, let threshold)):
            guard let current else { return String(localized: "Measuring…", comment: "Test view: window not full") }
            return String(
                localized: "Now \(RuleText.percent(current)) · needs \(RuleText.percent(threshold))",
                comment: "Test view: CPU value against threshold")
        case (.networkBusy, .level(let current, let threshold)):
            guard let current else { return String(localized: "Measuring…", comment: "Test view: window not full") }
            return String(
                localized: "Now \(RuleText.rate(current)) · needs \(RuleText.rate(threshold))",
                comment: "Test view: network rate against threshold")
        case (.appFrontmost(let app), .text(let frontmost)):
            return frontmost == app.bundleID
                ? String(localized: "In front now", comment: "Test view")
                : String(localized: "Another app is in front", comment: "Test view")
        case (.wifi, .text(let ssid)):
            return ssid.map { String(localized: "Connected to “\($0)”", comment: "Test view: Wi-Fi") }
                ?? String(localized: "No Wi-Fi network name available", comment: "Test view: Wi-Fi")
        case (.call, .flag(let inUse)), (.audioPlaying, .flag(let inUse)):
            if state == .met { return String(localized: "In use now", comment: "Test view") }
            return inUse
                ? String(localized: "Just started…", comment: "Test view: settling")
                : String(localized: "Not in use", comment: "Test view")
        case (_, .names(let names)):
            return names.isEmpty
                ? String(localized: "None right now", comment: "Test view: empty list")
                : names.formatted(.list(type: .and, width: .narrow))
        default:
            return state == .met
                ? String(localized: "True now", comment: "Test view")
                : String(localized: "Not true now", comment: "Test view")
        }
    }
}

extension PauseChoice {
    var title: String {
        switch self {
        case .oneHour: String(localized: "For 1 hour", comment: "Pause all rules")
        case .untilTomorrow: String(localized: "Until tomorrow, 6:00", comment: "Pause all rules")
        case .untilResumed: String(localized: "Until I turn them back on", comment: "Pause all rules")
        }
    }
}

extension RulePause {
    /// "Rules paused until 15:30", "Rules paused until tomorrow, 6:00", "Rules paused".
    func text(now: Date, calendar: Calendar = .current) -> String {
        guard case .until(let date) = self else { return String(localized: "Rules paused", comment: "Pause banner") }
        let time = date.formatted(date: .omitted, time: .shortened)
        return calendar.isDate(date, inSameDayAs: now)
            ? String(localized: "Rules paused until \(time)", comment: "Pause banner")
            : String(localized: "Rules paused until tomorrow, \(time)", comment: "Pause banner")
    }
}
