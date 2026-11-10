import Foundation
import Testing
import UAwakeCore

@testable import UAwakeSystem

struct AppsDisplayMonitorTests {
    @Test func appsStateSkipsMissingBundleIDs() {
        let state = SystemAppsMonitor.state(
            bundleIDs: ["com.apple.finder", nil, "com.apple.Safari", "com.apple.finder"],
            frontmost: "com.apple.Safari")
        #expect(state == AppsState(running: ["com.apple.finder", "com.apple.Safari"], frontmost: "com.apple.Safari"))
    }

    @Test func displaysSortByNameThenBuiltIn() {
        let built = DisplayInfo(name: "Display", isBuiltIn: true)
        let external = DisplayInfo(name: "Display", isBuiltIn: false)
        let studio = DisplayInfo(name: "Studio Display", isBuiltIn: false)
        let expected = [external, built, studio]
        #expect(SystemDisplayMonitor.sorted([studio, built, external]) == expected)
        #expect(SystemDisplayMonitor.sorted([built, studio, external]) == expected)
    }

    @Test func appsMonitorYieldsCurrentFirstThenOnlyChanges() async {
        let monitor = SystemAppsMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        let initial = monitor.current
        let changed = AppsState(running: initial.running.union(["test.uawake.fake"]), frontmost: "test.uawake.fake")
        monitor.refresh(initial)
        monitor.refresh(changed)
        monitor.refresh(changed)
        monitor.refresh(initial)
        #expect(await iterator.next() == initial)
        #expect(await iterator.next() == changed)
        #expect(await iterator.next() == initial)
    }

    @MainActor @Test func displayMonitorYieldsCurrentFirstThenOnlyChanges() async {
        let monitor = SystemDisplayMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        let initial = monitor.current
        let changed = initial + [DisplayInfo(name: "Fake", isBuiltIn: false)]
        monitor.refresh(initial)
        monitor.refresh(changed)
        monitor.refresh(changed)
        monitor.refresh(initial)
        #expect(await iterator.next() == initial)
        #expect(await iterator.next() == changed)
        #expect(await iterator.next() == initial)
    }

    @Test func realAppsMonitorReportsRunningApps() async {
        let monitor = SystemAppsMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.running.isEmpty == false)
    }

    @MainActor @Test func realDisplayMonitorYieldsInitialValue() async {
        let monitor = SystemDisplayMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == SystemDisplayMonitor.read())
    }
}
