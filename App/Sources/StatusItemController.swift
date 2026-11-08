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
    private var ticker: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model.popover).defaultAppStorage(model.settings.defaults))
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityHelp(
                String(
                    localized: "Click to turn uawake on or off. Option-click or right-click for options.",
                    comment: "VoiceOver help for the menu bar icon"))
        }
        model.popover.showPopover = { [weak self] in self?.showPopover() }
        observe()
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

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.popover.reload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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
        let symbols = Self.symbols(model.settings.iconStyle)
        let image = NSImage(
            systemSymbolName: active ? symbols.active : symbols.inactive, accessibilityDescription: nil)
        image?.isTemplate = true  // Follows light, dark and tinted menu bars.
        button.image = image

        let countdown = model.settings.showsCountdown ? viewModel.countdown(now: Date()) : nil
        button.attributedTitle = NSAttributedString(
            string: countdown.map { " " + $0 } ?? "",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
        button.setAccessibilityLabel(viewModel.statusAccessibilityLabel(now: Date()))

        let needsTicker = countdown != nil
        if needsTicker && ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !needsTicker {
            ticker?.invalidate()
            ticker = nil
        }
    }

    static func symbols(_ style: IconStyle) -> (active: String, inactive: String) {
        switch style {
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
