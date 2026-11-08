import Foundation
import Observation
import os

/// The production ``SessionEngine``.
@MainActor
@Observable
public final class DefaultSessionEngine: SessionEngine {
    public private(set) var sessions: [Session] = []

    public var policy: GuardPolicy {
        didSet { applyCap() }
    }

    @ObservationIgnored private let assertions: any AssertionProvider
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private let guards: [any Guard]
    @ObservationIgnored private var handles: [Session.ID: AssertionHandle] = [:]
    @ObservationIgnored private var endedContinuations: [UUID: AsyncStream<Session>.Continuation] = [:]
    /// Sleeps until the earliest active deadline. Internal so tests can await it.
    @ObservationIgnored private(set) var timerTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.underscoretec.uawake", category: "core")

    public init(
        assertions: any AssertionProvider,
        clock: any SessionClock,
        guards: [any Guard] = [],
        policy: GuardPolicy = GuardPolicy()
    ) {
        self.assertions = assertions
        self.clock = clock
        self.guards = guards
        self.policy = policy
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
        handles[session.id] = try assertions.acquire(modes: session.modes, reason: session.reason.englishDescription)
        sessions.append(session)
        logger.info("Started \(session.reason.englishDescription, privacy: .public)")
        rearm()
        return session
    }

    public func stop(_ id: Session.ID, cause: EndCause) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions.remove(at: index)
        if let handle = handles.removeValue(forKey: id) { assertions.release(handle) }
        session.state = .ended(cause)
        logger.info("Ended \(session.reason.englishDescription, privacy: .public): \(cause.rawValue, privacy: .public)")
        for continuation in endedContinuations.values { continuation.yield(session) }
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
        switch sessions[index].endCondition {
        case .duration, .until: break
        case .indefinite, .batteryLevel: throw .notExtendable
        }
        switch sessions[index].state {
        case .active: sessions[index].deadline = sessions[index].deadline.map { $0 + amount.timeInterval }
        case .paused(let remaining): sessions[index].state = .paused(remaining: remaining.map { $0 + amount })
        case .ended: throw .invalidState
        }
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
        rearm()
    }

    public func resume(_ id: Session.ID) throws(SessionEngineError) {
        let index = try index(of: id)
        guard case .paused(let remaining) = sessions[index].state else { throw .invalidState }
        let session = sessions[index]
        handles[id] = try assertions.acquire(modes: session.modes, reason: session.reason.englishDescription)
        sessions[index].state = .active
        sessions[index].deadline = remaining.map { clock.now + $0.timeInterval } ?? capDeadline(for: session)
        expireDue()
    }

    // MARK: Device state and lifecycle

    public func apply(_ state: DeviceState) {
        if state.powerSource == .battery, let level = state.batteryLevel {
            for session in sessions where session.state == .active {
                if case .batteryLevel(let threshold) = session.endCondition, level <= threshold {
                    stop(session.id, cause: .expired)
                }
            }
        }
        for verdict in guards.flatMap({ $0.evaluate(state, sessions: sessions, policy: policy) }) {
            stop(verdict.sessionID, cause: verdict.cause)
        }
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
            expireDue()
        }
    }

    public func endedSessions() -> AsyncStream<Session> {
        let (stream, continuation) = AsyncStream.makeStream(of: Session.self)
        let key = UUID()
        endedContinuations[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.endedContinuations[key] = nil }
        }
        return stream
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
        switch session.endCondition {
        case .indefinite, .batteryLevel: true
        case .duration, .until: false
        }
    }

    private func remainingTime(_ session: Session) -> Duration? {
        session.deadline.map { .seconds(max(0, $0.timeIntervalSince(clock.now))) }
    }

    private func applyCap() {
        for index in sessions.indices where sessions[index].state == .active && Self.isCapped(sessions[index]) {
            sessions[index].deadline = capDeadline(for: sessions[index])
        }
        expireDue()
    }

    /// Ends active sessions whose deadline has passed, then re-arms the timer.
    private func expireDue() {
        let now = clock.now
        for session in sessions where session.state == .active {
            if let deadline = session.deadline, deadline <= now {
                stop(session.id, cause: Self.isCapped(session) ? .maximumCap : .expired)
            }
        }
        rearm()
    }

    private func rearm() {
        timerTask?.cancel()
        let next = sessions.filter { $0.state == .active }.compactMap(\.deadline).min()
        guard let next else {
            timerTask = nil
            return
        }
        timerTask = Task { [clock] in
            do { try await clock.sleep(until: next) } catch { return }
            self.expireDue()
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
