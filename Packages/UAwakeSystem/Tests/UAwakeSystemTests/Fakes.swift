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

/// Stands in for any ``SignalMonitor``: replays the values the test sends.
final class FakeSignalMonitor<Value: Sendable>: SignalMonitor, @unchecked Sendable {
    private let broadcaster = Broadcaster<Value>()
    private let lock = NSLock()
    private var value: Value?

    init(_ initial: Value? = nil) { value = initial }

    func updates() -> AsyncStream<Value> { broadcaster.stream(startingWith: lock.withLock { value }) }

    func send(_ new: Value) {
        lock.withLock { value = new }
        broadcaster.yield(new)
    }
}
