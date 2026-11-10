import Foundation
import Observation
import os

/// "Pause all rules". Manual and other sessions are unaffected.
public enum RulePause: Equatable, Sendable {
    case until(Date)
    case indefinitely

    /// "Until tomorrow, 6:00": 06:00 local time on the next calendar day.
    public static func untilTomorrowMorning(from now: Date, calendar: Calendar) -> RulePause {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now + 86_400
        return .until(calendar.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow) ?? tomorrow + 21_600)
    }
}

/// What a rule is doing right now, for the rules list and the popover.
public enum RuleStatus: Equatable, Sendable {
    /// Disabled.
    case off
    /// All rules are paused.
    case paused
    /// Enabled, conditions not met.
    case idle
    case outsideHours
    /// A condition needs a permission that has not been granted. The rule stays inactive.
    case needsPermission(RulePermission)
    /// Conditions met; the rule holds a session.
    case matching
    /// Conditions no longer met; the session ends at `until` unless they return.
    case lingering(until: Date)
    /// The user stopped the rule's session. Off until the conditions clear and return.
    case stoppedByUser
    /// A guard ended or refused the session. The rule restarts by itself once no guard has
    /// applied for the cool-down; `until` is that moment, or `nil` while a guard still applies.
    case waiting(EndCause, until: Date?)
    /// The power assertion could not be created; retried at the next evaluation.
    case failed
}

public enum ConditionState: Equatable, Sendable {
    case met, notMet
    case unavailable(RulePermission)
}

/// A condition's live value against its threshold, for the editor's Test view.
public struct ConditionReading: Equatable, Sendable {
    public var state: ConditionState
    public var value: ReadingValue
}

public enum ReadingValue: Equatable, Sendable {
    /// Nothing to show beyond met / not met.
    case none
    /// The raw on/off value, before any settle time.
    case flag(Bool)
    /// E.g. the frontmost app's bundle id or the current Wi-Fi name.
    case text(String?)
    /// E.g. connected displays or devices, or events in progress.
    case names([String])
    /// An averaged measurement (CPU percent or bytes per second); `nil` until a full window is sampled.
    case level(current: Double?, threshold: Double)
}

/// Starts and stops rule sessions. It receives signals from the system monitors,
/// evaluates each rule as a pure function of them and the clock, and drives the
/// ``SessionEngine`` with source `.rule`. It never touches power assertions itself.
///
/// The app must forward: every `DeviceState` (after `SessionEngine.apply`) as
/// `.power`, every ``SessionEvent`` and every ``SessionLifecycleEvent``.
@MainActor
@Observable
public final class RuleEngine {
    /// A camera or microphone must be in use this long before a call counts.
    public static let callSettle: TimeInterval = 3
    /// Output must be running this long, so alert sounds don't start sessions.
    public static let audioSettle: TimeInterval = 5

    public private(set) var rules: [Rule]
    public private(set) var statuses: [Rule.ID: RuleStatus] = [:]
    public private(set) var pause: RulePause?
    /// Conditions whose permission is not `.granted` are unavailable.
    public var permissions: [RulePermission: PermissionStatus] = [:] {
        didSet { if permissions != oldValue { evaluate() } }
    }
    /// A draft being edited: its signals are kept flowing so ``readings(for:)`` is live.
    public var preview: Rule?

    private var inputs = Inputs()
    @ObservationIgnored private var runtime: [Rule.ID: Runtime] = [:]
    @ObservationIgnored private var frozen = false
    /// When the guards last stopped applying; `nil` while one applies.
    @ObservationIgnored private var guardClearedAt: Date?
    @ObservationIgnored private let engine: any SessionEngine
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private let guards: [any Guard]
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let guardCooldown: TimeInterval
    /// Sleeps until the next settle, linger, boundary or pause end. Internal so tests can await it.
    @ObservationIgnored private(set) var timerTask: Task<Void, Never>?
    @ObservationIgnored private(set) var nextWake: Date?
    @ObservationIgnored private let logger = Logger(subsystem: "com.underscoretec.uawake", category: "core")

