import AppKit
import Observation
import UAwakeCore
import UAwakeSystem
import os

/// Lock now, auto-lock and dim-when-idle (docs/LOCK-DIM-DESIGN.md). Samples idle time once a
/// second, only while a session is active and something is armed (50 times a second while the
/// dim is up, so input removes it at once), and feeds it to the pure ``LockDimTracker``.
///
/// Locking turns the display off with `pmset displaysleepnow`; the screen saver is the fallback.
/// The engine drops its display assertion on `screenDidLock`; nothing here touches IOKit assertions.
@MainActor
@Observable
final class LockDimModel {
    private static let logger = Logger(subsystem: "com.underscoretec.uawake", category: "app")

    /// The dim sits just below this; the watermark is raised above it while the dim shows.
    static let dimLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    static let aboveDimLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue)

    private(set) var requirement = PasswordRequirement.unknown
    private(set) var isDimmed = false
    /// The watermark stays above the dim (read by the watermark while dimmed).
    private(set) var dimKeepsWatermark = true
    private(set) var isLocking = false

    @ObservationIgnored private let engine: DefaultSessionEngine
    @ObservationIgnored private let settings: UAwakeSettings
    @ObservationIgnored private let idle: any IdleTimeProvider
    @ObservationIgnored private let displays: any DisplayAssertionProbe
    @ObservationIgnored private let locker: any ScreenLocker
    @ObservationIgnored private var tracker = LockDimTracker()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panels: [NSPanel] = []
    /// Called with a title and body when a lock could not be started or confirmed.
    @ObservationIgnored var report: (String, String) -> Void = { _, _ in }

    init(
        engine: DefaultSessionEngine, settings: UAwakeSettings, idle: any IdleTimeProvider,
        displays: any DisplayAssertionProbe, locker: any ScreenLocker
    ) {
        self.engine = engine
        self.settings = settings
        self.idle = idle
        self.displays = displays
        self.locker = locker
        observe()
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.refresh()
            }
        }
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await self?.refreshRequirement()
            }
        }
        Task { [weak self] in await self?.refreshRequirement() }
    }

    private func observe() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// Re-reads the "Require password" setting. Cheap; the user may change it any time.
    func refreshRequirement() async {
        let value = await locker.passwordRequirement()
        if value != requirement { requirement = value }
    }

    // MARK: Lock now

    func lockNow() {
        guard !isLocking else { return }
        isLocking = true
        setDimmed(false)
        Task {
            defer { isLocking = false }
            guard await locker.lock() != nil else {
                report(
                    String(localized: "Couldn't turn the screen off", comment: "Notification title"),
                    String(
                        localized:
                            "uawake couldn't ask your Mac to turn the screen off. Press ⌃⌘Q to lock it yourself.",
                        comment: "Notification body"))
                return
            }
            // Turning the screen off on a Mac that asks for no password locks nothing: nothing to confirm.
            if requirement.isKnownNotToLock { return }
            var wait = 3.0
            if case .delay(let seconds) = requirement { wait += Double(seconds) }
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                if engine.isScreenLocked { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            Self.logger.warning("Screen lock was not confirmed")
            report(
                String(localized: "Couldn't confirm the screen locked", comment: "Notification title"),
                String(
                    localized:
                        "The screen was turned off, but your Mac didn't report a lock. Check Lock Screen settings, or press ⌃⌘Q.",
                    comment: "Notification body"))
        }
    }

    func openLockScreenSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Wording

    var buttonTitle: String {
        requirement.isKnownNotToLock
            ? String(localized: "Screen off (no password required)", comment: "Popover and settings button")
            : String(localized: "Lock now", comment: "Popover and settings button")
    }

    var buttonSymbol: String { requirement.isKnownNotToLock ? "display" : "lock.fill" }

    /// What to know about the password setting; `nil` when a lock is prompt.
    var caption: String? {
        switch requirement {
        case .immediate: nil
        case .never:
            String(
                localized: "Your Mac isn't set to ask for a password, so this turns the screen off without locking it.",
                comment: "Lock caption")
        case .delay(let seconds) where seconds > PasswordRequirement.promptDelayLimit:
            String(
                localized:
                    "Your Mac asks for a password only \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))) after the screen turns off, so it isn't locked yet.",
                comment: "Lock caption; the argument is a time like 5 minutes")
        case .delay: nil
        case .unknown:
            String(
                localized: "uawake can't tell whether your Mac asks for a password.", comment: "Lock caption")
        }
    }

    /// The same warning, for the auto-lock control.
    var autoLockCaption: String? {
        requirement.isKnownNotToLock
            ? String(
                localized: "Your Mac won't ask for a password afterwards, so this only turns the screen off.",
                comment: "Auto-lock warning")
            : caption
    }

    /// "Dims after 5 min idle · Locks after 10 min idle"; `nil` when neither is on.
    var statusText: String? {
        let config = settings.lockDimConfig
        var parts: [String] = []
        if let dim = config.dim {
            parts.append(String(localized: "Dims after \(Int(dim / 60)) min idle", comment: "Popover status"))
        }
        if let lock = config.autoLock {
            parts.append(
                requirement.isKnownNotToLock
                    ? String(localized: "Screen off after \(Int(lock / 60)) min idle", comment: "Popover status")
                    : String(localized: "Locks after \(Int(lock / 60)) min idle", comment: "Popover status"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Sampling

    /// Starts or stops the sampler to match the settings and whether a session is active.
    func refresh() {
        let armed = settings.lockDimConfig.isArmed && engine.sessions.contains { $0.state == .active }
        if armed {
            if timer == nil { schedule(interval: isDimmed ? 0.02 : 1) }
        } else {
            timer?.invalidate()
            timer = nil
            tracker = LockDimTracker()
            setDimmed(false)
        }
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = interval == 1 ? 0.2 : 0
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    func tick() {
        let config = settings.lockDimConfig
        let output = tracker.update(
            config: config, idle: idle.secondsSinceLastInput(),
            sessionActive: engine.sessions.contains { $0.state == .active }, locked: engine.isScreenLocked,
            othersHoldDisplay: displays.othersHoldDisplay())
        dimKeepsWatermark = config.keepsWatermark
        setDimmed(output.dimmed, darkness: config.darkness)
        if output.lockNow { lockNow() }
    }

    // MARK: Dim

    private func setDimmed(_ dimmed: Bool, darkness: Double = 0.6) {
        if dimmed {
            syncPanels(darkness: darkness)
            if !isDimmed {
                isDimmed = true
                if timer != nil { schedule(interval: 0.02) }
            }
        } else if isDimmed || !panels.isEmpty {
            // Instant, no fade: input must never wait for an animation.
            for panel in panels { panel.orderOut(nil) }
            panels.removeAll()
            isDimmed = false
            if timer != nil { schedule(interval: 1) }
        }
    }

    /// One black, click-through panel per display, hidden from capture, on every Space.
    private func syncPanels(darkness: Double) {
        let screens = NSScreen.screens
        if panels.count != screens.count || zip(panels, screens).contains(where: { $0.frame != $1.frame }) {
            for panel in panels { panel.orderOut(nil) }
            panels = screens.map { screen in
                let panel = NSPanel(
                    contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                    defer: false)
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.sharingType = .none
                panel.level = Self.dimLevel
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                panel.title = "Dim"
                panel.identifier = NSUserInterfaceItemIdentifier("Dim")
                panel.setAccessibilityElement(false)
                panel.setFrame(screen.frame, display: false)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    panel.alphaValue = 1
                } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 1.5
                        panel.animator().alphaValue = 1
                    }
                }
                return panel
            }
        }
        for panel in panels { panel.backgroundColor = NSColor.black.withAlphaComponent(darkness) }
    }
}

/// The locker and probes for runs without a real lock (UI tests, screenshots): never touches the
/// display. `-UITestPasswordRequirement immediate|never|delay:300|unknown` picks what it reports.
struct InertScreenLocker: ScreenLocker {
    let requirement: PasswordRequirement

    init(argument: String?) {
        switch argument {
        case "never": requirement = .never
        case "unknown": requirement = .unknown
        case .some(let text) where text.hasPrefix("delay:"):
            requirement = .delay(seconds: Int(text.dropFirst(6)) ?? 300)
        default: requirement = .immediate
        }
    }

    func lock() async -> LockMethod? { .displaySleep }
    func passwordRequirement() async -> PasswordRequirement { requirement }
}

struct InertIdleTime: IdleTimeProvider {
    func secondsSinceLastInput() -> TimeInterval { 0 }
}

struct InertDisplayProbe: DisplayAssertionProbe {
    func othersHoldDisplay() -> Bool { false }
}
