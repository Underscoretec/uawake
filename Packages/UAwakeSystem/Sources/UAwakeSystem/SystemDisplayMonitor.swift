import AppKit
import UAwakeCore

/// Connected displays from `NSScreen.screens`, re-read once a burst of
/// screen-parameter notifications has been quiet for `coalesceDelay`.
public final class SystemDisplayMonitor: SignalMonitor, @unchecked Sendable {
    static let coalesceDelay: Duration = .seconds(1)

    private let broadcaster = Broadcaster<[DisplayInfo]>()
    private let lock = NSLock()
    private var state: [DisplayInfo]
    private var pending: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?

    /// Main actor because `NSScreen` is main-thread API.
    @MainActor public init() {
        state = Self.read()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.scheduleRefresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pending?.cancel()
    }

    public var current: [DisplayInfo] { lock.withLock { state } }

    public func updates() -> AsyncStream<[DisplayInfo]> {
        broadcaster.stream(startingWith: current)
    }

    /// Restarts the quiet period; the read happens on the main actor when it ends.
    private func scheduleRefresh() {
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled else { return }
            self?.refresh(Self.read())
        }
        lock.withLock {
            pending?.cancel()
            pending = task
        }
    }

    /// Stores `new` and yields it unless it equals the current value.
    func refresh(_ new: [DisplayInfo]) {
        let changed = lock.withLock {
            defer { state = new }
            return state != new
        }
        if changed { broadcaster.yield(new) }
    }

    /// The displays connected right now, for the rule editor's picker.
    @MainActor public static func read() -> [DisplayInfo] {
        sorted(
            NSScreen.screens.map { screen in
                let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return DisplayInfo(
                    name: screen.localizedName, isBuiltIn: id.map { CGDisplayIsBuiltin($0) != 0 } ?? false)
            })
    }

    /// By name, then external before built-in, so equal sets of displays compare equal.
    static func sorted(_ displays: [DisplayInfo]) -> [DisplayInfo] {
        displays.sorted { ($0.name, $0.isBuiltIn ? 1 : 0) < ($1.name, $1.isBuiltIn ? 1 : 0) }
    }
}
