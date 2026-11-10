import Foundation

/// A smart trigger: while its conditions are met it holds one session with source
/// `.rule` and its name as the reason. Stored as JSON (`RuleStore`); the same
/// dictionary shape is used for import, export and MDM-provided rules from 1.3,
/// so it uses only property-list-compatible types.
public struct Rule: Identifiable, Equatable, Sendable, Codable {
    public static let defaultLinger = 120
    public static let lingerRange = 0...3600
    public static let maxNameLength = 64
    public static let maxConditions = 16

    public var id: UUID
    /// 1–64 characters. Appears in `pmset -g assertions` as `uawake: Rule: <name>`.
    public var name: String
    public var enabled: Bool
    public var match: MatchMode
    /// 1–16 conditions.
    public var conditions: [Condition]
    /// ``AwakeMode/system`` is always included.
    public var modes: Set<AwakeMode>
    /// Seconds the session is kept after the conditions stop being met.
    public var lingerSeconds: Int
    /// When set, the rule applies only inside this window.
    public var activeHours: WeeklyWindow?

    public init(
        id: UUID = UUID(), name: String, enabled: Bool = true, match: MatchMode = .all, conditions: [Condition],
        modes: Set<AwakeMode> = [.system], lingerSeconds: Int = Rule.defaultLinger, activeHours: WeeklyWindow? = nil
    ) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        self.enabled = enabled
        self.match = match
        self.conditions = Array(conditions.prefix(Self.maxConditions))
        self.modes = modes.union([.system])
        self.lingerSeconds = min(max(lingerSeconds, Self.lingerRange.lowerBound), Self.lingerRange.upperBound)
        self.activeHours = activeHours
    }

    /// A rule can run only with a name and at least one condition.
    public var isValid: Bool { !name.isEmpty && !conditions.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, match, conditions, modes, lingerSeconds, activeHours
    }

    /// Missing optional fields take their defaults and out-of-range values are clamped.
    /// A rule without a name or conditions, or with a condition this build does not know,
    /// fails to decode; ``RuleStore`` keeps such entries untouched.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            match: try container.decodeIfPresent(MatchMode.self, forKey: .match) ?? .all,
            conditions: try container.decode([Condition].self, forKey: .conditions),
            modes: Set(try container.decodeIfPresent([AwakeMode].self, forKey: .modes) ?? []),
            lingerSeconds: try container.decodeIfPresent(Int.self, forKey: .lingerSeconds) ?? Self.defaultLinger,
            activeHours: try container.decodeIfPresent(WeeklyWindow.self, forKey: .activeHours)
        )
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "A rule needs a name and at least one condition")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(match, forKey: .match)
        try container.encode(conditions, forKey: .conditions)
        try container.encode(AwakeMode.allCases.filter(modes.contains), forKey: .modes)
        try container.encode(lingerSeconds, forKey: .lingerSeconds)
        try container.encodeIfPresent(activeHours, forKey: .activeHours)
    }
}

public enum MatchMode: String, Codable, CaseIterable, Sendable {
    case all, any
}

/// An app, by bundle identifier. `name` is only for display.
public struct AppRef: Hashable, Sendable, Codable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum DeviceKind: String, Codable, CaseIterable, Sendable {
    case usb, bluetooth
}

public enum NetworkDirection: String, Codable, CaseIterable, Sendable {
    case download, upload, both
}

/// One thing a rule watches. Encoded as `{ "type": …, parameters }`.
public enum Condition: Hashable, Sendable {
    case appRunning(AppRef)
    case appFrontmost(AppRef)
    /// A camera or microphone is in use. At least one of the two is watched.
    case call(camera: Bool, microphone: Bool)
    case audioPlaying
    /// Whole-system CPU load averaged over the window.
    case cpuBusy(percent: Int, windowSeconds: Int)
    case networkBusy(bytesPerSecond: Int, direction: NetworkDirection, windowSeconds: Int)
    case powerAdapter
    /// Any external display, or one with this name.
    case externalDisplay(name: String?)
    /// `id` as in ``ConnectedDevice``.
    case device(kind: DeviceKind, id: String, name: String)
    case wifi(ssid: String)
    /// An event is in progress, optionally in one calendar and/or with a keyword in its title.
    case calendarEvent(calendarID: String?, calendarName: String?, keyword: String?)
    case schedule(WeeklyWindow)

    public static let percentRange = 10...100
    public static let windowRange = 30...600
    /// 10 kB/s to 1 GB/s.
    public static let rateRange = 10_000...1_000_000_000

