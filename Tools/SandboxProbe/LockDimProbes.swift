import AppKit
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import os

// Lock & dim spike (1.0.0-alpha.8). Developer tool, never shipped. Public APIs only.
// Destructive probes (they lock or sleep the display) run only from the Run button or `--run <id>`.

@MainActor
private func note(_ id: String, _ text: String) { ProbeModel.shared.event(id, text) }

private func out(_ value: String, _ result: ProbeResult) -> ProbeOutcome { ProbeOutcome(value: value, result: result) }

/// Session dictionary flag. `CGSessionCopyCurrentDictionary` is public CoreGraphics; the key is not documented.
private func sessionLocked() -> Bool? {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

private func assertionTypes() -> [String] {
    var byProcess: Unmanaged<CFDictionary>?
    _ = IOPMCopyAssertionsByProcess(&byProcess)
    let processes = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] ?? [:]
    return (processes[NSNumber(value: getpid())] ?? []).compactMap { $0["AssertType"] as? String }.sorted()
}

@MainActor
enum LockDimProbes {
    nonisolated static let all: [Probe] = [
        Probe(id: "lockSetting", title: "Read 'require password' setting", release: "alpha.8", run: lockSetting),
        Probe(
            id: "lockObservers", title: "Lock/unlock/screensaver/display notifications", release: "alpha.8",
            run: lockObservers),
        Probe(id: "idleTime", title: "User idle time without permissions", release: "alpha.8", run: idleTime),
        Probe(id: "dimOverlay", title: "Dim overlay: window properties", release: "alpha.8", run: dimOverlay),
        Probe(
            id: "dimRemoval", title: "Dim overlay: instant removal on input (move the mouse)", release: "alpha.8",
            run: dimRemoval),
        Probe(
            id: "lockActions", title: "Lock actions: screen saver, displaysleepnow (LOCKS YOUR SCREEN)",
            release: "alpha.8", run: lockActions),
        Probe(
            id: "lockAssertions", title: "Assertions while locked; release display only (LOCKS YOUR SCREEN)",
            release: "alpha.8", run: lockAssertions),
    ]

    // MARK: 1. setting

    static func lockSetting(_ interactive: Bool) async -> ProbeOutcome {
        var parts: [String] = []
        for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
            for key in ["askForPassword", "askForPasswordDelay", "idleTime"] {
                let v = CFPreferencesCopyValue(
                    key as CFString, "com.apple.screensaver" as CFString, kCFPreferencesCurrentUser, host)
                parts.append("\(host == kCFPreferencesAnyHost ? "any" : "cur").\(key)=\(v.map { "\($0)" } ?? "nil")")
            }
        }
        // sysadminctl -screenLock status is the CLI view of the setting; try it from the sandbox.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        task.arguments = ["-screenLock", "status"]
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        var cli: String
        do {
            try task.run()
            task.waitUntilExit()
            cli = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { cli = "exec failed: \(error)" }
        let anyValue = parts.contains { !$0.hasSuffix("=nil") }
        return out("CFPreferences: \(parts.joined(separator: " ")) | sysadminctl: \(cli)", anyValue ? .works : .limited)
    }

    // MARK: 2. observers

