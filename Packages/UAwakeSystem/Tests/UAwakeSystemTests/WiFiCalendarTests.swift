import CoreBluetooth
import CoreLocation
import EventKit
import Foundation
import Testing
import UAwakeCore

@testable import UAwakeSystem

struct WiFiCalendarTests {
    typealias Candidate = SystemCalendarMonitor.Candidate

    static func candidate(
        _ title: String, start: TimeInterval, allDay: Bool = false, declined: Bool = false, free: Bool = false
    ) -> Candidate {
        Candidate(
            start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + 1800),
            calendarID: "work", title: title, isAllDay: allDay, isDeclined: declined, isFree: free)
    }

    @Test func calendarFilterDropsAllDayDeclinedAndFree() {
        let result = SystemCalendarMonitor.filter([
            Self.candidate("Holiday", start: 0, allDay: true),
            Self.candidate("Declined", start: 0, declined: true),
            Self.candidate("Focus", start: 0, free: true),
            Self.candidate("Standup", start: 0),
        ])
        #expect(result.map(\.title) == ["Standup"])
        #expect(result.first?.calendarID == "work")
    }

    @Test func calendarFilterSortsByStartThenTitle() {
        let result = SystemCalendarMonitor.filter([
            Self.candidate("Late", start: 7200),
            Self.candidate("B", start: 3600),
            Self.candidate("A", start: 3600),
        ])
        #expect(result.map(\.title) == ["A", "B", "Late"])
    }

    @Test func permissionStatusMapping() {
        #expect(SystemPermissionProvider.status(EKAuthorizationStatus.fullAccess) == .granted)
        #expect(SystemPermissionProvider.status(EKAuthorizationStatus.writeOnly) == .denied)
        #expect(SystemPermissionProvider.status(EKAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(SystemPermissionProvider.status(CLAuthorizationStatus.authorizedAlways) == .granted)
        #expect(SystemPermissionProvider.status(CLAuthorizationStatus.restricted) == .denied)
        #expect(SystemPermissionProvider.status(CLAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(SystemPermissionProvider.status(CBManagerAuthorization.allowedAlways) == .granted)
        #expect(SystemPermissionProvider.status(CBManagerAuthorization.denied) == .denied)
        #expect(SystemPermissionProvider.status(CBManagerAuthorization.notDetermined) == .notDetermined)
    }

    @Test func wifiMonitorYieldsInitialValue() async {
        let monitor = SystemWiFiMonitor()
        var iterator = monitor.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .some(monitor.current))
    }
}
