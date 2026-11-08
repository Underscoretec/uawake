import Foundation
import Observation
import UAwakeCore

enum SettingsTab: String, CaseIterable, Hashable {
    case general, durations, safety, appearance, about
}

/// Why a start was refused, and which settings tab can change it.
struct Refusal: Equatable {
    let message: String
    let settingsTab: SettingsTab?
}

struct SessionRow: Identifiable, Equatable {
    let id: Session.ID
    let title: String
    let sourceName: String
    /// The session's own end (duration or until-time); `nil` for indefinite and battery-level.
    let deadline: Date?
    let isPaused: Bool
    /// Extend is offered only for sessions with a deadline.
    let canExtend: Bool

    init(_ session: Session) {
        id = session.id
        title = session.reason.localizedDescription
        sourceName = session.source.localizedName
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

    @ObservationIgnored var openSettings: (SettingsTab?) -> Void = { _ in }
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

    /// Time until the Mac may sleep again: the latest deadline, shown only when every
    /// active session has its own deadline. `nil` while any indefinite or battery-level
    /// session runs, or when nothing is active.
    func countdown(now: Date) -> String? {
        let active = engine.sessions.filter { $0.state == .active }
        guard !active.isEmpty, active.allSatisfy({ $0.endCondition.hasOwnDeadline }),
            let latest = active.compactMap(\.deadline).max()
        else { return nil }
        return Self.countdownText(latest.timeIntervalSince(now))
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
        if let countdown = countdown(now: now) {
            return String(
                localized: "uawake: keeping your Mac awake, \(countdown) left", comment: "Menu bar icon, VoiceOver")
        }
        return String(localized: "uawake: keeping your Mac awake", comment: "Menu bar icon, VoiceOver")
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
        openSettings(refusal?.settingsTab)
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
                settingsTab: .safety)
        case .wouldEndImmediately(.lowPowerMode):
            Refusal(
                message: String(localized: "Low Power Mode is on.", comment: "Popover: start refused"),
                settingsTab: .safety)
        case .wouldEndImmediately(.thermalGuard):
            Refusal(
                message: String(
                    localized: "Your Mac is too warm to keep awake right now.", comment: "Popover: start refused"),
                settingsTab: .safety)
        case .wouldEndImmediately(.expired):
            Refusal(
                message: String(
                    localized: "The battery is already at or below that level.", comment: "Popover: start refused"),
                settingsTab: nil)
        case .wouldEndImmediately:
            Refusal(
                message: String(localized: "That session would end straight away.", comment: "Popover: start refused"),
                settingsTab: nil)
        case .assertionFailed(let code):
            Refusal(
                message: String(
                    localized: "macOS refused to keep your Mac awake (error \(code)).", comment: "Popover: IOKit error"),
                settingsTab: nil)
        case .sessionNotFound, .invalidState, .notExtendable:
            Refusal(
                message: String(localized: "That session can't be changed.", comment: "Popover: action refused"),
                settingsTab: nil)
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
