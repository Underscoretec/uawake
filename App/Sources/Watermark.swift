import AppKit
import SwiftUI
import UAwakeCore

/// What every display's watermark draws. One instance, shared by all overlay windows.
@MainActor @Observable
final class WatermarkContent {
    var style = WatermarkStyle.centred
    var title = ""
    var timer = ""
    var textColour = Color.blue
    var timerColour = Color.blue
    var opacity = 0.12
    var size = WatermarkSize.medium
    var drift = CGSize.zero
}

/// The on-screen watermark (Appearance › Show watermark on screen): a borderless,
/// transparent, click-through window per display, shown only while a session is active.
@MainActor
final class WatermarkController {
    private let model: PopoverViewModel
    private let settings: UAwakeSettings
    private let content = WatermarkContent()
    private var windows: [CGDirectDisplayID: NSPanel] = [:]
    private var ticker: Timer?
    private var fullScreenPoll: Timer?
    private var driftTimer: Timer?

    /// Above normal and floating windows, below alerts and modal panels.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue - 1)

    init(model: PopoverViewModel, settings: UAwakeSettings) {
        self.model = model
        self.settings = settings
        observe()
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (.default, UserDefaults.didChangeNotification),
            (.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (workspace, NSWorkspace.didActivateApplicationNotification),
        ]
        for (center, name) in names {
            Task { [weak self] in for await _ in center.notifications(named: name) { self?.update() } }
        }
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    func update() {
        let now = Date()
        let active = model.engine.sessions.filter { $0.state == .active }
        ticker?.invalidate()
        ticker = nil
        guard settings.watermarkEnabled, !active.isEmpty else {
            for window in windows.values { window.close() }
            windows = [:]
            fullScreenPoll?.invalidate()
            fullScreenPoll = nil
            driftTimer?.invalidate()
            driftTimer = nil
            content.drift = .zero
            return
        }
        content.title = String(localized: "AWAKE · uawake", comment: "On-screen watermark; uawake is the app's name")
        if let remaining = model.countdownRemaining(now: now) {
            let left = PopoverViewModel.menuBarText(remaining)
            content.timer = String(localized: "\(left) left", comment: "On-screen watermark: time left, e.g. 1:42 left")
            // Same cadence as the menu bar pill: once a minute, every second in the final minute.
            let timer = Timer(
                timeInterval: PopoverViewModel.secondsUntilMenuBarChange(remaining) + 0.02, repeats: false
            ) {
                [weak self] _ in MainActor.assumeIsolated { self?.update() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else {
            let open = active.filter { !$0.endCondition.hasOwnDeadline }
            content.timer = PopoverViewModel.sinceText(open.map(\.startedAt).min() ?? active[0].startedAt)
        }
        content.style = settings.watermarkStyle
        content.textColour = Self.colour(settings.watermarkTextColour)
        content.timerColour = Self.colour(settings.watermarkTimerColour)
        content.opacity = Double(settings.watermarkOpacity) / 100
        content.size = settings.watermarkSize
        updateDrift()
        updateWindows()
    }

    // MARK: Windows

    private func updateWindows() {
        let hideInFullScreen = settings.watermarkHiddenInFullScreen
        let covered = hideInFullScreen ? Self.framesCoveredByFrontApp() : []
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { continue }
            seen.insert(id)
            let window = windows[id] ?? makeWindow()
            windows[id] = window
            window.sharingType = settings.watermarkHiddenFromCapture ? .none : .readOnly
            var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if !hideInFullScreen { behavior.insert(.fullScreenAuxiliary) }
            window.collectionBehavior = behavior
            if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
            if covered.contains(where: { $0 == screen.frame }) {
                window.orderOut(nil)
            } else if !window.isVisible {
                window.orderFrontRegardless()
            }
        }
        for (id, window) in windows where !seen.contains(id) {
            window.close()
            windows[id] = nil
        }
        // Presenting (Keynote, PowerPoint) opens a full-screen window without an app switch.
        // ponytail: 2 s poll of the window list; an accessibility observer if this shows up in CPU samples.
        if hideInFullScreen, fullScreenPoll == nil {
            let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWindows() }
            }
            poll.tolerance = 0.5
            RunLoop.main.add(poll, forMode: .common)
            fullScreenPoll = poll
        } else if !hideInFullScreen {
            fullScreenPoll?.invalidate()
            fullScreenPoll = nil
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = Self.level
        panel.title = "Watermark"
        panel.identifier = NSUserInterfaceItemIdentifier("Watermark")
        let view = NSHostingView(rootView: WatermarkView(content: content))
        view.setAccessibilityElement(false)
        panel.contentView = view
        panel.setAccessibilityElement(false)
        return panel
    }

    /// Screen frames (AppKit coordinates) that a window of the frontmost app fills completely:
    /// a full-screen app or a presentation.
    private static func framesCoveredByFrontApp() -> [NSRect] {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            pid != ProcessInfo.processInfo.processIdentifier,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
            let primaryHeight = NSScreen.screens.first?.frame.height
        else { return [] }
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                (info[kCGWindowLayer as String] as? Int ?? -1) >= 0,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            // Window-server coordinates have their origin at the top left of the primary display.
            return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    // MARK: Drift

    /// The centred style moves a little every few minutes; Reduce Motion stops it (in the view).
    private func updateDrift() {
        guard content.style == .centred, settings.watermarkDrifts else {
            driftTimer?.invalidate()
            driftTimer = nil
            content.drift = .zero
            return
        }
        guard driftTimer == nil else { return }
        let timer = Timer(timeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.content.drift = CGSize(width: .random(in: -120...120), height: .random(in: -80...80))
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }

    // MARK: Colours

    static let colourPresets: [(value: String, hex: UInt32, name: LocalizedStringResource)] = [
        ("blue", 0x1F6FE5, LocalizedStringResource("uawake blue", comment: "Watermark colour")),
        ("amber", 0xFFB340, LocalizedStringResource("Amber", comment: "Watermark colour")),
        ("green", 0x34C759, LocalizedStringResource("Green", comment: "Watermark colour")),
        ("red", 0xFF453A, LocalizedStringResource("Red", comment: "Watermark colour")),
        ("white", 0xFFFFFF, LocalizedStringResource("White", comment: "Watermark colour")),
    ]

    static func hex(_ value: String) -> UInt32 {
        colourPresets.first { $0.value == value }?.hex ?? UAwakeSettings.hexColour(value) ?? 0x1F6FE5
    }

    static func colour(_ value: String) -> Color {
        let hex = hex(value)
        return Color(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// `#RRGGBB` for a picked colour.
    static func hexText(_ colour: Color) -> String {
        let ns = NSColor(colour).usingColorSpace(.sRGB) ?? .white
        func byte(_ component: CGFloat) -> Int { Int((min(1, max(0, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }
}

/// The watermark drawn over one display. The time left (or since when) is the large part;
/// "AWAKE · uawake" sits small above it.
struct WatermarkView: View {
    let content: WatermarkContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            switch content.style {
            case .centred:
                label
                    .offset(reduceMotion ? .zero : content.drift)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 4), value: content.drift)
            case .tiled:
                tiles
            case .bouncing:
                if reduceMotion { label } else { BouncingLabel(image: renderedLabel) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(contrast == .increased ? min(0.6, content.opacity * 1.75) : content.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The timer's point size; the title is ~40% of it.
    private var timerSize: CGFloat {
        switch content.size {
        case .small: content.style == .tiled ? 24 : 64
        case .medium: content.style == .tiled ? 34 : 104
        case .large: content.style == .tiled ? 48 : 150
        }
    }

    private var titleText: Text {
        Text(verbatim: content.title).font(.system(size: timerSize * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(content.textColour)
    }

    private var timerText: Text {
        Text(verbatim: content.timer).font(.system(size: timerSize, weight: .heavy, design: .rounded))
            .monospacedDigit().foregroundStyle(content.timerColour)
    }

    private var label: some View {
        VStack(spacing: 0) {
            titleText
            timerText
        }
        // Increase Contrast: outlined, so it reads over any wallpaper.
        .shadow(color: contrast == .increased ? .black : .clear, radius: 1)
    }

    /// The label as an image for the Core Animation layer; redrawn only when the text changes.
    private var renderedLabel: CGImage? {
        let renderer = ImageRenderer(content: label.padding(4))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.cgImage
    }

    /// Title and timer repeated on a grid turned 30°, offsetting alternate rows.
    private var tiles: some View {
        Canvas { context, size in
            let title = context.resolve(titleText)
            let timer = context.resolve(timerText)
            let titleSize = title.measure(in: size)
            let timerSize = timer.measure(in: size)
            let stepX = max(titleSize.width, timerSize.width) + self.timerSize * 2
            let stepY = titleSize.height + timerSize.height + self.timerSize * 1.6
            let reach = hypot(size.width, size.height) / 2 + stepX
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .degrees(-30))
            if contrast == .increased { context.addFilter(.shadow(color: .black, radius: 1)) }
            var row = 0
            for y in stride(from: -reach, through: reach, by: stepY) {
                let shift = row.isMultiple(of: 2) ? 0 : stepX / 2
                for x in stride(from: -reach - shift, through: reach, by: stepX) {
                    context.draw(title, at: CGPoint(x: x, y: y), anchor: .bottom)
                    context.draw(timer, at: CGPoint(x: x, y: y), anchor: .top)
                }
                row += 1
            }
        }
    }
}

/// The label gliding across the screen and bouncing off its edges. Core Animation runs the
/// motion in the render server: drawing it with SwiftUI 20 times a second cost ~7% CPU.
private struct BouncingLabel: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> BouncingLabelView { BouncingLabelView() }

    func updateNSView(_ view: BouncingLabelView, context: Context) { view.image = image }
}

final class BouncingLabelView: NSView {
    private let label = CALayer()
    var image: CGImage? {
        didSet { if image !== oldValue { restart() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.anchorPoint = .zero
        layer?.addSublayer(label)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        restart()
    }

    /// One autoreversing animation per axis at 60 and 42 pt/s. Each starts at a phase set by
    /// the current time, so a new image (the timer changed) or a resize continues the path.
    private func restart() {
        guard let image, bounds.width > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.contents = image
        label.contentsScale = scale
        label.bounds = CGRect(origin: .zero, size: size)
        label.position = .zero
        for (key, range, speed) in [
            ("position.x", bounds.width - size.width, 60.0), ("position.y", bounds.height - size.height, 42.0),
        ] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = 0
            animation.toValue = max(0, range)
            animation.duration = max(1, range / speed)
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: 2 * animation.duration)
            label.add(animation, forKey: key)
        }
        CATransaction.commit()
    }
}
