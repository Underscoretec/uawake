import Foundation
import UAwakeCore

@testable import UAwakeSystem

/// Replays device states sent by the test.
final class FakeDeviceStateMonitor: DeviceStateMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<DeviceState>()
    private let lock = NSLock()
    private var state: DeviceState

    init(_ initial: DeviceState) { state = initial }

    var current: DeviceState { lock.withLock { state } }

    func updates() -> AsyncStream<DeviceState> { broadcaster.stream(startingWith: current) }

    func send(_ new: DeviceState) {
        lock.withLock { state = new }
        broadcaster.yield(new)
    }
}
