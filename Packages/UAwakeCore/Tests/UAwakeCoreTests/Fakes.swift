import Foundation
import UAwakeCore

/// Manual time. `advance(by:)` resumes every sleeper whose deadline has passed.
final class FakeClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = [:]

    init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) { current = now }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock {
            current += seconds
            let due = sleepers.filter { $0.value.deadline <= current }
            for key in due.keys { sleepers[key] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    func sleep(until deadline: Date) async throws {
        let key = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeNow = lock.withLock {
                    if deadline <= current || Task.isCancelled { return true }
                    sleepers[key] = (deadline, continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: key) }?.continuation.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }
}

/// Hands out sequential ids and tracks which are live.
final class FakeAssertionProvider: AssertionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var _live: [UInt32: String] = [:]
    var failure: Int32?

    /// Live assertion names by id.
    var live: [UInt32: String] { lock.withLock { _live } }

    func acquire(modes: Set<AwakeMode>, reason: String) throws(SessionEngineError) -> AssertionHandle {
        let ids: [UInt32]? = lock.withLock {
            if failure != nil { return nil }
            let ids = (0..<UInt32(modes.count)).map { nextID + $0 }
            nextID += UInt32(modes.count)
            for id in ids { _live[id] = "uawake: \(reason)" }
            return ids
        }
        guard let ids else { throw .assertionFailed(code: failure ?? -1) }
        return AssertionHandle(ids: ids)
    }

    func release(_ handle: AssertionHandle) {
        lock.withLock { for id in handle.ids { _live[id] = nil } }
    }
}