    public var kind: ConditionKind {
        switch self {
        case .appRunning: .appRunning
        case .appFrontmost: .appFrontmost
        case .call: .call
        case .audioPlaying: .audioPlaying
        case .cpuBusy: .cpuBusy
        case .networkBusy: .networkBusy
        case .powerAdapter: .powerAdapter
        case .externalDisplay: .externalDisplay
        case .device: .device
        case .wifi: .wifi
        case .calendarEvent: .calendarEvent
        case .schedule: .schedule
        }
    }

    /// The monitor this condition reads; `nil` for the schedule, which only needs the clock.
    public var signal: SignalKind? {
        switch self {
        case .appRunning, .appFrontmost: .apps
        case .call: .mediaUse
        case .audioPlaying: .audioPlaying
        case .cpuBusy, .networkBusy: .load
        case .powerAdapter: .power
        case .externalDisplay: .displays
        case .device(let kind, _, _): kind == .usb ? .usbDevices : .bluetoothDevices
        case .wifi: .wifi
        case .calendarEvent: .calendar
        case .schedule: nil
        }
    }

    /// The privacy permission this condition needs, if any.
    public var permission: RulePermission? {
        switch self {
        case .device(.bluetooth, _, _): .bluetooth
        case .wifi: .location
        case .calendarEvent: .calendar
        default: nil
        }
    }

    /// Whether every parameter is filled in (the editor creates rows empty).
    public var isComplete: Bool {
        switch self {
        case .appRunning(let app), .appFrontmost(let app): !app.bundleID.isEmpty
        case .call(let camera, let microphone): camera || microphone
        case .device(_, let id, _): !id.isEmpty
        case .wifi(let ssid): !ssid.isEmpty
        case .schedule(let window): !window.days.isEmpty
        default: true
        }
    }
}

/// The 12 condition types of the 1.0 spec, in the order the editor lists them.
public enum ConditionKind: String, Codable, CaseIterable, Sendable {
    case appRunning, appFrontmost, call, audioPlaying, cpuBusy, networkBusy, powerAdapter, externalDisplay, device,
        wifi, calendarEvent, schedule
}

extension Condition: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, bundleID, name, camera, microphone, percent, windowSeconds, bytesPerSecond, direction, kind, id,
            ssid, calendarID, calendarName, keyword, window
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
            min(max(value, range.lowerBound), range.upperBound)
        }
        func window() throws -> Int {
            clamp(try container.decodeIfPresent(Int.self, forKey: .windowSeconds) ?? 60, Self.windowRange)
        }
        func app() throws -> AppRef {
            let bundleID = try container.decode(String.self, forKey: .bundleID)
            return AppRef(
                bundleID: bundleID, name: try container.decodeIfPresent(String.self, forKey: .name) ?? bundleID)
        }
        /// Empty optional strings mean "any".
        func optional(_ key: CodingKeys) throws -> String? {
            let text = try container.decodeIfPresent(String.self, forKey: key)
            return text?.isEmpty == false ? text : nil
        }
        // An unknown type throws here, so the store keeps the rule as an opaque entry.
        switch try container.decode(ConditionKind.self, forKey: .type) {
        case .appRunning: self = .appRunning(try app())
        case .appFrontmost: self = .appFrontmost(try app())
        case .call:
            self = .call(
                camera: try container.decodeIfPresent(Bool.self, forKey: .camera) ?? true,
                microphone: try container.decodeIfPresent(Bool.self, forKey: .microphone) ?? true)
        case .audioPlaying: self = .audioPlaying
        case .cpuBusy:
            self = .cpuBusy(
                percent: clamp(try container.decode(Int.self, forKey: .percent), Self.percentRange),
                windowSeconds: try window())
        case .networkBusy:
            self = .networkBusy(
                bytesPerSecond: clamp(try container.decode(Int.self, forKey: .bytesPerSecond), Self.rateRange),
                direction: try container.decodeIfPresent(NetworkDirection.self, forKey: .direction) ?? .download,
                windowSeconds: try window())
        case .powerAdapter: self = .powerAdapter
        case .externalDisplay: self = .externalDisplay(name: try optional(.name))
        case .device:
            let id = try container.decode(String.self, forKey: .id)
            self = .device(
                kind: try container.decode(DeviceKind.self, forKey: .kind), id: id,
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? id)
        case .wifi: self = .wifi(ssid: try container.decode(String.self, forKey: .ssid))
        case .calendarEvent:
            self = .calendarEvent(
                calendarID: try optional(.calendarID), calendarName: try optional(.calendarName),
                keyword: try optional(.keyword))
        case .schedule: self = .schedule(try container.decode(WeeklyWindow.self, forKey: .window))
        }
        guard isComplete else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Incomplete condition")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .appRunning(let app), .appFrontmost(let app):
            try container.encode(app.bundleID, forKey: .bundleID)
            try container.encode(app.name, forKey: .name)
        case .call(let camera, let microphone):
            try container.encode(camera, forKey: .camera)
            try container.encode(microphone, forKey: .microphone)
        case .audioPlaying, .powerAdapter:
            break
        case .cpuBusy(let percent, let windowSeconds):
            try container.encode(percent, forKey: .percent)
            try container.encode(windowSeconds, forKey: .windowSeconds)
        case .networkBusy(let bytesPerSecond, let direction, let windowSeconds):
            try container.encode(bytesPerSecond, forKey: .bytesPerSecond)
            try container.encode(direction, forKey: .direction)
            try container.encode(windowSeconds, forKey: .windowSeconds)
        case .externalDisplay(let name):
            try container.encodeIfPresent(name, forKey: .name)
        case .device(let kind, let id, let name):
            try container.encode(kind, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
        case .wifi(let ssid):
            try container.encode(ssid, forKey: .ssid)
        case .calendarEvent(let calendarID, let calendarName, let keyword):
            try container.encodeIfPresent(calendarID, forKey: .calendarID)
            try container.encodeIfPresent(calendarName, forKey: .calendarName)
            try container.encodeIfPresent(keyword, forKey: .keyword)
        case .schedule(let window):
            try container.encode(window, forKey: .window)
        }
    }
}