    public init(
        engine: any SessionEngine,
        clock: any SessionClock,
        guards: [any Guard] = DefaultSessionEngine.standardGuards,
        calendar: Calendar = .autoupdatingCurrent,
        rules: [Rule] = [],
        pause: RulePause? = nil,
        guardCooldown: TimeInterval = 300
    ) {
        self.engine = engine
        self.clock = clock
        self.guards = guards
        self.calendar = calendar
        self.rules = rules
        self.pause = pause
        self.guardCooldown = guardCooldown
        evaluate()
    }

    // MARK: Inputs

    /// Replaces the rule set. A rule that changed (or went away) gives up its session, but a
    /// changed rule that still matches starts its new session first, so there is never a
    /// moment without an assertion. Editing also re-arms a held rule.
    public func setRules(_ new: [Rule]) {
        let old = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var stale: [Session.ID] = []
        for (id, state) in runtime where kept[id] != old[id] {
            if let session = state.sessionID { stale.append(session) }
            runtime[id] = nil
        }
        rules = new
        evaluate()
        for session in stale { engine.stop(session, cause: .stoppedByUser) }
    }

    /// Pauses all rules (ending their sessions at once) or, with `nil`, resumes them.
    public func setPause(_ new: RulePause?) {
        pause = new
        evaluate()
    }

    public func update(_ signal: Signal) {
        let now = clock.now
        func since(_ on: Bool, _ previous: Date?) -> Date? { on ? previous ?? now : nil }
        switch signal {
        case .apps(let value):
            guard inputs.apps != value else { return }
            inputs.apps = value
        case .mediaUse(let value):
            guard inputs.media != value else { return }
            inputs.media = value
            inputs.cameraSince = since(value.cameraInUse, inputs.cameraSince)
            inputs.microphoneSince = since(value.microphoneInUse, inputs.microphoneSince)
        case .audioPlaying(let value):
            guard inputs.audio != value else { return }
            inputs.audio = value
            inputs.audioSince = since(value, inputs.audioSince)
        case .load(let sample):
            inputs.samples.append((now, sample))
            inputs.samples.removeAll { $0.date < now - TimeInterval(Condition.windowRange.upperBound) - 60 }
        case .power(let value):
            guard inputs.power != value else { return }
            inputs.power = value
        case .displays(let value):
            guard inputs.displays != value else { return }
            inputs.displays = value
        case .usbDevices(let value):
            guard inputs.usb != value else { return }
            inputs.usb = value
        case .bluetoothDevices(let value):
            guard inputs.bluetooth != value else { return }
            inputs.bluetooth = value
        case .wifi(let value):
            guard inputs.wifi != value else { return }
            inputs.wifi = value
        case .calendar(let value):
            guard inputs.calendar != value else { return }
            inputs.calendar = value
        }
        evaluate()
    }

    /// Forgets a monitor's last value when it stops, so a rule enabled later never acts on
    /// stale data before the monitor reports again.
    public func reset(_ kind: SignalKind) {
        switch kind {
        case .apps: inputs.apps = nil
        case .mediaUse: (inputs.media, inputs.cameraSince, inputs.microphoneSince) = (nil, nil, nil)
        case .audioPlaying: (inputs.audio, inputs.audioSince) = (nil, nil)
        case .load: inputs.samples = []
        case .power: break  // Always fed.
        case .displays: inputs.displays = nil
        case .usbDevices: inputs.usb = nil
        case .bluetoothDevices: inputs.bluetooth = nil
        case .wifi: inputs.wifi = nil
        case .calendar: inputs.calendar = []
        }
        evaluate()
    }

    /// Reacts to a rule session ending from outside: a guard puts the rule in
    /// ``RuleStatus/waiting(_:until:)``, the user's stop holds it for the rest of the episode.
    public func handle(_ event: SessionEvent) {
        guard case .ended(let session) = event, case .ended(let cause) = session.state,
            let id = runtime.first(where: { $0.value.sessionID == session.id })?.key
        else { return }
        runtime[id]?.sessionID = nil
        switch cause {
        case .batteryGuard, .lowPowerMode, .thermalGuard, .maximumCap:
            runtime[id]?.hold = .guardEnded(cause)
            guardClearedAt = nil  // the cool-down starts from here at the earliest
        case .stoppedByUser:
            runtime[id]?.hold = .user
        case .expired, .appQuit:
            runtime[id] = nil
        }
        evaluate()
    }

