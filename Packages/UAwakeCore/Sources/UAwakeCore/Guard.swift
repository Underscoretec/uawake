import Foundation

/// Decides which sessions must end given the current device state.
/// Pure and synchronous: no I/O, no timers. The engine calls it on every
/// ``DeviceState`` change and ends the returned sessions with their cause.
///
/// The maximum cap is time-based, not state-based: the engine applies
/// ``GuardPolicy/maximumCap`` as a deadline (`startedAt + cap`) on indefinite and
/// battery-level sessions, recomputes it when the policy changes, and ends them
/// with ``EndCause/maximumCap``.
public protocol Guard: Sendable {
    func evaluate(_ state: DeviceState, sessions: [Session], policy: GuardPolicy) -> [GuardVerdict]
}

/// A session a guard wants ended, and why.
public struct GuardVerdict: Equatable, Sendable {
    public let sessionID: Session.ID
    public let cause: EndCause

    public init(sessionID: Session.ID, cause: EndCause) {
        self.sessionID = sessionID
        self.cause = cause
    }
}

/// Guard settings. Defaults match the spec; values come from user defaults,
/// and from 1.3 an MDM profile can clamp or lock them.
public struct GuardPolicy: Equatable, Sendable {
    /// End sessions at or below this level when on battery; `nil` disables. 5–95.
    public var batteryThreshold: Int? = 20
    public var endOnLowPowerMode = true
    /// End sessions at `.serious` or `.critical` thermal state.
    public var endOnThermalPressure = true
    /// Indefinite and battery-level sessions end this long after they start; `nil` disables. 1–72 h.
    public var maximumCap: Duration? = .seconds(24 * 3600)

    public init() {}
}

/// Snapshot of the power and thermal state guards care about.
/// Lives in Core so guards stay pure; produced by `DeviceStateMonitor` in UAwakeSystem.
public struct DeviceState: Equatable, Sendable {
    /// 0–100, or `nil` on Macs without a battery.
    public var batteryLevel: Int?
    public var powerSource: PowerSource
    public var isLowPowerModeEnabled: Bool
    public var thermalState: ProcessInfo.ThermalState

    public init(batteryLevel: Int?, powerSource: PowerSource, isLowPowerModeEnabled: Bool, thermalState: ProcessInfo.ThermalState) {
        self.batteryLevel = batteryLevel
        self.powerSource = powerSource
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }
}

public enum PowerSource: Equatable, Sendable {
    case ac, battery, unknown
}
