import Testing
import UAwakeCore

@testable import UAwakeSystem

struct MediaMonitorTests {
    @Test func mediaUseCombinesPerDeviceFlags() {
        #expect(
            SystemMediaUseMonitor.mediaUse(microphoneFlags: [], cameraFlags: [])
                == MediaUse(cameraInUse: false, microphoneInUse: false))
        #expect(
            SystemMediaUseMonitor.mediaUse(microphoneFlags: [false, true], cameraFlags: [false])
                == MediaUse(cameraInUse: false, microphoneInUse: true))
        #expect(
            SystemMediaUseMonitor.mediaUse(microphoneFlags: [false], cameraFlags: [true, false])
                == MediaUse(cameraInUse: true, microphoneInUse: false))
    }

    @Test func diffReportsAddedAndRemoved() {
        let change = PropertyListeners<UInt32, String>.diff(from: [1, 2, 3], to: [2, 3, 4])
        #expect(change.added == [4])
        #expect(change.removed == [1])
    }

    @Test func listenersAreRemovedWithTheBlockTheyWereAddedWith() {
        var listeners = PropertyListeners<UInt32, String>()
        var removed: [UInt32: String] = [:]
        listeners.update(to: [1, 2]) {
            "block\($0)"
        } remove: {
            removed[$0] = $1
        }
        #expect(Set(listeners.ids) == [1, 2])

        // Moving the default output device: one out, one in.
        listeners.update(to: [2, 5]) {
            "block\($0)"
        } remove: {
            removed[$0] = $1
        }
        #expect(removed == [1: "block1"])
        #expect(listeners.blocks == [2: "block2", 5: "block5"])

        // A failed registration is not kept, so it is retried next time.
        listeners.update(to: [2, 5, 6]) { _ in
            nil
        } remove: {
            removed[$0] = $1
        }
        #expect(Set(listeners.ids) == [2, 5])

        listeners.removeAll { removed[$0] = $1 }
        #expect(listeners.ids.isEmpty)
        #expect(removed == [1: "block1", 2: "block2", 5: "block5"])
    }

    @Test func realMediaUseMonitorYieldsInitialValue() async {
        let monitor = SystemMediaUseMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        #expect(await iterator.next() == monitor.current)
    }

    @Test func realAudioOutputMonitorYieldsInitialValue() async {
        let monitor = SystemAudioOutputMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        #expect(await iterator.next() == monitor.current)
    }
}
