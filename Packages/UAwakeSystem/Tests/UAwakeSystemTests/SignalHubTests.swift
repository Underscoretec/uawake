import Foundation
import Testing
import UAwakeCore

@testable import UAwakeSystem

@MainActor
struct SignalHubTests {
    final class Log {
        var signals: [Signal] = []
        var stopped: [SignalKind] = []
        var created = 0
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// One fake per monitor value type, each replayed through the hub exactly as the system one is.
    @Test func everyMonitorTypeIsForwardedAsItsSignal() async {
        let log = Log()
        let apps = FakeSignalMonitor(AppsState(running: ["a"], frontmost: "a"))
        let media = FakeSignalMonitor(MediaUse(cameraInUse: true, microphoneInUse: false))
        let audio = FakeSignalMonitor(true)
        let load = FakeSignalMonitor<LoadSample>()
        let displays = FakeSignalMonitor([DisplayInfo(name: "TV", isBuiltIn: false)])
        let usb = FakeSignalMonitor([ConnectedDevice(id: "05ac:8104", name: "Dock")])
        let bluetooth = FakeSignalMonitor([ConnectedDevice(id: "a4-83", name: "Headset")])
        let wifi = FakeSignalMonitor<String?>("Office")
        let calendar = FakeSignalMonitor<[CalendarEvent]>([])
        let hub = SignalHub(
            sources: [
                .apps: { SignalHub.stream(apps) { .apps($0) } },
                .mediaUse: { SignalHub.stream(media) { .mediaUse($0) } },
                .audioPlaying: { SignalHub.stream(audio) { .audioPlaying($0) } },
                .load: { SignalHub.stream(load) { .load($0) } },
                .displays: { SignalHub.stream(displays) { .displays($0) } },
                .usbDevices: { SignalHub.stream(usb) { .usbDevices($0) } },
                .bluetoothDevices: { SignalHub.stream(bluetooth) { .bluetoothDevices($0) } },
                .wifi: { SignalHub.stream(wifi) { .wifi($0) } },
                .calendar: { SignalHub.stream(calendar) { .calendar($0) } },
            ], deliver: { log.signals.append($0) })
        hub.setNeeded(Set(SignalKind.allCases))
        await settle()
        #expect(hub.running == Set(SignalKind.allCases).subtracting([.power]))
        #expect(Set(log.signals.map(\.kind)) == Set(SignalKind.allCases).subtracting([.power, .load]))

        let sample = LoadSample(cpuPercent: 40, bytesInPerSecond: 1, bytesOutPerSecond: 2, interval: 10)
        load.send(sample)
        wifi.send(nil)
        await settle()
        #expect(log.signals.suffix(2) == [.load(sample), .wifi(nil)])
    }

    @Test func monitorsExistOnlyWhileNeeded() async {
        let log = Log()
        weak var monitor: FakeSignalMonitor<Bool>?
        let hub = SignalHub(
            sources: [
                .audioPlaying: {
                    let new = FakeSignalMonitor(false)
                    monitor = new
                    log.created += 1
                    return SignalHub.stream(new) { .audioPlaying($0) }
                }
            ], deliver: { log.signals.append($0) }, stopped: { log.stopped.append($0) })
        #expect(log.created == 0, "nothing runs with no rules")

        hub.setNeeded([.audioPlaying])
        hub.setNeeded([.audioPlaying])
        await settle()
        #expect(log.created == 1)
        #expect(log.signals == [.audioPlaying(false)])
        monitor?.send(true)
        await settle()
        #expect(log.signals == [.audioPlaying(false), .audioPlaying(true)])

        hub.setNeeded([])
        await settle()
        #expect(hub.running.isEmpty)
        #expect(log.stopped == [.audioPlaying])
        #expect(monitor == nil, "the monitor is released when no rule needs it")

        hub.restart(.audioPlaying)
        #expect(log.created == 1, "restart only affects running monitors")
        hub.setNeeded([.audioPlaying])
        hub.restart(.audioPlaying)
        await settle()
        #expect(log.created == 3)
    }
}
