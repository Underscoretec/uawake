import Foundation
import Testing
import UAwakeCore

@testable import UAwakeSystem

// No SystemBluetoothMonitor or pairedDevices() here: either can show the Bluetooth prompt.
struct DeviceMonitorTests {
    @Test func usbIDIsLowercaseFourDigitHex() {
        #expect(SystemUSBMonitor.usbID(vendor: 0x05AC, product: 0x8104) == "05ac:8104")
        #expect(SystemUSBMonitor.usbID(vendor: 1, product: 0xABCD) == "0001:abcd")
    }

    @Test func usbNameFallsBackToEntryNameThenID() {
        #expect(
            SystemUSBMonitor.usbDevice(vendor: 1, product: 2, productName: "Keyboard", entryName: "Entry")
                == ConnectedDevice(id: "0001:0002", name: "Keyboard"))
        #expect(
            SystemUSBMonitor.usbDevice(vendor: 1, product: 2, productName: " ", entryName: "Entry")
                == ConnectedDevice(id: "0001:0002", name: "Entry"))
        #expect(
            SystemUSBMonitor.usbDevice(vendor: 1, product: 2, productName: nil, entryName: nil)
                == ConnectedDevice(id: "0001:0002", name: "0001:0002"))
        #expect(SystemUSBMonitor.usbDevice(vendor: nil, product: 2, productName: "X", entryName: nil) == nil)
    }

    @Test func bluetoothAddressIsNormalised() {
        #expect(SystemBluetoothMonitor.bluetoothID(address: "A4:83:E7:12:34:56") == "a4-83-e7-12-34-56")
        #expect(SystemBluetoothMonitor.bluetoothID(address: "a4-83-e7-12-34-56") == "a4-83-e7-12-34-56")
        #expect(
            SystemBluetoothMonitor.bluetoothDevice(address: "A4-83-E7-12-34-56", name: nil)
                == ConnectedDevice(id: "a4-83-e7-12-34-56", name: "a4-83-e7-12-34-56"))
        #expect(
            SystemBluetoothMonitor.bluetoothDevice(address: "A4-83-E7-12-34-56", name: "Mouse")?.name == "Mouse")
        #expect(SystemBluetoothMonitor.bluetoothDevice(address: nil, name: "Mouse") == nil)
    }

    @Test func normalizedDedupesByIDAndSortsByNameThenID() {
        let devices = [
            ConnectedDevice(id: "b", name: "Hub"),
            ConnectedDevice(id: "c", name: "Disk 10"),
            ConnectedDevice(id: "a", name: "Hub"),
            ConnectedDevice(id: "b", name: "Duplicate"),
            ConnectedDevice(id: "d", name: "Disk 9"),
        ]
        #expect(
            ConnectedDevice.normalized(devices).map(\.id) == ["d", "c", "a", "b"])
    }

    @Test func realUSBMonitorYieldsInitialList() async {
        let monitor = SystemUSBMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
        #expect(first == SystemUSBMonitor.read())
    }
}
