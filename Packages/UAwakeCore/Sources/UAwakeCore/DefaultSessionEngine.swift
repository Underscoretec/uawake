import Foundation
import Observation
import os

/// The production ``SessionEngine``.
@MainActor
@Observable
public final class DefaultSessionEngine: SessionEngine {
    public private(set) var sessions: [Session] = []

    public var policy: GuardPolicy {
        didSet {
            guard policy != oldValue else { return }
            applyCap()
            applyDeviceState()
        }
    }

    public var endWarning: Duration? {
        didSet { if endWarning != oldValue { tick() } }
    }

    /// The last state passed to ``apply(_:)``; `nil` until the first one.
    public private(set) var deviceState: DeviceState?

    @ObservationIgnored private let assertions: any AssertionProvider
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private let guards: [any Guard]
    @ObservationIgnored private var handles: [Session.ID: AssertionHandle] = [:]
    /// Sessions already warned (or too short to warn) for their current deadline.
    @ObservationIgnored private var warned: Set<Session.ID> = []
    @ObservationIgnored private var eventContinuations: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    /// Sleeps until the next deadline or warning. Internal so tests can await it.
    @ObservationIgnored private(set) var timerTask: Task<Void, Never>?
    /// When ``timerTask`` fires. Internal so tests know whether advancing time reaches it.
    @ObservationIgnored private(set) var nextWake: Date?
    @ObservationIgnored private let logger = Logger(subsystem: "com.underscoretec.uawake", category: "core")

    public init(
        assertions: any AssertionProvider,
        clock: any SessionClock,
        guards: [any Guard] = [],
        policy: GuardPolicy = GuardPolicy(),
        endWarning: Duration? = nil
    ) {
        self.assertions = assertions
        self.clock = clock
        self.guards = guards
        self.policy = policy
        self.endWarning = endWarning
    }

    // MARK: Start and stop

    @discardableResult
    public func start(_ request: SessionRequest) throws(SessionEngineError) -> Session {
        let now = clock.now
        var session = Session(
            source: request.source,
            reason: request.reason,
            modes: request.modes,
            endCondition: request.endCondition,
            startedAt: now,
            deadline: nil
        )
        session.deadline = ownDeadline(for: session.endCondition, from: now) ?? capDeadline(for: session)
        if let cause = immediateEnd(of: session) { throw .wouldEndImmediately(cause) }
        handles[session.id] = try assertions.acquire(modes: session.modes, reason: session.reason.englishDescription)
        sessions.append(session)
        if !Self.isWarnable(session) || isTooShortToWarn(session, from: now) { warned.insert(session.id) }
        logger.info("Started \(session.reason.englishDescription, privacy: .public)")
        emit(.started(session))
        rearm()
        return session
    }