    private static var observersInstalled = false
    static func lockObservers(_ interactive: Bool) async -> ProbeOutcome {
        guard !observersInstalled else { return out("Already listening", .works) }
        observersInstalled = true
        let names = [
            "com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
            "com.apple.screensaver.didstart", "com.apple.screensaver.didstop", "com.apple.screensaver.willstop",
        ]
        for name in names {
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    note(
                        "lockObservers",
                        "distributed \(name) (CGSession locked=\(sessionLocked().map(String.init) ?? "nil"))")
                }
            }
        }
        for name in [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    note(
                        "lockObservers",
                        "workspace \(name.rawValue) (locked=\(sessionLocked().map(String.init) ?? "nil"))")
                }
            }
        }
        return out(
            "Listening: 5 distributed + 4 NSWorkspace notifications. Initial CGSession locked=\(sessionLocked().map(String.init) ?? "nil")",
            .works)
    }

    // MARK: 3. idle time

    static func idleTime(_ interactive: Bool) async -> ProbeOutcome {
        let types: [(String, CGEventType)] = [
            ("any", anyInput), ("mouseMoved", .mouseMoved), ("keyDown", .keyDown),
            ("leftMouseDown", .leftMouseDown),
        ]
        let values = types.map {
            "\($0.0)=\(String(format: "%.1f", CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0.1)))s"
        }
        // IOHIDSystem's HIDIdleTime, nanoseconds.
        var hid = "n/a"
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        if entry != 0 {
            if let prop = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            {
                hid = String(format: "%.1fs", prop.doubleValue / 1e9)
            } else {
                hid = "property unreadable"
            }
            IOObjectRelease(entry)
        }
        let trusted = AXIsProcessTrusted()
        return out(
            "CGEventSource: \(values.joined(separator: " ")) | IOHIDSystem HIDIdleTime=\(hid) | AXIsProcessTrusted=\(trusted)",
            .works)
    }

    // MARK: 4. overlay

    private static var overlays: [NSWindow] = []

    private static func showOverlays(alpha: CGFloat) {
        removeOverlays()
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor.black.withAlphaComponent(alpha)
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.sharingType = .none
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlays.append(window)
        }
    }

    private static func removeOverlays() {
        for w in overlays { w.orderOut(nil) }
        overlays.removeAll()
    }

    static func dimOverlay(_ interactive: Bool) async -> ProbeOutcome {
        showOverlays(alpha: 0.9)
        try? await Task.sleep(for: .seconds(1))
        let ids = Set(overlays.map { CGWindowID($0.windowNumber) })
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ids.contains(CGWindowID(($0[kCGWindowNumber as String] as? Int) ?? -1)) }
        let rows = info.map {
            "win \($0[kCGWindowNumber as String] ?? "?") layer=\($0[kCGWindowLayer as String] ?? "?") sharing=\($0[kCGWindowSharingState as String] ?? "?") alpha=\($0[kCGWindowAlpha as String] ?? "?")"
        }
        let w = overlays.first
        let summary =
            "screens=\(NSScreen.screens.count) overlays=\(overlays.count) onScreen=\(info.count) | \(rows.joined(separator: "; ")) | ignoresMouse=\(w?.ignoresMouseEvents ?? false) sharingType=\(w.map { String($0.sharingType.rawValue) } ?? "n/a") behavior=canJoinAllSpaces:\(w?.collectionBehavior.contains(.canJoinAllSpaces) ?? false)"
        // Hold 6 s so the maintainer can screencapture / switch Spaces by hand; the log keeps the facts.
        try? await Task.sleep(for: .seconds(interactive ? 12 : 6))
        let ok = info.count == NSScreen.screens.count
        removeOverlays()
        return out(summary, ok ? .works : .limited)
    }

    static func dimRemoval(_ interactive: Bool) async -> ProbeOutcome {
        showOverlays(alpha: 0.6)
        let start = Date()
        // Baseline: idle time right now; input is any drop below the baseline growth.
        var last = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyInput)
        while Date().timeIntervalSince(start) < 25 {
            try? await Task.sleep(for: .milliseconds(20))
            let now = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: anyInput)
            if now < last - 0.01 {
                let t0 = Date()
                removeOverlays()
                let latency = Date().timeIntervalSince(t0) * 1000
                return out(
                    "Input detected after \(String(format: "%.2f", Date().timeIntervalSince(start)))s by polling idle time at 50 Hz; overlays removed in \(String(format: "%.1f", latency)) ms; no Accessibility/Input Monitoring prompt",
                    .works)
            }
            last = now
        }
        removeOverlays()
        return out("No input within 25 s (move the mouse during the run). Overlay removed by timeout.", .limited)
    }

    // MARK: 1/5 destructive

    private static func runTool(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "exit \(task.terminationStatus) \(text)"
        } catch { return "exec failed: \(error)" }
    }

    /// Polls for `seconds`, logging every change of the CGSession locked flag.
    private static func watchLock(_ id: String, seconds: Int) async -> [String] {
        var log: [String] = []
        var last = sessionLocked()
        for second in 0..<seconds {
            try? await Task.sleep(for: .seconds(1))
            let now = sessionLocked()
            if now != last {
                let line = "+\(second + 1)s locked \(last.map(String.init) ?? "nil") → \(now.map(String.init) ?? "nil")"
                log.append(line)
                note(id, line)
                last = now
            }
        }
        return log
    }

    static func lockActions(_ interactive: Bool) async -> ProbeOutcome {
        _ = await lockObservers(false)
        var report: [String] = ["start locked=\(sessionLocked().map(String.init) ?? "nil")"]

        // A. Screen saver via NSWorkspace.
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            report.append("screensaver launch: ok")
        } catch { report.append("screensaver launch: FAILED \(error)") }
        let a = await watchLock("lockActions", seconds: 20)
        report.append(
            "after screensaver, 20 s: \(a.isEmpty ? "NO lock flag change" : a.joined(separator: ", ")) locked=\(sessionLocked().map(String.init) ?? "nil")"
        )
        report.append("Maintainer: unlock now and move the mouse; next step starts in 60 s")
        note("lockActions", report.last ?? "")
        try? await Task.sleep(for: .seconds(60))
        _ = runTool("/usr/bin/killall", ["ScreenSaverEngine"])

        // B. pmset displaysleepnow from the sandbox.
        let exec = runTool("/usr/bin/pmset", ["displaysleepnow"])
        report.append("pmset displaysleepnow: \(exec)")
        let b = await watchLock("lockActions", seconds: 20)
        report.append(
            "after displaysleepnow, 20 s: \(b.isEmpty ? "NO lock flag change" : b.joined(separator: ", ")) locked=\(sessionLocked().map(String.init) ?? "nil")"
        )

        // C. IOKit: IOPMAssertion cannot sleep the display; IODisplayWrangler does not exist on Apple silicon.
        let wrangler = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayWrangler"))
        report.append("IODisplayWrangler present: \(wrangler != 0)")
        if wrangler != 0 { IOObjectRelease(wrangler) }

        // D. Shortcuts CLI (user-made shortcut with the Lock Screen action), only if one named "uawake-lock" exists.
        report.append("shortcuts list: \(runTool("/usr/bin/shortcuts", ["list"]).prefix(200))")
        return out(report.joined(separator: " | "), .limited)
    }

    static func lockAssertions(_ interactive: Bool) async -> ProbeOutcome {
        _ = await lockObservers(false)
        var ids: [String: IOPMAssertionID] = [:]
        for type in ["PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep"] {
            var id = IOPMAssertionID(0)
            _ = IOPMAssertionCreateWithName(
                type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "uawake probe lock" as CFString, &id)
            ids[type] = id
        }
        note("lockAssertions", "created: \(assertionTypes())")
        // Lock: screen saver then (if the saver is not enough) displaysleepnow, same as lockActions.
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        let lockLog = await watchLock("lockAssertions", seconds: 15)
        note("lockAssertions", "locked after saver: \(sessionLocked().map(String.init) ?? "nil") \(lockLog)")
        note("lockAssertions", "while locked (all 3 held): \(assertionTypes())")
        // Release only the display assertion. Display sleep timer is `pmset displaysleep` minutes after the last input;
        // the screen saver may sleep the display earlier. Watch up to 5 minutes for screensDidSleep.
        if let id = ids["PreventUserIdleDisplaySleep"] { IOPMAssertionRelease(id) }
        note(
            "lockAssertions",
            "display assertion released; remaining: \(assertionTypes()) — do not touch the Mac for 5 min")
        let begin = Date()
        var slept = false
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { slept = true }
        }
        while !slept && Date().timeIntervalSince(begin) < 300 { try? await Task.sleep(for: .seconds(2)) }
        NSWorkspace.shared.notificationCenter.removeObserver(token)
        let after = assertionTypes()
        for (_, id) in ids { IOPMAssertionRelease(id) }
        return out(
            "locked=\(sessionLocked().map(String.init) ?? "nil") displaySlept=\(slept) after \(Int(Date().timeIntervalSince(begin)))s; assertions then: \(after)",
            slept && after.contains("PreventUserIdleSystemSleep") && after.contains("PreventSystemSleep")
                ? .works : .limited)
    }
}

/// `kCGAnyInputEventType` (~0); the failable init never fails for it.
private let anyInput = CGEventType(rawValue: UInt32.max) ?? .mouseMoved
