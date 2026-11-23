import AppKit
import IOKit
import IOKit.pwr_mgt
import UAwakeCore
import os

/// Seconds since the last keyboard, mouse or trackpad input. Needs no permission (verified from
/// the sandbox with Accessibility not granted).
public protocol IdleTimeProvider: Sendable {
    func secondsSinceLastInput() -> TimeInterval
}

public struct SystemIdleTimeProvider: IdleTimeProvider {
    public init() {}

    public func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType is ~0, which Swift's failable init cannot spell as a literal.
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}

/// Whether another app holds a display-sleep assertion (video, a presentation). Our own
/// assertions are ignored.
public protocol DisplayAssertionProbe: Sendable {
    func othersHoldDisplay() -> Bool
}

public struct SystemDisplayAssertionProbe: DisplayAssertionProbe {
    public init() {}

    public func othersHoldDisplay() -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
            let processes = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return false }
        let own = NSNumber(value: getpid())
        let types: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        return processes.contains { pid, list in
            pid != own && list.contains { types.contains($0["AssertType"] as? String ?? "") }
        }
    }
}

/// How the screen was switched off or locked.
public enum LockMethod: String, Sendable {
    case displaySleep = "pmset displaysleepnow"
    case screenSaver = "screen saver"
}

/// Locks the screen. The session keeps running.
public protocol ScreenLocker: Sendable {
    /// Turns the display off; if that fails, starts the screen saver. Returns the method that
    /// was started, or `nil` if both failed. Whether it actually locked is reported by
    /// ``SessionLifecycleEvent/screenDidLock``, not by this call.
    @MainActor func lock() async -> LockMethod?

    /// The "Require password" setting, read each time (it is cheap and the user may change it).
    func passwordRequirement() async -> PasswordRequirement
}

/// Public API only: `/usr/bin/pmset displaysleepnow` (runs from the sandbox, spike 23 Nov 2026),
/// then `ScreenSaverEngine.app` through `NSWorkspace`. The setting comes from
/// `/usr/sbin/sysadminctl -screenLock status`; preferences reads return nothing in the sandbox.
public struct SystemScreenLocker: ScreenLocker {
    private static let logger = Logger(subsystem: "com.underscoretec.uawake", category: "system")

    public init() {}

    @MainActor
    public func lock() async -> LockMethod? {
        if Self.run("/usr/bin/pmset", ["displaysleepnow"]).status == 0 { return .displaySleep }
        Self.logger.warning("pmset displaysleepnow failed; starting the screen saver")
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return .screenSaver
        } catch {
            Self.logger.warning("Screen saver launch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func passwordRequirement() async -> PasswordRequirement {
        await Task.detached {
            PasswordRequirement.parse(Self.run("/usr/sbin/sysadminctl", ["-screenLock", "status"]).output)
        }.value
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (task.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }
}
