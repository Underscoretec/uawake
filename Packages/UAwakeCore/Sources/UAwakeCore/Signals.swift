import Foundation

/// What the system monitors report to the ``RuleEngine``. Value types only, so Core
/// stays free of system frameworks; the monitors live in UAwakeSystem.
public enum Signal: Equatable, Sendable {
    case apps(AppsState)
    case mediaUse(MediaUse)
    /// The default output device is running (not necessarily audible).
    case audioPlaying(Bool)
    case load(LoadSample)
    case power(DeviceState)
    case displays([DisplayInfo])
    case usbDevices([ConnectedDevice])
    case bluetoothDevices([ConnectedDevice])
    /// The current Wi-Fi network name; `nil` when not associated or not readable.
    case wifi(String?)
    /// Events in the monitor's look-ahead window, already filtered (see ``CalendarEvent``).
    case calendar([CalendarEvent])

    public var kind: SignalKind {
        switch self {
        case .apps: .apps
        case .mediaUse: .mediaUse
        case .audioPlaying: .audioPlaying
        case .load: .load
        case .power: .power
        case .displays: .displays
        case .usbDevices: .usbDevices
        case .bluetoothDevices: .bluetoothDevices
        case .wifi: .wifi
        case .calendar: .calendar
        }
    }
}

/// One per monitor. The app runs a monitor only while a rule needs its kind.
public enum SignalKind: String, CaseIterable, Sendable {
    case apps, mediaUse, audioPlaying, load, power, displays, usbDevices, bluetoothDevices, wifi, calendar
}

/// Running and frontmost apps, by bundle identifier.
public struct AppsState: Equatable, Sendable {
    public var running: Set<String>
    public var frontmost: String?

    public init(running: Set<String>, frontmost: String?) {
        self.running = running
        self.frontmost = frontmost
    }
}

/// Whether any camera or any microphone is in use by some process.
public struct MediaUse: Equatable, Sendable {
    public var cameraInUse: Bool
    public var microphoneInUse: Bool

    public init(cameraInUse: Bool, microphoneInUse: Bool) {
        self.cameraInUse = cameraInUse
        self.microphoneInUse = microphoneInUse
    }
}

/// Whole-system CPU load and network throughput averaged over `interval`, the time since
/// the previous sample. The first sample after start or wake is not emitted.
public struct LoadSample: Equatable, Sendable {
    /// 0–100, across all cores.
    public var cpuPercent: Double
    public var bytesInPerSecond: Double
    public var bytesOutPerSecond: Double
    /// Seconds this sample covers (about 10).
    public var interval: TimeInterval

    public init(cpuPercent: Double, bytesInPerSecond: Double, bytesOutPerSecond: Double, interval: TimeInterval) {
        self.cpuPercent = cpuPercent
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
        self.interval = interval
    }
}

public struct DisplayInfo: Hashable, Sendable {
    /// `NSScreen.localizedName`.
    public var name: String
    public var isBuiltIn: Bool

    public init(name: String, isBuiltIn: Bool) {
        self.name = name
        self.isBuiltIn = isBuiltIn
    }
}

/// A USB or Bluetooth device. `id` is what rules match on; `name` is for display.
public struct ConnectedDevice: Hashable, Sendable {
    /// USB: lowercase hex `vendorID:productID`, e.g. `05ac:8104`.
    /// Bluetooth: the device address, lowercase with `-` separators, e.g. `a4-83-e7-12-34-56`.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A calendar event that can keep the Mac awake. The monitor leaves out all-day events,
/// events the user declined and events whose availability is "free".
public struct CalendarEvent: Hashable, Sendable {
    public var start: Date
    public var end: Date
    /// `EKCalendar.calendarIdentifier`.
    public var calendarID: String
    public var title: String

    public init(start: Date, end: Date, calendarID: String, title: String) {
        self.start = start
        self.end = end
        self.calendarID = calendarID
        self.title = title
    }
}

/// A calendar the user can pick in the rule editor.
public struct CalendarInfo: Hashable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A privacy permission some conditions need. Requested only when a rule needs it.
public enum RulePermission: String, CaseIterable, Sendable {
    case bluetooth, location, calendar
}

public enum PermissionStatus: Equatable, Sendable {
    case notDetermined, granted, denied
}
