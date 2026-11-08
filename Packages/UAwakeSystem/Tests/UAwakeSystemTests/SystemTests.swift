import Foundation
import Testing
import UAwakeCore

@testable import UAwakeSystem

struct SystemTests {
    static let ac = DeviceState(
        batteryLevel: 80, powerSource: .ac, isLowPowerModeEnabled: false, thermalState: .nominal)
    static let battery = DeviceState(
        batteryLevel: 19, powerSource: .battery, isLowPowerModeEnabled: true, thermalState: .serious)

    @Test func monitorStreamsCurrentThenChanges() async {
        let monitor = FakeDeviceStateMonitor(Self.ac)
        var iterator = monitor.updates().makeAsyncIterator()
        monitor.send(Self.battery)
        #expect(await iterator.next() == Self.ac)
        #expect(await iterator.next() == Self.battery)
        #expect(monitor.current == Self.battery)
    }

    @Test func assertionTypesMatchIOKitNames() {
        #expect(IOKitAssertionProvider.assertionType(.system) == "PreventUserIdleSystemSleep")
        #expect(IOKitAssertionProvider.assertionType(.display) == "PreventUserIdleDisplaySleep")
        #expect(IOKitAssertionProvider.assertionType(.disk) == "PreventDiskIdle")
    }

    @Test func realDeviceStateIsReadable() {
        let state = SystemDeviceStateMonitor.read()
        if let level = state.batteryLevel { #expect((0...100).contains(level)) }
    }
}
