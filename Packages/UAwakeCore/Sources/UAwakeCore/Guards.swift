/// The 0.1 safety guards. Each ends every live session with its own cause.
/// The maximum cap is not here: the engine applies it as a deadline.
public struct BatteryGuard: Guard {
    public init() {}

    /// On battery power at or below ``GuardPolicy/batteryThreshold``; ignored on AC or without a battery.
    public func evaluate(_ state: DeviceState, sessions: [Session], policy: GuardPolicy) -> [GuardVerdict] {
        guard state.powerSource == .battery, let threshold = policy.batteryThreshold, let level = state.batteryLevel,
            level <= threshold
        else { return [] }
        return sessions.map { GuardVerdict(sessionID: $0.id, cause: .batteryGuard) }
    }
}

public struct LowPowerModeGuard: Guard {
    public init() {}

    public func evaluate(_ state: DeviceState, sessions: [Session], policy: GuardPolicy) -> [GuardVerdict] {
        guard policy.endOnLowPowerMode, state.isLowPowerModeEnabled else { return [] }
        return sessions.map { GuardVerdict(sessionID: $0.id, cause: .lowPowerMode) }
    }
}

public struct ThermalGuard: Guard {
    public init() {}

    /// `.serious` or `.critical`.
    public func evaluate(_ state: DeviceState, sessions: [Session], policy: GuardPolicy) -> [GuardVerdict] {
        guard policy.endOnThermalPressure, state.thermalState == .serious || state.thermalState == .critical else {
            return []
        }
        return sessions.map { GuardVerdict(sessionID: $0.id, cause: .thermalGuard) }
    }
}

extension DefaultSessionEngine {
    /// Battery, Low Power Mode and thermal, in that order of precedence.
    public static let standardGuards: [any Guard] = [BatteryGuard(), LowPowerModeGuard(), ThermalGuard()]
}