    /// While the user session is inactive (fast user switching) nothing starts or ends;
    /// on return and on wake every rule is evaluated afresh.
    public func handle(_ event: SessionLifecycleEvent) {
        switch event {
        case .userSessionDidResignActive:
            frozen = true
            timerTask?.cancel()
        case .userSessionDidBecomeActive:
            frozen = false
            evaluate()
        case .systemWillSleep:
            break
        case .systemDidWake:
            // Samples spanning the sleep are meaningless, and in-use flags settle again.
            let now = clock.now
            inputs.samples.removeAll()
            inputs.cameraSince = inputs.cameraSince.map { _ in now }
            inputs.microphoneSince = inputs.microphoneSince.map { _ in now }
            inputs.audioSince = inputs.audioSince.map { _ in now }
            evaluate()
        }
    }

    /// Call after anything else that can change the outcome: guard policy, time zone, clock.
    public func reevaluate() { evaluate() }

    // MARK: Outputs

    /// The monitors worth running: those read by enabled rules (unless paused) and by the
    /// previewed draft, leaving out any whose permission is missing. `.power` is always fed.
    public var neededSignals: Set<SignalKind> {
        var conditions = preview?.conditions ?? []
        if pause == nil { conditions += rules.filter(\.enabled).flatMap(\.conditions) }
        var kinds = Set(conditions.filter { missingPermission($0) == nil }.compactMap(\.signal))
        kinds.remove(.power)
        return kinds
    }

    public func sessionID(for rule: Rule.ID) -> Session.ID? { runtime[rule]?.sessionID }

    public func rule(forSession id: Session.ID) -> Rule? {
        runtime.first { $0.value.sessionID == id }.flatMap { entry in rules.first { $0.id == entry.key } }
    }

    /// Live values for each of the rule's conditions, in order.
    public func readings(for rule: Rule) -> [ConditionReading] {
        var wakes: [Date] = []
        return rule.conditions.map { reading($0, now: clock.now, wakes: &wakes) }
    }

    /// Whether the conditions alone match (ignoring enabled, pause and active hours).
    public func conditionsMatch(_ rule: Rule) -> Bool {
        Self.matches(rule, readings(for: rule))
    }

    // MARK: Evaluation

    private struct Inputs {
        var apps: AppsState?
        var media: MediaUse?
        var cameraSince: Date?
        var microphoneSince: Date?
        var audio: Bool?
        var audioSince: Date?
        var samples: [(date: Date, sample: LoadSample)] = []
        var power: DeviceState?
        var displays: [DisplayInfo]?
        var usb: [ConnectedDevice]?
        var bluetooth: [ConnectedDevice]?
        var wifi: String?
        var calendar: [CalendarEvent] = []
    }

    private enum Hold: Equatable {
        case user
        case guardEnded(EndCause)
    }

    /// One rule's episode: from first match until not matching for the linger time.
    private struct Runtime {
        var sessionID: Session.ID?
        var hold: Hold?
        var notMatchingSince: Date?
    }

    private static func matches(_ rule: Rule, _ readings: [ConditionReading]) -> Bool {
        guard !readings.isEmpty, !readings.contains(where: { if case .unavailable = $0.state { true } else { false } })
        else { return false }
        let met = readings.map { $0.state == .met }
        return rule.match == .all ? !met.contains(false) : met.contains(true)
    }

    private func evaluate() {
        guard !frozen else { return }
        let now = clock.now
        var wakes: [Date] = []
        if case .until(let end) = pause {
            if end <= now { pause = nil } else { wakes.append(end) }
        }
        let applying = applyingGuard(now: now)
        if applying != nil { guardClearedAt = nil } else if guardClearedAt == nil { guardClearedAt = now }

        var new: [Rule.ID: RuleStatus] = [:]
        for rule in rules {
            var state = runtime[rule.id] ?? Runtime()
            new[rule.id] = status(of: rule, &state, now: now, applying: applying, wakes: &wakes)
            runtime[rule.id] = state.sessionID == nil && state.hold == nil ? nil : state
        }
        if new != statuses { statuses = new }
        rearm(wakes, now: now)
    }

