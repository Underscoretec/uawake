import Foundation

/// What the user's "Require password after screen saver begins or display is turned off"
/// setting is, as far as uawake can tell. Decides whether a button may say "Lock".
public enum PasswordRequirement: Equatable, Sendable {
    /// A password is asked at once.
    case immediate
    /// A password is asked after this many seconds.
    case delay(seconds: Int)
    /// No password is asked.
    case never
    /// The setting could not be read.
    case unknown

    /// Up to this many seconds still counts as locking promptly.
    public static let promptDelayLimit = 60

    /// True when turning the screen off locks it promptly (immediate, or a delay up to a minute).
    public var locksPromptly: Bool {
        switch self {
        case .immediate: true
        case .delay(let seconds): seconds <= Self.promptDelayLimit
        case .never, .unknown: false
        }
    }

    /// True when we know a quick screen-off will not ask for a password.
    public var isKnownNotToLock: Bool {
        switch self {
        case .never: true
        case .delay(let seconds): seconds > Self.promptDelayLimit
        case .immediate, .unknown: false
        }
    }

    /// Parses `sysadminctl -screenLock status` output, e.g. "screenLock delay is immediate",
    /// "screenLock delay is 300 seconds", "screenLock is off". Anything else is ``unknown``.
    public static func parse(_ text: String) -> PasswordRequirement {
        let lower = text.lowercased()
        if lower.contains("immediate") { return .immediate }
        if lower.contains("off") || lower.contains("never") || lower.contains("disabled") { return .never }
        guard let match = lower.firstMatch(of: /(\d+)\s*(second|sec|minute|min|hour|hr)?/),
            let value = Int(match.1)
        else { return .unknown }
        let unit = match.2.map(String.init) ?? "second"
        switch unit {
        case "minute", "min": return .delay(seconds: value * 60)
        case "hour", "hr": return .delay(seconds: value * 3600)
        default: return .delay(seconds: value)
        }
    }
}

/// The lock and dim settings as the tracker reads them, with the dim kept below the lock.
public struct LockDimConfig: Equatable, Sendable {
    /// Idle seconds before auto-lock; `nil` when off.
    public var autoLock: TimeInterval?
    /// Idle seconds before the dim; `nil` when off.
    public var dim: TimeInterval?
    /// 0.2–0.9.
    public var darkness: Double
    public var keepsWatermark: Bool
    public var skipsWhenPlaying: Bool

    public init(
        autoLock: TimeInterval? = nil, dim: TimeInterval? = nil, darkness: Double = 0.6, keepsWatermark: Bool = true,
        skipsWhenPlaying: Bool = true
    ) {
        self.autoLock = autoLock
        self.dim = dim
        self.darkness = darkness
        self.keepsWatermark = keepsWatermark
        self.skipsWhenPlaying = skipsWhenPlaying
    }

    public var isArmed: Bool { autoLock != nil || dim != nil }

    /// Seconds until the dim at this idle time; `nil` when off or already due.
    public func dimsIn(idle: TimeInterval) -> TimeInterval? {
        dim.flatMap { $0 > idle ? $0 - idle : nil }
    }

    /// Seconds until the lock at this idle time; `nil` when off or already due.
    public func locksIn(idle: TimeInterval) -> TimeInterval? {
        autoLock.flatMap { $0 > idle ? $0 - idle : nil }
    }
}

/// The dim and auto-lock sequence, a pure function of idle time. The app samples idle time
/// and feeds it in; tests feed numbers.
///
/// Both thresholds count from the last input. Auto-lock fires once per idle period and again
/// only after input; the dim shows from its threshold until input, a lock, or the session ending.
public struct LockDimTracker: Equatable, Sendable {
    public struct Output: Equatable, Sendable {
        public var dimmed = false
        public var lockNow = false
    }

    private var lockFired = false

    public init() {}

    /// - Parameters:
    ///   - sessionActive: some session is active; nothing dims or locks without one.
    ///   - locked: the screen is locked now.
    ///   - othersHoldDisplay: another app holds a display-sleep assertion (video, a presentation).
    ///     Evaluated only when the dim is due.
    public mutating func update(
        config: LockDimConfig, idle: TimeInterval, sessionActive: Bool, locked: Bool,
        othersHoldDisplay: @autoclosure () -> Bool
    ) -> Output {
        var output = Output()
        guard sessionActive else {
            lockFired = false
            return output
        }
        if locked {
            lockFired = true
            return output
        }
        if let autoLock = config.autoLock {
            if idle < autoLock {
                lockFired = false
            } else if !lockFired {
                lockFired = true
                output.lockNow = true
                return output
            }
        }
        // Past the lock time the lock is on its way (or failed): no dim.
        if let autoLock = config.autoLock, idle >= autoLock { return output }
        if let dim = config.dim, idle >= dim, !(config.skipsWhenPlaying && othersHoldDisplay()) {
            output.dimmed = true
        }
        return output
    }
}
