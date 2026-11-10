import Foundation
import Testing
import UAwakeCore

@testable import UAwakeSystem

struct LoadMonitorTests {
    typealias Ticks = SystemLoadMonitor.CPUTicks
    typealias Counters = SystemLoadMonitor.ByteCounters

    @Test func cpuPercentIsBusyShareOfTickDelta() {
        let old = Ticks(user: 100, system: 50, idle: 1000, nice: 10)
        let new = Ticks(user: 130, system: 60, idle: 1050, nice: 20)
        // busy 30 + 10 + 10 = 50 of 100 total
        #expect(SystemLoadMonitor.cpuPercent(from: old, to: new) == 50)
        #expect(SystemLoadMonitor.cpuPercent(from: old, to: old) == 0)
    }

    @Test func cpuPercentHandlesWrappedTicks() {
        let old = Ticks(user: .max - 9, system: 0, idle: .max - 9, nice: 0)
        let new = Ticks(user: 10, system: 0, idle: 10, nice: 0)
        #expect(SystemLoadMonitor.cpuPercent(from: old, to: new) == 50)
    }

    @Test func byteDeltaWrapsPastUInt32Max() {
        #expect(SystemLoadMonitor.byteDelta(from: 100, to: 250) == 150)
        #expect(SystemLoadMonitor.byteDelta(from: .max - 99, to: 50) == 150)
        #expect(SystemLoadMonitor.byteDelta(from: 7, to: 7) == 0)
    }

    @Test func byteDeltasIgnoreInterfacesThatAppearOrDisappear() {
        let old = ["en0": Counters(bytesIn: 1000, bytesOut: 500), "en5": Counters(bytesIn: 9, bytesOut: 9)]
        let new = [
            "en0": Counters(bytesIn: 3000, bytesOut: 600), "en7": Counters(bytesIn: 1_000_000, bytesOut: 1_000_000),
        ]
        let deltas = SystemLoadMonitor.byteDeltas(from: old, to: new)
        #expect(deltas.bytesIn == 2000)
        #expect(deltas.bytesOut == 100)
    }

    @Test func dropsTicksSpanningSleepOrLateTimer() {
        #expect(!SystemLoadMonitor.shouldDrop(elapsed: 10, interval: 10))
        #expect(!SystemLoadMonitor.shouldDrop(elapsed: 25, interval: 10))
        #expect(SystemLoadMonitor.shouldDrop(elapsed: 25.1, interval: 10))
        #expect(SystemLoadMonitor.shouldDrop(elapsed: 0, interval: 10))
    }

    @Test func realMonitorYieldsSample() async {
        let monitor = SystemLoadMonitor(interval: 0.2)
        let sample = await withTaskGroup(of: LoadSample?.self) { group in
            group.addTask { await monitor.updates().first { _ in true } }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(sample != nil)
        if let sample {
            #expect((0...100).contains(sample.cpuPercent))
            #expect(sample.bytesInPerSecond >= 0)
            #expect(sample.bytesOutPerSecond >= 0)
            #expect(sample.interval > 0)
        }
    }
}
