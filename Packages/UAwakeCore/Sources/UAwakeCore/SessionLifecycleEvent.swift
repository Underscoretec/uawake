/// User-session and sleep/wake events the engine reacts to. Produced by
/// `SessionLifecycleMonitor` in UAwakeSystem; lives in Core so the engine can consume it.
public enum SessionLifecycleEvent: Equatable, Sendable {
    /// Fast user switching away from this user. The engine pauses active sessions.
    case userSessionDidResignActive
    /// This user is back. The engine resumes the sessions it paused.
    case userSessionDidBecomeActive
    /// Forced sleep (lid closed, Apple menu Sleep). Sessions keep their deadlines.
    case systemWillSleep
    /// After wake the engine ends sessions whose deadline passed during sleep
    /// and re-arms its timer for the rest.
    case systemDidWake
    /// The screen locked, however it was started (our button, ⌃⌘Q, the screen saver, the lid).
    /// The engine releases the display assertion and keeps the system ones.
    case screenDidLock
    /// The screen unlocked; the engine takes the display assertion back.
    case screenDidUnlock
}
