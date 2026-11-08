import Foundation

/// Fans values out to any number of `AsyncStream`s. Thread-safe.
final class Broadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    func stream(startingWith initial: Value? = nil) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(16))
        let key = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { self?.continuations[key] = nil }
        }
        lock.withLock {
            if let initial { continuation.yield(initial) }
            continuations[key] = continuation
        }
        return stream
    }

    func yield(_ value: Value) {
        for continuation in lock.withLock({ Array(continuations.values) }) { continuation.yield(value) }
    }
}