    public func stop(_ id: Session.ID, cause: EndCause) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions.remove(at: index)
        if let handle = handles.removeValue(forKey: id) { assertions.release(handle) }
        warned.remove(id)
        session.state = .ended(cause)
        logger.info("Ended \(session.reason.englishDescription, privacy: .public): \(cause.rawValue, privacy: .public)")
        emit(.ended(session))
        rearm()
    }

    public func stopAll(source: SessionSource, cause: EndCause) {
        for session in sessions where session.source == source { stop(session.id, cause: cause) }
    }

    @discardableResult
    public func toggle(_ request: SessionRequest) throws(SessionEngineError) -> Session? {
        let toggleable: Set<SessionSource> = [.manual, .url]
        guard sessions.contains(where: { toggleable.contains($0.source) }) else { return try start(request) }
        for source in toggleable { stopAll(source: source, cause: .stoppedByUser) }
        return nil
    }

    // MARK: Extend, pause, resume

    public func extend(_ id: Session.ID, by amount: Duration) throws(SessionEngineError) {
        let index = try index(of: id)
        guard Self.isWarnable(sessions[index]) else { throw .notExtendable }
        switch sessions[index].state {
        case .active: sessions[index].deadline = sessions[index].deadline.map { $0 + amount.timeInterval }
        case .paused(let remaining): sessions[index].state = .paused(remaining: remaining.map { $0 + amount })
        case .ended: throw .invalidState
        }
        warned.remove(id)
        rearm()
    }

    public func pause(_ id: Session.ID) throws(SessionEngineError) {
        let index = try index(of: id)
        guard sessions[index].state == .active else { throw .invalidState }
        let session = sessions[index]
        let remaining = Self.isCapped(session) ? nil : remainingTime(session)
        if let handle = handles.removeValue(forKey: id) { assertions.release(handle) }
        sessions[index].state = .paused(remaining: remaining)
        sessions[index].deadline = nil
        logger.info("Paused \(session.reason.englishDescription, privacy: .public)")
        emit(.paused(sessions[index]))
        rearm()
    }

    public func resume(_ id: Session.ID) throws(SessionEngineError) {
        let index = try index(of: id)
        guard case .paused(let remaining) = sessions[index].state else { throw .invalidState }
        let session = sessions[index]
        handles[id] = try assertions.acquire(modes: session.modes, reason: session.reason.englishDescription)
        sessions[index].state = .active
        sessions[index].deadline = remaining.map { clock.now + $0.timeInterval } ?? capDeadline(for: session)
        logger.info("Resumed \(session.reason.englishDescription, privacy: .public)")
        emit(.resumed(sessions[index]))
        tick()
    }

    // MARK: Device state and lifecycle

    public func apply(_ state: DeviceState) {
        deviceState = state
        applyDeviceState()
    }

    public func handle(_ event: SessionLifecycleEvent) {
        switch event {
        case .userSessionDidResignActive:
            for session in sessions where session.state == .active { try? pause(session.id) }
        case .userSessionDidBecomeActive:
            for session in sessions where session.state != .active {
                do throws(SessionEngineError) {
                    try resume(session.id)
                } catch {
                    logger.error("Resume failed: \(String(describing: error), privacy: .public)")
                }
            }
        case .systemWillSleep:
            break
        case .systemDidWake:
            tick()
        }
    }

    public func events() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        let key = UUID()
        eventContinuations[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.eventContinuations[key] = nil }
        }
        return stream
    }

    private func emit(_ event: SessionEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    // MARK: Guards

    /// Ends sessions whose battery level is reached, then whatever the guards return.
    private func applyDeviceState() {
        guard let state = deviceState else { return }
        for session in sessions where Self.batteryLevelReached(session, state) { stop(session.id, cause: .expired) }
        for verdict in guards.flatMap({ $0.evaluate(state, sessions: sessions, policy: policy) }) {
            stop(verdict.sessionID, cause: verdict.cause)
        }
    }

    private func immediateEnd(of session: Session) -> EndCause? {
        guard let state = deviceState else { return nil }
        if Self.batteryLevelReached(session, state) { return .expired }
        return guards.lazy.flatMap { $0.evaluate(state, sessions: [session], policy: self.policy) }.first?.cause
    }

    private static func batteryLevelReached(_ session: Session, _ state: DeviceState) -> Bool {
        guard case .batteryLevel(let threshold) = session.endCondition, state.powerSource == .battery,
            let level = state.batteryLevel
        else { return false }
        return level <= threshold
    }

    // MARK: Deadlines

    private func index(of id: Session.ID) throws(SessionEngineError) -> Int {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw .sessionNotFound }
        return index
    }

    private func ownDeadline(for condition: EndCondition, from now: Date) -> Date? {
        switch condition {
        case .duration(let duration):
            return now + duration.timeInterval
        case .until(let time):
            let components = DateComponents(hour: time.hour, minute: time.minute)
            return Calendar.current.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        case .indefinite, .batteryLevel:
            return nil
        }
    }

    /// `startedAt + cap` for indefinite and battery-level sessions; `nil` otherwise or when the cap is off.
    private func capDeadline(for session: Session) -> Date? {
        guard Self.isCapped(session), let cap = policy.maximumCap else { return nil }
        return session.startedAt + cap.timeInterval
    }

    private static func isCapped(_ session: Session) -> Bool {
        !isWarnable(session)
    }

    /// `duration` and `until` sessions: they can be extended and are warned before they end.
    private static func isWarnable(_ session: Session) -> Bool {
        switch session.endCondition {
        case .duration, .until: true
        case .indefinite, .batteryLevel: false
        }
    }

    private func isTooShortToWarn(_ session: Session, from now: Date) -> Bool {
        guard let deadline = session.deadline, let endWarning else { return false }
        return deadline.timeIntervalSince(now) <= endWarning.timeInterval
    }

    private func warningTime(_ session: Session) -> Date? {
        guard !warned.contains(session.id), let deadline = session.deadline, let endWarning else { return nil }
        return deadline - endWarning.timeInterval
    }

    private func remainingTime(_ session: Session) -> Duration? {
        session.deadline.map { .seconds(max(0, $0.timeIntervalSince(clock.now))) }
    }

    private func applyCap() {
        for index in sessions.indices where sessions[index].state == .active && Self.isCapped(sessions[index]) {
            sessions[index].deadline = capDeadline(for: sessions[index])
        }
        tick()
    }

    /// Ends active sessions whose deadline has passed, emits due warnings, then re-arms the timer.
    private func tick() {
        let now = clock.now
        for session in sessions where session.state == .active {
            if let deadline = session.deadline, deadline <= now {
                stop(session.id, cause: Self.isCapped(session) ? .maximumCap : .expired)
            } else if let warning = warningTime(session), warning <= now {
                warned.insert(session.id)
                emit(.aboutToEnd(session))
            }
        }
        rearm()
    }

    private func rearm() {
        timerTask?.cancel()
        let active = sessions.filter { $0.state == .active }
        let next = (active.compactMap(\.deadline) + active.compactMap(warningTime)).min()
        nextWake = next
        guard let next else {
            timerTask = nil
            return
        }
        timerTask = Task { [clock] in
            do { try await clock.sleep(until: next) } catch { return }
            self.tick()
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