    private func status(
        of rule: Rule, _ state: inout Runtime, now: Date, applying: EndCause?, wakes: inout [Date]
    ) -> RuleStatus {
        func end(_ cause: EndCause) {
            if let session = state.sessionID { engine.stop(session, cause: cause) }
            state = Runtime()
        }
        guard rule.enabled, rule.isValid else {
            end(.stoppedByUser)
            return .off
        }
        guard pause == nil else {
            end(.stoppedByUser)
            return .paused
        }
        if let hours = rule.activeHours {
            if let boundary = hours.nextBoundary(after: now, calendar: calendar) { wakes.append(boundary) }
            guard hours.contains(now, calendar: calendar) else {
                end(.expired)
                return .outsideHours
            }
        }
        let readings = rule.conditions.map { reading($0, now: now, wakes: &wakes) }
        let missing = readings.lazy.compactMap { if case .unavailable(let p) = $0.state { p } else { nil } }.first
        let resting: RuleStatus = missing.map { .needsPermission($0) } ?? .idle

        guard Self.matches(rule, readings) else {
            guard state.sessionID != nil || state.hold != nil else { return resting }
            let since = state.notMatchingSince ?? now
            state.notMatchingSince = since
            let lingerEnd = since + TimeInterval(rule.lingerSeconds)
            guard lingerEnd > now else {
                end(.expired)
                return resting
            }
            wakes.append(lingerEnd)
            if state.sessionID != nil { return .lingering(until: lingerEnd) }
            if case .guardEnded(let cause) = state.hold { return .waiting(applying ?? cause, until: nil) }
            return .stoppedByUser
        }

        state.notMatchingSince = nil
        if state.sessionID != nil { return .matching }
        let cooledAt = guardClearedAt.map { $0 + guardCooldown }
        switch state.hold {
        case .user:
            return .stoppedByUser
        case .guardEnded(let cause):
            guard let cooledAt, cooledAt <= now else {
                if let cooledAt { wakes.append(cooledAt) }
                return .waiting(applying ?? cause, until: cooledAt)
            }
        case nil:
            break
        }
        state.hold = nil
        do throws(SessionEngineError) {
            let request = SessionRequest(
                source: .rule, reason: .rule(name: rule.name), modes: rule.modes, endCondition: .indefinite)
            state.sessionID = try engine.start(request).id
            return .matching
        } catch {
            guard case .wouldEndImmediately(let cause) = error else {
                logger.error("Rule session failed to start: \(String(describing: error), privacy: .public)")
                return .failed
            }
            state.hold = .guardEnded(cause)
            let retry = (guardClearedAt ?? now) + guardCooldown
            if retry > now { wakes.append(retry) }
            return .waiting(cause, until: applying == nil ? retry : nil)
        }
    }

    /// The guard that would end a rule session right now, if any.
    private func applyingGuard(now: Date) -> EndCause? {
        guard let power = inputs.power else { return nil }
        let probe = Session(
            source: .rule, reason: .rule(name: ""), modes: [.system], endCondition: .indefinite, startedAt: now,
            deadline: nil)
        return guards.lazy.flatMap { $0.evaluate(power, sessions: [probe], policy: self.engine.policy) }.first?.cause
    }

    private func missingPermission(_ condition: Condition) -> RulePermission? {
        condition.permission.flatMap { permissions[$0] == .granted ? nil : $0 }
    }