public enum Weekday: String, Codable, CaseIterable, Sendable {
    case mon, tue, wed, thu, fri, sat, sun

    public static let workdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri]

    /// From `Calendar`'s weekday number (1 = Sunday).
    init?(calendarWeekday: Int) {
        let order: [Weekday] = [.sun, .mon, .tue, .wed, .thu, .fri, .sat]
        guard order.indices.contains(calendarWeekday - 1) else { return nil }
        self = order[calendarWeekday - 1]
    }
}

/// A weekly time window, used for a rule's active hours and for the Schedule condition.
/// `days` are the days the window *starts* on. `end` before `start` runs past midnight
/// into the next day (Fri 22:00–02:00 covers Saturday 00:00–02:00). `start == end`
/// is the whole day.
public struct WeeklyWindow: Hashable, Sendable {
    public var days: Set<Weekday>
    public var start: ClockTime
    public var end: ClockTime

    public init(days: Set<Weekday>, start: ClockTime, end: ClockTime) {
        self.days = days
        self.start = start
        self.end = end
    }

    /// Whether `date` is inside the window, in `calendar`'s time zone.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let number = parts.weekday, let today = Weekday(calendarWeekday: number) else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let from = start.hour * 60 + start.minute
        let to = end.hour * 60 + end.minute
        if from == to { return days.contains(today) }
        if from < to { return days.contains(today) && minute >= from && minute < to }
        let yesterday = Weekday(calendarWeekday: (number + 5) % 7 + 1)
        return (days.contains(today) && minute >= from) || (yesterday.map(days.contains) == true && minute < to)
    }

    /// The next moment after `date` at which ``contains(_:calendar:)`` could change: the
    /// next start time, end time or midnight. Wall-clock, so it follows DST.
    public func nextBoundary(after date: Date, calendar: Calendar) -> Date? {
        [(start.hour, start.minute), (end.hour, end.minute), (0, 0)].compactMap {
            calendar.nextDate(
                after: date, matching: DateComponents(hour: $0.0, minute: $0.1, second: 0), matchingPolicy: .nextTime)
        }.min()
    }
}

extension WeeklyWindow: Codable {
    private enum CodingKeys: String, CodingKey { case days, start, end }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func time(_ key: CodingKeys) throws -> ClockTime {
            guard let time = ClockTime(text: try container.decode(String.self, forKey: key)) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected HH:mm")
            }
            return time
        }
        self.init(
            days: Set(try container.decode([Weekday].self, forKey: .days)), start: try time(.start), end: try time(.end)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Weekday.allCases.filter(days.contains), forKey: .days)
        try container.encode(start.text, forKey: .start)
        try container.encode(end.text, forKey: .end)
    }
}

extension ClockTime {
    /// Out-of-range values are clamped, so this never fails.
    public init(clampingHour hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// 24-hour `HH:mm`.
    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var text: String { String(format: "%02d:%02d", hour, minute) }
}
