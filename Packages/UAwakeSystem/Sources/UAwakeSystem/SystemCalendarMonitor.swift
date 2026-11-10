import EventKit
import Foundation
import UAwakeCore
import os

/// Calendar events from now to 25 hours ahead, without all-day, declined and "free"
/// events. Refetched on `EKEventStoreChanged`, hourly, and on ``refresh()``. Emits `[]`
/// without full calendar access and never prompts.
public final class SystemCalendarMonitor: SignalMonitor, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.underscoretec.uawake", category: "system")
    static let lookAhead: TimeInterval = 25 * 60 * 60
    private let broadcaster = Broadcaster<[CalendarEvent]>()
    private let lock = NSLock()
    private let store = EKEventStore()
    private var events: [CalendarEvent] = []
    private var observer: (any NSObjectProtocol)?
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.underscoretec.uawake.calendar"))

    public init() {
        events = Self.fetch(from: store)
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: nil
        ) { [weak self] _ in self?.refresh() }
        timer.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(600))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
    }

    deinit {
        timer.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public var current: [CalendarEvent] { lock.withLock { events } }

    public func updates() -> AsyncStream<[CalendarEvent]> {
        lock.withLock { broadcaster.stream(startingWith: events) }
    }

    /// Refetches, e.g. after wake or after calendar access is granted.
    public func refresh() {
        lock.withLock {
            let new = Self.fetch(from: store)
            guard new != events else { return }
            events = new
            Self.logger.debug("Calendar events: \(new.count, privacy: .public)")
            broadcaster.yield(new)
        }
    }

    /// Event calendars for the rule editor, sorted by title. Empty without full access.
    public static func calendars() -> [CalendarInfo] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return EKEventStore().calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func fetch(from store: EKEventStore, now: Date = Date()) -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: now + lookAhead, calendars: nil)
        let candidates = store.events(matching: predicate).compactMap { event -> Candidate? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return Candidate(
                start: start, end: end,
                calendarID: event.calendar?.calendarIdentifier ?? "",
                title: event.title ?? "",
                isAllDay: event.isAllDay,
                isDeclined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined,
                isFree: event.availability == .free)
        }
        return filter(candidates)
    }

    /// The EventKit fields the filter needs, so it is testable without EventKit objects.
    struct Candidate {
        var start: Date
        var end: Date
        var calendarID: String
        var title: String
        var isAllDay: Bool
        var isDeclined: Bool
        var isFree: Bool
    }

    static func filter(_ candidates: [Candidate]) -> [CalendarEvent] {
        candidates
            .filter { !$0.isAllDay && !$0.isDeclined && !$0.isFree }
            .map { CalendarEvent(start: $0.start, end: $0.end, calendarID: $0.calendarID, title: $0.title) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }
}
