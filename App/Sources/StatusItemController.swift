import AppKit
import SwiftUI
import UAwakeCore

/// The menu bar item. Primary click toggles the default session; secondary click,
/// Control-click or Option-click opens the popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    /// Space below the anchor for the popover, set each time it opens.
    private var availableHeight = CGFloat.greatestFiniteMagnitude
    private var ticker: Timer?
    /// The countdown text last drawn in the menu bar, and when (acceptance sampling).
    private(set) var lastCountdown: String?
    private(set) var lastRendered: Date?

    private struct Appearance: Equatable {
        let style: IconStyle
        let active: Bool
        let countdown: String?
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
            button.setAccessibilityHelp(
                String(
                    localized: "Click to turn uawake on or off. Option-click or right-click for options.",
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
    }

    @objc private func clicked() {
        let event = NSApplication.shared.currentEvent
        let wantsMenu =
            event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu || popover.isShown {
            togglePopover()
        } else {
            model.popover.toggle()
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
        let active = viewModel.isAwake
        let now = Date()
        let remaining = model.settings.showsCountdown ? viewModel.countdownRemaining(now: now) : nil
        let countdown = remaining.map(PopoverViewModel.menuBarText)
        let appearance = Appearance(style: model.settings.iconStyle, active: active, countdown: countdown)
        if appearance != drawn {
            button.image = Self.statusImage(style: appearance.style, active: active, countdown: countdown)
            button.setAccessibilityLabel(viewModel.statusAccessibilityLabel(now: Date()))
            drawn = appearance
        }
        lastCountdown = countdown
        lastRendered = Date()

        // One-shot timer for the moment the text next changes: once a minute, then every
        // second in the final minute.
        ticker?.invalidate()
        ticker = nil
        if let remaining {
            let delay = PopoverViewModel.secondsUntilMenuBarChange(remaining) + 0.02
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    /// The icon alone when idle (or the countdown is off); icon plus time left in a
    /// compact pill while a timed session runs. A template image, so the menu bar tints it
    /// for light, dark and wallpaper-tinted bars.
    static func statusImage(style: IconStyle, active: Bool, countdown: String?) -> NSImage {
        let symbol = symbolImage(style: style, active: active)
        guard let countdown else { return symbol }
        let text = NSAttributedString(string: countdown, attributes: pillTextAttributes)
        let textSize = text.size()
        let height: CGFloat = 18
        let symbolSize = NSSize(width: symbol.size.width * 0.86, height: symbol.size.height * 0.86)
        let size = NSSize(width: 7 + symbolSize.width + 4 + ceil(textSize.width) + 8, height: height)
        // Drawn once into a 2x bitmap. A drawing-handler image would re-run this code every
        // time the menu bar draws the item, which cost ~0.9% CPU with a 1 s countdown.
        let scale: CGFloat = 2
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return symbol }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: height / 2, yRadius: height / 2).fill()
        symbol.draw(
            in: NSRect(x: 7, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
        text.draw(at: NSPoint(x: 7 + symbolSize.width + 4, y: (height - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    private static let pillTextAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black,
    ]
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
        guard
            let vector,
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(vector.size.width * 2)),
                pixelsHigh: Int(ceil(vector.size.height * 2)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSImage() }
        bitmap.size = vector.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        vector.draw(in: NSRect(origin: .zero, size: vector.size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: vector.size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
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
