import Foundation
import Observation
import UAwakeCore

/// Sections of the main window's sidebar. Diagnostics (1.2) joins later.
enum MainSection: String, CaseIterable, Hashable, Identifiable {
    case overview, rules, durations, safety, appearance, general, updates, about
    var id: Self { self }
}

/// Why a start was refused, and which main-window section can change it.
struct Refusal: Equatable {
    let message: String
    let section: MainSection?
}

/// A dismissible, tinted card in the popover and Overview.
struct Banner: Identifiable, Equatable {
    enum Kind: Equatable {
        case refusal
        case guardStop(Session.ID)
    }

    let kind: Kind
    let tone: Tone
    let symbol: String
    let title: String
    let message: String
    let section: MainSection?

    var id: String {
        switch kind {
        case .refusal: "refusal"
        case .guardStop(let id): id.uuidString
        }
    }
}

/// What the colour of a chip, banner or hero means. Always paired with an icon and text.
enum Tone: Equatable {
    /// Informational.
    case neutral
    /// Awake, or guards on and clear.
    case good
    /// Ending soon, or a guard near its limit.
    case caution
    /// Stopped by a guard, or a guard blocking sessions.
    case critical
}

/// The popover's main state, big and bold.
struct Hero: Equatable {
    enum Kind: Equatable {
        /// Nothing keeps the Mac awake.
        case idle
        /// Every active session has its own end: a countdown to the last one.
        case timed
        /// An indefinite or battery-level session runs.
        case indefinite
    }

    let kind: Kind
    /// The countdown for `.timed`; `nil` otherwise.
    let countdown: String?
    /// "until 18:30" for `.timed`, "Indefinite" for `.indefinite`.
    let caption: String
    /// Elapsed fraction of the longest-running timed session, 0–1.
    let progress: Double?
    let isEndingSoon: Bool
}

struct StatusChip: Identifiable, Equatable {
    let id: String
    let symbol: String
    let text: String
    let tone: Tone
    let accessibilityLabel: String
}

struct SessionRow: Identifiable, Equatable {
    let id: Session.ID
    /// The duration ("1 hour") or the caller's reason ("Render"); no source prefix.
    let title: String
    /// "Started manually at 9:50", "Started from a link at 9:50".
    let subtitle: String
    let source: SessionSource
    let endCondition: EndCondition
    /// The session's own end (duration or until-time); `nil` for indefinite and battery-level.
    let deadline: Date?
    let isPaused: Bool
    /// Extend is offered only for sessions with a deadline.
    let canExtend: Bool

    init(_ session: Session) {
        id = session.id
        title = session.title
        subtitle = session.source.startedText(at: session.startedAt.formatted(date: .omitted, time: .shortened))
        source = session.source
        endCondition = session.endCondition
        isPaused = session.state != .active
        canExtend = session.endCondition.hasOwnDeadline
        deadline = canExtend ? session.deadline : nil
    }
}

/// State and actions behind the popover, the status item and the global shortcut.
@MainActor
@Observable
final class PopoverViewModel {
    let engine: DefaultSessionEngine
    let settings: UAwakeSettings
    private(set) var presets: [EndCondition]
    private(set) var refusal: Refusal?
    var untilTime: Date
    /// The popover's tallest allowed height: the screen's space below the menu bar. Taller
    /// content scrolls, so the header and footer always stay on screen.
    var maxHeight: CGFloat = .infinity

    /// Set by ``AppModel``; `nil` in tests that don't involve rules.
    @ObservationIgnored var rules: RulesModel?
    @ObservationIgnored var openMainWindow: (MainSection?) -> Void = { _ in }
    @ObservationIgnored var showPopover: () -> Void = {}

    init(engine: DefaultSessionEngine, settings: UAwakeSettings, now: Date = Date()) {
        self.engine = engine
        self.settings = settings
        presets = settings.presets
        untilTime = Self.defaultUntilTime(from: now)
    }

    /// Re-reads presets, which Settings may have changed.
    func reload() {
        presets = settings.presets
    }

    // MARK: State

    /// Manual or URL sessions are running: what the on/off control and primary click toggle.
    var isOn: Bool {
        engine.sessions.contains { $0.source == .manual || $0.source == .url }
    }

    /// Any session is actively keeping the Mac awake: the menu bar icon's state.
    var isAwake: Bool {
        engine.sessions.contains { $0.state == .active }
    }

    var rows: [SessionRow] {
        engine.sessions.map(SessionRow.init)
    }

