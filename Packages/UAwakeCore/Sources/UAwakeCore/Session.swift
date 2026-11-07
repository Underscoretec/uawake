import Foundation

/// The unit of keep-awake work. Every entry point (menu bar, URL scheme, rules,
/// CLI, Shortcuts, MDM) creates sessions; only the ``SessionEngine`` mutates them.
public struct Session: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Where the session came from.
    public let source: SessionSource
    /// Why the session exists, as structured data. The UI renders it localized;
    /// the IOKit assertion name is always English: `uawake: <reason.englishDescription>`.
    public let reason: SessionReason
    /// Combined awake modes. Always contains ``AwakeMode/system``.
    public let modes: Set<AwakeMode>
    /// The condition under which the session ends on its own.
    public let endCondition: EndCondition
    /// When the session was started.
    public let startedAt: Date
    /// The resolved moment the session ends on its own, or `nil` when it has no
    /// time limit. For indefinite and battery-level sessions it is the maximum cap
    /// (`startedAt + cap`), or `nil` when the cap is off. Extending moves it forward;
    /// it is `nil` while paused.
    public var deadline: Date?
    /// Lifecycle state. An ended session carries its ``EndCause``.
    public var state: SessionState

    public init(
        id: UUID = UUID(),
        source: SessionSource,
        reason: SessionReason,
        modes: Set<AwakeMode>,
        endCondition: EndCondition,
        startedAt: Date,
        deadline: Date?,
        state: SessionState = .active
    ) {
        self.id = id
        self.source = source
        self.reason = reason
        self.modes = modes.union([.system])
        self.endCondition = endCondition
        self.startedAt = startedAt
        self.deadline = deadline
        self.state = state
    }
}

/// What a caller asks the engine for. The engine fills in id, start time and deadline.
public struct SessionRequest: Equatable, Sendable {
    public var source: SessionSource
    public var reason: SessionReason
    /// ``AwakeMode/system`` is added by the engine if missing.
    public var modes: Set<AwakeMode>
    public var endCondition: EndCondition

    public init(source: SessionSource, reason: SessionReason, modes: Set<AwakeMode> = [.system], endCondition: EndCondition) {
        self.source = source
        self.reason = reason
        self.modes = modes
        self.endCondition = endCondition
    }
}

/// Origin of a session. 0.1 only creates `manual` and `url`; the rest are reserved
/// so later releases plug in without changing this contract.
public enum SessionSource: String, CaseIterable, Codable, Sendable {
    case manual, url, rule, cli, shortcut, mdm
}

/// What a session keeps awake. Each maps to one IOKit assertion type.
public enum AwakeMode: String, CaseIterable, Codable, Sendable {
    /// Prevent idle system sleep. Always present.
    case system
    /// Prevent idle display sleep.
    case display
    /// Prevent idle disk spin-down.
    case disk
}

/// When a session ends on its own.
/// Only `duration` and `until` sessions can be extended. The maximum cap applies
/// only to `indefinite` and `batteryLevel` sessions.
public enum EndCondition: Hashable, Sendable {
    /// Ends after a fixed duration from start.
    case duration(Duration)
    /// Ends at the next occurrence of a local wall-clock time (today if still ahead, else tomorrow).
    case until(ClockTime)
    /// Never ends on its own; subject to the maximum cap.
    case indefinite
    /// Ends (cause ``EndCause/expired``) when the Mac is on battery power and the
    /// level is at or below this percentage (1–100). Keeps running on AC power.
    /// Never "charge up to". Subject to the maximum cap.
    case batteryLevel(Int)
}

/// Why a session exists: a kind plus its arguments. Rendered localized only in
/// the UI; ``englishDescription`` is the untranslated form used for assertion names.
public enum SessionReason: Hashable, Sendable {
    /// The default reason for a source and end condition, e.g. "Manual: 2 hours".
    case standard(SessionSource, EndCondition)
    /// Caller-supplied text (URL `reason=`, CLI `--reason`), shown verbatim.
    case custom(String)
    /// From 1.0: a rule's name, e.g. "Rule: On a call".
    case rule(name: String)

    /// English text for the IOKit assertion name, e.g. "Manual: 1 hour 30 minutes".
    public var englishDescription: String {
        switch self {
        case .custom(let text): text
        case .rule(let name): "Rule: \(name)"
        case .standard(let source, let condition):
            "\(source.englishName): \(condition.englishDescription)"
        }
    }
}

extension SessionSource {
    var englishName: String {
        switch self {
        case .manual: "Manual"
        case .url: "URL"
        case .rule: "Rule"
        case .cli: "CLI"
        case .shortcut: "Shortcut"
        case .mdm: "Managed"
        }
    }
}

extension EndCondition {
    var englishDescription: String {
        switch self {
        case .indefinite: "indefinite"
        case .batteryLevel(let level): "until battery \(level)%"
        case .until(let time): String(format: "until %02d:%02d", time.hour, time.minute)
        case .duration(let duration):
            Self.englishParts(duration)
        }
    }

    private static func englishParts(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let parts = [(total / 3600, "hour"), (total % 3600 / 60, "minute"), (total % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }
}

/// A local wall-clock time of day, e.g. 18:30.
public struct ClockTime: Equatable, Hashable, Sendable {
    /// 0–23.
    public let hour: Int
    /// 0–59.
    public let minute: Int

    /// Returns `nil` when `hour` or `minute` is out of range.
    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }
}

/// Lifecycle of a session.
public enum SessionState: Equatable, Sendable {
    case active
    /// Paused (fast user switching). Assertions are released while paused.
    /// `remaining` is the time left at pause for `duration` and `until` sessions;
    /// `nil` for indefinite and battery-level ones, whose cap deadline is
    /// recomputed from `startedAt` and the current policy on resume.
    case paused(remaining: Duration?)
    /// Terminal. Assertions have been released.
    case ended(EndCause)
}

/// Why a session ended. Recorded for every end. A session's own end condition
/// (duration, until-time, battery level) ends it with `expired`; the maximum cap
/// ends it with `maximumCap`, never `expired`.
public enum EndCause: String, CaseIterable, Codable, Sendable {
    case expired
    case stoppedByUser
    case batteryGuard
    case lowPowerMode
    case thermalGuard
    case maximumCap
    case appQuit
}
