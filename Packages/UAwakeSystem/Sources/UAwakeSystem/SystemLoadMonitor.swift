import Darwin
import Foundation
import UAwakeCore

/// Whole-system CPU load (`host_statistics`) and `en*` network throughput (`getifaddrs`),
/// sampled on one coalescable timer. Emits a ``LoadSample`` per tick after the first; ticks
/// spanning a system sleep or a badly late timer re-baseline and emit nothing.
public final class SystemLoadMonitor: SignalMonitor, @unchecked Sendable {
    struct CPUTicks: Equatable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    struct ByteCounters: Equatable {
        var bytesIn: UInt32
        var bytesOut: UInt32
    }

    struct Reading {
        var time: ContinuousClock.Instant
        var cpu: CPUTicks
        var interfaces: [String: ByteCounters]
    }

    private let broadcaster = Broadcaster<LoadSample>()
    private let queue = DispatchQueue(label: "com.underscoretec.uawake.load", qos: .utility)
    private let timer: any DispatchSourceTimer
    private let interval: TimeInterval
    /// Confined to `queue`.
    private var previous: Reading?

    public init(interval: TimeInterval = 10) {
        self.interval = interval
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    deinit { timer.cancel() }

    public func updates() -> AsyncStream<LoadSample> { broadcaster.stream() }

    private func tick() {
        guard let cpu = Self.readCPU() else {
            previous = nil
            return
        }
        let current = Reading(time: .now, cpu: cpu, interfaces: Self.readInterfaces())
        defer { previous = current }
        guard let previous else { return }
        let elapsed = Self.seconds(previous.time.duration(to: current.time))
        guard !Self.shouldDrop(elapsed: elapsed, interval: interval) else { return }
        let bytes = Self.byteDeltas(from: previous.interfaces, to: current.interfaces)
        broadcaster.yield(
            LoadSample(
                cpuPercent: Self.cpuPercent(from: previous.cpu, to: current.cpu),
                bytesInPerSecond: Double(bytes.bytesIn) / elapsed,
                bytesOutPerSecond: Double(bytes.bytesOut) / elapsed,
                interval: elapsed))
    }

    // MARK: Pure arithmetic

    /// Busy (user + system + nice) share of all ticks between two readings, 0–100.
    static func cpuPercent(from old: CPUTicks, to new: CPUTicks) -> Double {
        let busy = UInt64(new.user &- old.user) + UInt64(new.system &- old.system) + UInt64(new.nice &- old.nice)
        let total = busy + UInt64(new.idle &- old.idle)
        guard total > 0 else { return 0 }
        return Double(busy) / Double(total) * 100
    }

    /// Delta of a 32-bit counter that wraps at 4 GiB.
    static func byteDelta(from old: UInt32, to new: UInt32) -> UInt64 { UInt64(new &- old) }

    /// Summed deltas over interfaces present in both readings; one that appears or
    /// disappears contributes 0.
    static func byteDeltas(
        from old: [String: ByteCounters], to new: [String: ByteCounters]
    ) -> (bytesIn: UInt64, bytesOut: UInt64) {
        var result: (bytesIn: UInt64, bytesOut: UInt64) = (0, 0)
        for (name, counters) in new {
            guard let before = old[name] else { continue }
            result.bytesIn += byteDelta(from: before.bytesIn, to: counters.bytesIn)
            result.bytesOut += byteDelta(from: before.bytesOut, to: counters.bytesOut)
        }
        return result
    }

    /// True when the tick spans a sleep or a badly delayed timer and must re-baseline.
    static func shouldDrop(elapsed: TimeInterval, interval: TimeInterval) -> Bool {
        elapsed <= 0 || elapsed > interval * 2.5
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    // MARK: System reads

    static func readCPU() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks  // user, system, idle, nice
        return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    /// Link-layer byte counters for interfaces named `en*`. Empty if `getifaddrs` fails.
    static func readInterfaces() -> [String: ByteCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var result: [String: ByteCounters] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                let data = entry.ifa_data, strncmp(entry.ifa_name, "en", 2) == 0
            else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            result[String(cString: entry.ifa_name)] = ByteCounters(
                bytesIn: counters.ifi_ibytes, bytesOut: counters.ifi_obytes)
        }
        return result
    }
}