    /// Evaluates one condition. Appends to `wakes` any future moment at which the answer
    /// can change without a new signal (settle times, schedule and calendar boundaries).
    private func reading(_ condition: Condition, now: Date, wakes: inout [Date]) -> ConditionReading {
        if let permission = missingPermission(condition) {
            return ConditionReading(state: .unavailable(permission), value: .none)
        }
        func result(_ met: Bool, _ value: ReadingValue) -> ConditionReading {
            ConditionReading(state: met ? .met : .notMet, value: value)
        }
        func settled(_ since: Date?, _ settle: TimeInterval) -> Bool {
            guard let since else { return false }
            if since + settle > now { wakes.append(since + settle) }
            return since + settle <= now
        }
        switch condition {
        case .appRunning(let app):
            return result(inputs.apps?.running.contains(app.bundleID) == true, .none)
        case .appFrontmost(let app):
            return result(inputs.apps?.frontmost == app.bundleID, .text(inputs.apps?.frontmost))
        case .call(let camera, let microphone):
            let inUse =
                (camera && inputs.media?.cameraInUse == true) || (microphone && inputs.media?.microphoneInUse == true)
            let cameraMet = camera && settled(inputs.cameraSince, Self.callSettle)
            let microphoneMet = microphone && settled(inputs.microphoneSince, Self.callSettle)
            return result(cameraMet || microphoneMet, .flag(inUse))
        case .audioPlaying:
            return result(settled(inputs.audioSince, Self.audioSettle), .flag(inputs.audio == true))
        case .cpuBusy(let percent, let window):
            let average = average(over: window, now: now, \.cpuPercent)
            return result(
                average.map { $0 >= Double(percent) } ?? false, .level(current: average, threshold: Double(percent)))
        case .networkBusy(let rate, let direction, let window):
            let average = average(over: window, now: now) {
                switch direction {
                case .download: $0.bytesInPerSecond
                case .upload: $0.bytesOutPerSecond
                case .both: $0.bytesInPerSecond + $0.bytesOutPerSecond
                }
            }
            return result(
                average.map { $0 >= Double(rate) } ?? false, .level(current: average, threshold: Double(rate)))
        case .powerAdapter:
            return result(inputs.power?.powerSource == .ac, .none)
        case .externalDisplay(let name):
            let external = (inputs.displays ?? []).filter { !$0.isBuiltIn }.map(\.name)
            return result(name.map(external.contains) ?? !external.isEmpty, .names(external))
        case .device(let kind, let id, _):
            let devices = (kind == .usb ? inputs.usb : inputs.bluetooth) ?? []
            return result(devices.contains { $0.id == id }, .names(devices.map(\.name)))
        case .wifi(let ssid):
            return result(inputs.wifi == ssid, .text(inputs.wifi))
        case .calendarEvent(let calendarID, _, let keyword):
            let relevant = inputs.calendar.filter { event in
                (calendarID == nil || event.calendarID == calendarID)
                    && (keyword.map {
                        event.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    } ?? true)
            }
            wakes += relevant.flatMap { [$0.start, $0.end] }.filter { $0 > now }
            let current = relevant.filter { $0.start <= now && now < $0.end }
            return result(!current.isEmpty, .names(current.map(\.title)))
        case .schedule(let window):
            if let boundary = window.nextBoundary(after: now, calendar: calendar) { wakes.append(boundary) }
            return result(window.contains(now, calendar: calendar), .none)
        }
    }

    /// The time-weighted average of the samples in the window ending at the latest sample;
    /// `nil` until the samples cover at least 90% of the window, or when they are stale.
    private func average(over window: Int, now: Date, _ value: (LoadSample) -> Double) -> Double? {
        guard let latest = inputs.samples.last?.date, latest > now - 30 else { return nil }
        let recent = inputs.samples.filter { $0.date > latest - TimeInterval(window) }
        let covered = recent.reduce(0) { $0 + $1.sample.interval }
        guard covered >= TimeInterval(window) * 0.9 else { return nil }
        return recent.reduce(0) { $0 + value($1.sample) * $1.sample.interval } / covered
    }

    private func rearm(_ wakes: [Date], now: Date) {
        timerTask?.cancel()
        let next = wakes.filter { $0 > now }.min()
        nextWake = next
        guard let next else {
            timerTask = nil
            return
        }
        timerTask = Task { [clock] in
            do { try await clock.sleep(until: next) } catch { return }
            self.evaluate()
        }
    }
}
