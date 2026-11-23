import AppKit
import SwiftUI
import UAwakeCore

/// The menu bar item. A double click toggles the default session; a single click,
/// secondary click, Control-click or Option-click opens the popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    /// Space below the anchor for the popover, set each time it opens.
    private var availableHeight = CGFloat.greatestFiniteMagnitude
    private var ticker: Timer?
    /// Opens the popover once a single click can no longer become a double click.
    private var pendingPopover: Timer?
    private var clicks = ClickSequence(interval: NSEvent.doubleClickInterval)
    /// System uptime when the popover last closed: a transient popover closes on the mouse-down
    /// of the very click that was meant to close it.
    private var popoverClosedAt: TimeInterval = -.infinity
    /// The countdown text last drawn in the menu bar, and when (acceptance sampling).
    private(set) var lastCountdown: String?
    private(set) var lastRendered: Date?

    struct Appearance: Equatable {
        var style: IconStyle
        var highlight: MenuBarHighlight
        var tone: PopoverViewModel.MenuBarTone
        var countdown: String?
        var increasedContrast = false
    }

    /// What the button shows now; redraws only when this changes.
    private var drawn: Appearance?

    init(model: AppModel, keepsPopoverOpen: Bool = false) {
        self.model = model
        super.init()
        popover.behavior = keepsPopoverOpen ? .applicationDefined : .transient
        popover.appearance = NSApplication.shared.appearance
        popover.delegate = self
        let controller = NSHostingController(
            rootView: PopoverView(model: model.popover).defaultAppStorage(model.settings.defaults))
        controller.sizingOptions = []  // `fitPopover` sets the size.
        popover.contentViewController = controller
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            // No press highlight: a click must change nothing on screen until the double-click
            // interval has passed. The icon highlights only while the popover is open.
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.setAccessibilityHelp(
                String(
                    localized: "Double-click to turn uawake on or off. Click for options.",
                    comment: "VoiceOver help for the menu bar icon"))
        }
        model.popover.showPopover = { [weak self] in self?.showPopover() }
        observe()
        observeHeight()
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.update()
            }
        }
        Task { [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await _ in center.notifications(named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
                self?.update()
            }
        }
    }

    /// Right-, Option- or Control-click opens the popover at once.
    static func wantsMenu(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseUp || !modifiers.isDisjoint(with: [.option, .control])
    }

    @objc private func clicked() {
        guard let event = NSApplication.shared.currentEvent else { return }
        if Self.wantsMenu(event.type, modifiers: event.modifierFlags) {
            pendingPopover?.invalidate()
            pendingPopover = nil
            togglePopover()
            return
        }
        clicks.interval = NSEvent.doubleClickInterval
        switch clicks.click(at: event.timestamp) {
        case .double:
            pendingPopover?.invalidate()
            pendingPopover = nil
            model.popover.toggle()
        case .single where popover.isShown || event.timestamp - popoverClosedAt < clicks.interval:
            popover.performClose(nil)
        case .single:
            let timer = Timer(timeInterval: clicks.interval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingPopover = nil
                    // A button still down is a second click on its way: its mouse-up decides.
                    if NSEvent.pressedMouseButtons & 1 == 0 {
                        self.showPopover()
                    } else {
                        self.clicks.awaitSecondClick()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pendingPopover = timer
        case .ignored:
            break
        }
    }

    private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    /// `anchor` replaces the status item (UI tests on a Mac where the item isn't placed).
    func showPopover(anchor: NSView? = nil) {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.popover.reload()
        let view = anchor ?? button
        if let screen = view.window?.screen ?? NSScreen.main {
            // Room below the anchor, less the popover's arrow and a margin above the Dock.
            let anchorBottom = view.window?.frame.minY ?? screen.visibleFrame.maxY
            availableHeight = max(200, anchorBottom - screen.visibleFrame.minY - 32)
        }
        // Measure the unscrolled content now, so the popover opens at its natural size.
        model.popover.scrolls = false
        let measure = NSHostingController(
            rootView: PopoverView(model: model.popover).defaultAppStorage(model.settings.defaults))
        let natural = measure.sizeThatFits(in: CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude)).height
        fitPopover(natural: natural)
        // A transient popover closes on outside clicks, app switches and Esc only while uawake is active.
        NSApplication.shared.activate()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        button.highlight(true)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Natural height when it fits below the menu bar; otherwise the space there, with the middle scrolling.
    private func fitPopover(natural: CGFloat) {
        guard natural > 0, natural < .greatestFiniteMagnitude else { return }
        model.popover.scrolls = natural > availableHeight
        popover.contentSize = NSSize(width: 360, height: min(natural, availableHeight).rounded(.up))
    }

    /// Content changes (sessions, banners, the Until… picker) re-measure through `naturalHeight`.
    private func observeHeight() {
        let natural = withObservationTracking {
            model.popover.naturalHeight
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHeight() }
        }
        fitPopover(natural: natural)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = ProcessInfo.processInfo.systemUptime
        statusItem.button?.highlight(false)
        model.popover.clearRefusal()
    }

    // MARK: Icon and countdown

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update() {
        guard let button = statusItem.button else { return }
        let viewModel = model.popover
        let now = Date()
        let appearance = Appearance(
            style: model.settings.iconStyle, highlight: model.settings.menuBarHighlight,
            tone: viewModel.menuBarTone(now: now),
            countdown: model.settings.showsCountdown ? viewModel.menuBarCountdown(now: now) : nil,
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        if appearance != drawn {
            let rendered = Self.render(appearance)
            button.image = rendered.image
            button.contentTintColor = rendered.tint
            button.appearsDisabled = rendered.dimmed
            button.setAccessibilityLabel(viewModel.statusAccessibilityLabel(now: now))
            drawn = appearance
        }
        lastCountdown = appearance.countdown
        lastRendered = now

        // One-shot timer for the next change: the countdown text (once a minute, then every
        // second in the final minute), the warning window or the end of a guard flash.
        ticker?.invalidate()
        ticker = nil
        let delays = [
            appearance.countdown == nil
                ? nil : viewModel.countdownRemaining(now: now).map(PopoverViewModel.secondsUntilMenuBarChange),
            viewModel.secondsUntilToneChange(now: now),
        ]
        if let delay = delays.compactMap({ $0 }).min() {
            let timer = Timer(timeInterval: delay + 0.02, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    /// The button's image, tint and dimming. Idle: the dimmed template icon. Active with
    /// the capsule: white (black on amber) icon and countdown in a uawake-blue, amber or red
    /// capsule. Otherwise a template image the menu bar tints for light and dark bars,
    /// coloured by `contentTintColor` with "Coloured icon".
    static func render(_ appearance: Appearance) -> (image: NSImage, tint: NSColor?, dimmed: Bool) {
        var tone = appearance.tone
        if appearance.highlight == .none && tone == .stopped { tone = .idle }
        let symbol = symbolImage(style: appearance.style, active: tone == .awake || tone == .endingSoon)
        let countdown = tone == .idle || tone == .stopped ? nil : appearance.countdown
        switch (tone, appearance.highlight) {
        case (.idle, _):
            return (symbol, nil, true)
        case (_, .capsule):
            let (fill, content) = capsuleColours(tone, increasedContrast: appearance.increasedContrast)
            return (capsule(symbol, countdown: countdown, fill: fill, content: content), nil, false)
        case (_, .colouredIcon):
            let tint: NSColor =
                switch tone {
                case .endingSoon: .systemOrange
                case .stopped: .systemRed
                default: .systemBlue
                }
            return (plain(symbol, countdown: countdown), tint, false)
        case (_, .none):
            return (plain(symbol, countdown: countdown), nil, false)
        }
    }

    /// Fill and content colours, white on blue and red (≥ 4.5:1), near-black on amber.
    /// Increase Contrast darkens the blue and red.
    static func capsuleColours(
        _ tone: PopoverViewModel.MenuBarTone, increasedContrast: Bool
    ) -> (fill: NSColor, content: NSColor) {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch tone {
        case .endingSoon: return (rgb(0xFFB340), rgb(0x1D1D1F))
        case .stopped: return (rgb(increasedContrast ? 0xB42318 : 0xD92D20), .white)
        default: return (rgb(increasedContrast ? 0x0A5BC4 : 0x1F6FE5), .white)
        }
    }

    private static let pillHeight: CGFloat = 18

    /// The icon and countdown in a filled capsule. Not a template: the colours are its point.
    static func capsule(_ symbol: NSImage, countdown: String?, fill: NSColor, content: NSColor) -> NSImage {
        let height = pillHeight
        let symbolSize = NSSize(width: symbol.size.width * 0.86, height: symbol.size.height * 0.86)
        let text = countdown.map { NSAttributedString(string: $0, attributes: textAttributes(content)) }
        let textWidth = text.map { 4 + ceil($0.size().width) + 1 } ?? 0
        let size = NSSize(width: 7 + symbolSize.width + textWidth + 7, height: height)
        let glyph = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            content.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return rasterize(size, template: false) {
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: height / 2, yRadius: height / 2)
                .fill()
            glyph.draw(
                in: NSRect(
                    x: 7, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
            if let text {
                text.draw(at: NSPoint(x: 7 + symbolSize.width + 4, y: (height - text.size().height) / 2))
            }
        }
    }

    /// The icon, and the countdown beside it, as one template image.
    static func plain(_ symbol: NSImage, countdown: String?) -> NSImage {
        guard let countdown else { return symbol }
        let text = NSAttributedString(string: countdown, attributes: textAttributes(.black))
        let size = NSSize(width: symbol.size.width + 4 + ceil(text.size().width), height: max(symbol.size.height, 18))
        return rasterize(size, template: true) {
            symbol.draw(in: NSRect(origin: NSPoint(x: 0, y: (size.height - symbol.size.height) / 2), size: symbol.size))
            text.draw(at: NSPoint(x: symbol.size.width + 4, y: (size.height - text.size().height) / 2))
        }
    }

    private static func textAttributes(_ colour: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: colour]
    }

    /// Drawn once into a 2x bitmap. A drawing-handler image would re-run its code every time
    /// the menu bar draws the item, which cost ~0.9% CPU with a 1 s countdown.
    private static func rasterize(_ size: NSSize, template: Bool, draw: () -> Void) -> NSImage {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage() }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = template
        return image
    }

    private static var symbolCache: [String: NSImage] = [:]

    /// The menu bar icon, rasterized once per style and state: drawing a vector image
    /// every second was the largest share of the countdown's CPU cost. The uawake cup is an
    /// asset-catalog template PDF drawn 18 pt tall; the other styles are SF Symbols.
    static func symbolImage(style: IconStyle, active: Bool) -> NSImage {
        let name = active ? symbols(style).active : symbols(style).inactive
        if let cached = symbolCache[name] { return cached }
        let vector: NSImage?
        if style == .uawake {
            vector = (NSImage(named: name)?.copy() as? NSImage).map { image in
                let height: CGFloat = 18
                image.size = NSSize(width: (image.size.width * height / image.size.height).rounded(), height: height)
                return image
            }
        } else {
            vector = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        }
        guard let vector else { return NSImage() }
        let image = rasterize(vector.size, template: true) { vector.draw(in: NSRect(origin: .zero, size: vector.size)) }
        symbolCache[name] = image
        return image
    }

    static func symbols(_ style: IconStyle) -> (active: String, inactive: String) {
        switch style {
        case .uawake: ("MenuBarIcon", "MenuBarIconIdle")
        case .cup: ("cup.and.saucer.fill", "cup.and.saucer")
        case .eye: ("eye.fill", "eye.slash")
        case .bolt: ("bolt.fill", "bolt.slash")
        }
    }

    // MARK: Hidden-icon detection

    /// Best-effort check that the item is on screen. macOS has no API for "hidden by the
    /// notch or a full menu bar"; a hidden item's window is off screen, not visible, or
    /// under the notch.
    var isProbablyHidden: Bool {
        guard let window = statusItem.button?.window, let screen = window.screen ?? NSScreen.main else { return true }
        if !window.occlusionState.contains(.visible) { return true }
        let frame = window.frame
        if frame.width < 1 || !screen.frame.intersects(frame) || frame.minX < screen.frame.minX { return true }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = NSRect(
                x: screen.frame.minX + left.maxX, y: frame.minY, width: right.minX - left.maxX, height: frame.height)
            if frame.intersects(notch) { return true }
        }
        return false
    }

    private static var crowd: [NSStatusItem] = []

    /// Debug only (`-CrowdMenuBar <n>`): adds placeholder items so ours gets pushed out.
    static func crowdMenuBar(count: Int) {
        for index in 0..<count {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "Placeholder \(index)"
            crowd.append(item)
        }
    }
}

/// Tells single from double clicks on the menu bar icon by timing: macOS reports every click
/// on a status item with a click count of 1. Times are event timestamps (system uptime).
struct ClickSequence {
    enum Kind: Equatable { case single, double, ignored }

    var interval: TimeInterval
    private var last = -TimeInterval.infinity
    private var lastDouble = -TimeInterval.infinity
    private var secondClickPending = false

    init(interval: TimeInterval) { self.interval = interval }

    mutating func click(at time: TimeInterval) -> Kind {
        defer { last = time }
        if time - lastDouble < interval { return .ignored }  // A third click.
        // A held button counts for a second more, not for a click much later.
        let held = secondClickPending && time - last < interval + 1
        secondClickPending = false
        if held || time - last < interval {
            lastDouble = time
            return .double
        }
        return .single
    }

    /// The interval ran out with the button held down: the next mouse-up completes a double click.
    mutating func awaitSecondClick() { secondClickPending = true }
}