    /// The only session, when there is exactly one and the list is hidden: the hero shows it.
    var singleRow: SessionRow? {
        let rows = rows
        return rows.count == 1 && !showsSessionList ? rows[0] : nil
    }

    /// The list shows with 2+ sessions, a single paused one (the hero is idle then), or any
    /// rule session: a rule's row carries its source tile, what matched and its stop button.
    var showsSessionList: Bool {
        let count = engine.sessions.count
        return count >= 2 || (count == 1 && !isAwake) || engine.sessions.contains { $0.source == .rule }
    }

    // MARK: Rules

    /// What the popover's Rules strip says; `nil` (strip hidden) when there are no rules.
    struct RulesStrip: Equatable {
        let text: String
        let isPaused: Bool
    }

    func rulesStrip(now: Date) -> RulesStrip? {
        guard let rules, !rules.rules.isEmpty else { return nil }
        if let pause = rules.engine.pause {
            return RulesStrip(text: pause.text(now: now), isPaused: true)
        }
        return RulesStrip(
            text: String(
                localized: "\(rules.matchingCount) of \(rules.rules.count) rules matching",
                comment: "Popover rules strip: matching rules out of all rules"),
            isPaused: false)
    }

    /// For a rule's session row: "Rule · Keynote is in front", or "Rule · ends in 1:12" while
    /// it lingers. `nil` for other sessions.
    func ruleSubtitle(_ row: SessionRow, now: Date) -> String? {
        guard row.source == .rule else { return nil }
        let label = String(localized: "Rule", comment: "Session source")
        guard let rules, let rule = rules.engine.rule(forSession: row.id) else { return label }
        if case .lingering(let until) = rules.status(of: rule) {
            let left = Self.countdownText(until.timeIntervalSince(now))
            return String(localized: "\(label) · ends in \(left)", comment: "Rule session row while lingering")
        }
        let met = zip(rule.conditions, rules.engine.readings(for: rule)).filter { $0.1.state == .met }.map(\.0.summary)
        return met.isEmpty ? label : "\(label) · \(met.formatted(.list(type: .and, width: .narrow)))"
    }

    func pauseRules(_ choice: PauseChoice) { rules?.pause(choice) }

    func resumeRules() { rules?.resume() }

    /// The running manual session's end condition, for the selected preset chip.
    var currentManualCondition: EndCondition? {
        let manual = engine.sessions.filter { $0.source == .manual }
        return manual.count == 1 ? manual[0].endCondition : nil
    }

    /// Time until the Mac may sleep again: the latest deadline, shown only when every
    /// active session has its own deadline. `nil` while any indefinite or battery-level
    /// session runs, or when nothing is active.
    func countdown(now: Date) -> String? {
        countdownRemaining(now: now).map(Self.countdownText)
    }

    /// Seconds until the last timed session ends, under the same rule as ``countdown(now:)``.
    func countdownRemaining(now: Date) -> TimeInterval? {
        let active = engine.sessions.filter { $0.state == .active }
        guard !active.isEmpty, active.allSatisfy({ $0.endCondition.hasOwnDeadline }),
            let latest = active.compactMap(\.deadline).max()
        else { return nil }
        return latest.timeIntervalSince(now)
    }

    /// The menu bar's coarser countdown (see ``menuBarText(_:)``).
    func menuBarCountdown(now: Date) -> String? {
        countdownRemaining(now: now).map(Self.menuBarText)
    }

