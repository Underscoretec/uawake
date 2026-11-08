import Foundation
import UAwakeCore

extension DeviceState {
    /// A device state for tests: on AC, 80 %, nominal, Low Power Mode off unless overridden.
    public static func test(
        battery: Int? = 80, source: PowerSource = .ac, lowPowerMode: Bool = false,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> DeviceState {
        DeviceState(
            batteryLevel: battery, powerSource: source, isLowPowerModeEnabled: lowPowerMode, thermalState: thermal)
    }
}