    /// Menu bar countdown: `1:42` (hours and minutes) from an hour, `42m` under an hour, and
    /// `0:42` only in the final 60 seconds. Rounds up, so it reads 0:00 only at the end.
    /// Redrawing the menu bar every second cost ~0.9% CPU; this redraws once a minute.
    static func menuBarText(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        if seconds <= 60 { return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)) }
        let minutes = (seconds + 59) / 60
        if minutes >= 60 { return Duration.seconds(minutes * 60).formatted(.time(pattern: .hourMinute)) }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .narrow))
    }

    /// How long until ``menuBarText(_:)`` changes, so the menu bar redraws only then.
    static func secondsUntilMenuBarChange(_ remaining: TimeInterval) -> TimeInterval {
        guard remaining > 0 else { return 1 }
        let seconds = remaining.rounded(.up)
        if seconds <= 60 { return remaining - (seconds - 1) }
        let minutes = (seconds / 60).rounded(.up)
        return remaining - (minutes - 1) * 60
    }

    func remaining(_ row: SessionRow, now: Date) -> String? {
        row.deadline.map { Self.countdownText($0.timeIntervalSince(now)) }
    }

    /// `42:05` under an hour, `1:42:05` from an hour; seconds round up so it reads 0:00 only at the end.
    static func countdownText(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
    }

    func statusAccessibilityLabel(now: Date) -> String {
        guard isAwake else { return String(localized: "uawake: off", comment: "Menu bar icon, VoiceOver") }
        if let countdown = menuBarCountdown(now: now) {
            return String(
                localized: "uawake: keeping your Mac awake, \(countdown) left", comment: "Menu bar icon, VoiceOver")
        }
        return String(localized: "uawake: keeping your Mac awake", comment: "Menu bar icon, VoiceOver")
    }

    // MARK: Hero

    func hero(now: Date) -> Hero {
        let active = engine.sessions.filter { $0.state == .active }
        guard !active.isEmpty else {
            return Hero(kind: .idle, countdown: nil, caption: "", progress: nil, isEndingSoon: false)
        }
        guard let countdown = countdown(now: now),
            let last = active.max(by: { ($0.deadline ?? .distantPast) < ($1.deadline ?? .distantPast) }),
            let deadline = last.deadline
        else {
            return Hero(
                kind: .indefinite, countdown: nil,
                caption: String(localized: "Indefinite", comment: "Preset chip: no end time"), progress: nil,
                isEndingSoon: false)
        }
        let total = deadline.timeIntervalSince(last.startedAt)
        let progress = total > 0 ? min(1, max(0, now.timeIntervalSince(last.startedAt) / total)) : 1
        let time = deadline.formatted(date: .omitted, time: .shortened)
        return Hero(
            kind: .timed, countdown: countdown,
            caption: String(localized: "until \(time)", comment: "Session end; the argument is a time of day"),
            progress: progress, isEndingSoon: isEndingSoon(deadline, now: now))
    }

    /// Within the end-warning lead time (5 min when the warning is off).
    func isEndingSoon(_ deadline: Date, now: Date) -> Bool {
        deadline.timeIntervalSince(now) <= Double((settings.endWarning ?? .seconds(300)).components.seconds)
    }

    // MARK: Banners

    private(set) var guardStops: [Banner] = []

    /// The refusal (if any) first, then the most recent guard stops.
    var banners: [Banner] {
        let refusalBanner = refusal.map {
            Banner(
                kind: .refusal, tone: .caution, symbol: "exclamationmark.triangle.fill",
                title: String(localized: "Can't keep your Mac awake", comment: "Banner title: start refused"),
                message: $0.message, section: $0.section)
        }
        return (refusalBanner.map { [$0] } ?? []) + guardStops
    }

    func dismiss(_ banner: Banner) {
        switch banner.kind {
        case .refusal: refusal = nil
        case .guardStop(let id): guardStops.removeAll { $0.kind == .guardStop(id) }
        }
    }

    func open(_ banner: Banner) {
        openMainWindow(banner.section)
    }

    // MARK: Session events

    /// Today's ended sessions, for "Kept awake today". In memory only; history comes in 1.2.
    private var closedIntervals: [DateInterval] = []
    /// When each session last became active (started or resumed).
    private var activeSince: [Session.ID: Date] = [:]
    /// Paused sessions: already closed, so their end must not count from `startedAt`.
    private var pausedIDs: Set<Session.ID> = []
    /// Sessions whose events this model has seen; for the rest, count from `startedAt`.
    private var seenIDs: Set<Session.ID> = []

    func handle(_ event: SessionEvent, now: Date = Date()) {
        switch event {
        case .started(let session):
            seenIDs.insert(session.id)
            activeSince[session.id] = session.startedAt
        case .resumed(let session):
            pausedIDs.remove(session.id)
            activeSince[session.id] = now
        case .paused(let session):
            close(session, now: now)
            pausedIDs.insert(session.id)
        case .aboutToEnd:
            break
        case .ended(let session):
            close(session, now: now)
            pausedIDs.remove(session.id)
            addGuardBanner(for: session)
        }
    }

    private func close(_ session: Session, now: Date) {
        seenIDs.insert(session.id)
        guard !pausedIDs.contains(session.id) else { return }
        let start = activeSince.removeValue(forKey: session.id) ?? session.startedAt
        if now > start { closedIntervals.append(DateInterval(start: start, end: now)) }
    }

    private func addGuardBanner(for session: Session) {
        guard case .ended(let cause) = session.state, let text = cause.guardText(settings: settings) else { return }
        let banner = Banner(
            kind: .guardStop(session.id), tone: .critical, symbol: "stop.circle.fill",
            title: String(localized: "Stopped by \(text.title)", comment: "Banner title: a guard ended a session"),
            message: String(
                localized: "\(session.title) ended. \(text.detail)",
                comment: "Banner body: session, then why the guard ended it"),
            section: .safety)
        guardStops = Array(([banner] + guardStops).prefix(3))
    }

    /// Time today when at least one session was keeping the Mac awake (overlaps count once).
    /// Paused time is excluded.
    func keptAwakeToday(now: Date, calendar: Calendar = .current) -> Duration {
        let dayStart = calendar.startOfDay(for: now)
        let live = engine.sessions.filter { $0.state == .active }
            .compactMap { activeSince[$0.id] ?? (seenIDs.contains($0.id) ? nil : $0.startedAt) }
            .filter { $0 < now }
            .map { DateInterval(start: $0, end: now) }
        let clipped = (closedIntervals + live).compactMap { interval -> DateInterval? in
            let start = max(interval.start, dayStart)
            let end = min(interval.end, now)
            return start < end ? DateInterval(start: start, end: end) : nil
        }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in clipped.sorted(by: { $0.start < $1.start }) {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                total += current?.duration ?? 0
                current = interval
            }
        }
        total += current?.duration ?? 0
        return .seconds(Int(total))
    }

    /// "3h 20m", "45m", "0m".
    static func keptAwakeText(_ duration: Duration) -> String {
        duration.formatted(
            .units(allowed: [.hours, .minutes], width: .narrow, zeroValueUnits: .hide, fractionalPart: .hide))
    }

    // MARK: Status strip

    /// Battery level, power source and guard state. Empty until the first device-state reading.
    var statusChips: [StatusChip] {
        guard let state = engine.deviceState else { return [] }
        var chips: [StatusChip] = []
        let policy = settings.policy
        if let level = state.batteryLevel {
            let near =
                state.powerSource == .battery && policy.batteryThreshold.map { level <= $0 + 10 } == true
            let text = (Double(level) / 100).formatted(.percent)
            chips.append(
                StatusChip(
                    id: "battery", symbol: Self.batterySymbol(level, charging: state.powerSource == .ac), text: text,
                    tone: near ? .caution : .neutral,
                    accessibilityLabel: String(localized: "Battery \(text)", comment: "Status chip, VoiceOver")))
        }
        switch state.powerSource {
        case .ac:
            chips.append(
                StatusChip(
                    id: "power", symbol: "powerplug.fill",
                    text: String(localized: "Power adapter", comment: "Status chip"), tone: .neutral,
                    accessibilityLabel: String(localized: "On power adapter", comment: "Status chip, VoiceOver")))
        case .battery:
            chips.append(
                StatusChip(
                    id: "power", symbol: "bolt.slash.fill",
                    text: String(localized: "Battery power", comment: "Status chip"), tone: .neutral,
                    accessibilityLabel: String(localized: "On battery power", comment: "Status chip, VoiceOver")))
        case .unknown:
            break
        }
        chips.append(guardChip(state, policy: policy))
        return chips
    }

    private func guardChip(_ state: DeviceState, policy: GuardPolicy) -> StatusChip {
        let anyOn = policy.batteryThreshold != nil || policy.endOnLowPowerMode || policy.endOnThermalPressure
        if !anyOn {
            return StatusChip(
                id: "guards", symbol: "shield.slash", text: String(localized: "Guards off", comment: "Status chip"),
                tone: .neutral, accessibilityLabel: String(localized: "Safety guards are off", comment: "VoiceOver"))
        }
        let critical =
            (policy.endOnLowPowerMode && state.isLowPowerModeEnabled)
            || (policy.endOnThermalPressure && (state.thermalState == .serious || state.thermalState == .critical))
            || (state.powerSource == .battery
                && state.batteryLevel.map { level in
                    policy.batteryThreshold.map { level <= $0 } ?? false
                } == true)
        if critical {
            return StatusChip(
                id: "guards", symbol: "exclamationmark.shield.fill",
                text: String(localized: "Guard active", comment: "Status chip"), tone: .critical,
                accessibilityLabel: String(
                    localized: "A safety guard is stopping sessions", comment: "Status chip, VoiceOver"))
        }
        let near =
            (policy.endOnThermalPressure && state.thermalState == .fair)
            || (state.powerSource == .battery
                && state.batteryLevel.map { level in
                    policy.batteryThreshold.map { level <= $0 + 10 } ?? false
                } == true)
        if near {
            return StatusChip(
                id: "guards", symbol: "exclamationmark.shield",
                text: String(localized: "Near a guard limit", comment: "Status chip"), tone: .caution,
                accessibilityLabel: String(
                    localized: "Guards on; one is near its limit", comment: "Status chip, VoiceOver"))
        }
        return StatusChip(
            id: "guards", symbol: "checkmark.shield.fill", text: String(localized: "Guards on", comment: "Status chip"),
            tone: .good,
            accessibilityLabel: String(localized: "Safety guards are on", comment: "Status chip, VoiceOver"))
    }

    static func batterySymbol(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Actions

    /// Primary click, the global shortcut and the popover's on/off control.
    func toggle() {
        let condition = settings.primaryClickAction
        perform { () throws(SessionEngineError) in
            try engine.toggle(
                SessionRequest(source: .manual, reason: .standard(.manual, condition), endCondition: condition))
        }
    }

    /// A preset chip or the until picker. Replaces running manual sessions; if the
    /// start is refused, they keep running.
    func start(_ condition: EndCondition) {
        perform { () throws(SessionEngineError) in
            let previous = engine.sessions.filter { $0.source == .manual }.map(\.id)
            try engine.start(
                SessionRequest(source: .manual, reason: .standard(.manual, condition), endCondition: condition))
            for id in previous { engine.stop(id, cause: .stoppedByUser) }
        }
    }

    func startUntil() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: untilTime)
        guard let time = ClockTime(hour: components.hour ?? 0, minute: components.minute ?? 0) else { return }
        start(.until(time))
    }

    func extend(_ id: Session.ID, by amount: Duration) {
        perform { () throws(SessionEngineError) in try engine.extend(id, by: amount) }
    }

    func stop(_ id: Session.ID) {
        engine.stop(id, cause: .stoppedByUser)
    }

    func clearRefusal() {
        refusal = nil
    }

    func openRefusalSettings() {
        openMainWindow(refusal?.section)
    }

    private func perform(_ action: () throws(SessionEngineError) -> Void) {
        do {
            try action()
            refusal = nil
        } catch {
            refusal = Self.refusal(for: error, settings: settings)
            showPopover()
        }
    }

    static func refusal(for error: SessionEngineError, settings: UAwakeSettings) -> Refusal {
        switch error {
        case .wouldEndImmediately(.batteryGuard):
            Refusal(
                message: String(
                    localized: "The battery is at or below the \(settings.batteryGuardThreshold)% safety limit.",
                    comment: "Popover: start refused by the battery guard"),
                section: .safety)
        case .wouldEndImmediately(.lowPowerMode):
            Refusal(
                message: String(localized: "Low Power Mode is on.", comment: "Popover: start refused"),
                section: .safety)
        case .wouldEndImmediately(.thermalGuard):
            Refusal(
                message: String(
                    localized: "Your Mac is too warm to keep awake right now.", comment: "Popover: start refused"),
                section: .safety)
        case .wouldEndImmediately(.expired):
            Refusal(
                message: String(
                    localized: "The battery is already at or below that level.", comment: "Popover: start refused"),
                section: nil)
        case .wouldEndImmediately:
            Refusal(
                message: String(localized: "That session would end straight away.", comment: "Popover: start refused"),
                section: nil)
        case .assertionFailed(let code):
            Refusal(
                message: String(
                    localized: "macOS refused to keep your Mac awake (error \(code)).", comment: "Popover: IOKit error"),
                section: nil)
        case .sessionNotFound, .invalidState, .notExtendable:
            Refusal(
                message: String(localized: "That session can't be changed.", comment: "Popover: action refused"),
                section: nil)
        }
    }

    /// An hour from now, rounded up to the next 5 minutes.
    static func defaultUntilTime(from now: Date) -> Date {
        let target = now.addingTimeInterval(3600)
        let interval = 300.0
        return Date(
            timeIntervalSinceReferenceDate: (target.timeIntervalSinceReferenceDate / interval).rounded(.up) * interval)
    }
}

extension EndCondition {
    /// Duration and until-time sessions: they show a countdown and can be extended.
    var hasOwnDeadline: Bool {
        switch self {
        case .duration, .until: true
        case .indefinite, .batteryLevel: false
        }
    }
}
