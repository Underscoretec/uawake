import AppKit
import SwiftUI
import UAwakeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var mainWindow: MainWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var previewWindow: NSWindow?
    private var standIn: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting unit tests: they build their own models; show nothing.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let options = LaunchOptions(ProcessInfo.processInfo.arguments)
        if let appearance = options.appearance { NSApplication.shared.appearance = NSAppearance(named: appearance) }

        let model = AppModel(uiTesting: options.uiTesting, fixedDeviceState: options.deviceState)
        self.model = model
        if options.showsCountdown { model.settings.showsCountdown = true }
        let mainWindow = MainWindowController(model: model)
        self.mainWindow = mainWindow
        model.popover.openMainWindow = { section in mainWindow.show(section: section) }

        // Debug aid for the notch check: crowd the menu bar before adding our item.
        if let count = options.crowdMenuBar { StatusItemController.crowdMenuBar(count: count) }
        let statusItem = StatusItemController(model: model, keepsPopoverOpen: options.uiTesting)
        self.statusItem = statusItem

        if options.uiTesting {
            model.popover.showPopover = {}  // The stand-in is already on screen.
            if let url = options.url { model.open(url) }
            if options.showsMainWindow {
                mainWindow.show(section: .overview)
            } else {
                showPopoverStandIn(model)
            }
            if options.showsMenuBarPreview { showMenuBarPreview(model) }
        } else if !model.settings.firstRunCompleted {
            let welcome = WelcomeWindowController(model: model, statusItem: statusItem)
            welcomeWindow = welcome
            welcome.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model?.open(url) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.quit()
    }

    /// UI tests and screenshots drive the popover's exact content in a stand-in panel with
    /// the popover material, pinned under the menu bar. The real NSPopover hangs off the
    /// status item, which macOS may not place on a crowded test Mac.
    private func showPopoverStandIn(_ model: AppModel) {
        let controller = NSHostingController(
            rootView: PopoverView(model: model.popover)
                .background(PopoverMaterial())
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .defaultAppStorage(model.settings.defaults))
        controller.sizingOptions = .preferredContentSize
        let window = KeyableWindow(contentViewController: controller)
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.title = "Popover"
        window.identifier = NSUserInterfaceItemIdentifier("Popover")
        window.delegate = self
        standIn = window
        pinUnderMenuBar(window)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    /// Keeps the stand-in's top edge under the menu bar as its content grows.
    func windowDidResize(_ notification: Notification) {
        if let standIn, notification.object as? NSWindow === standIn { pinUnderMenuBar(standIn) }
    }

    private func pinUnderMenuBar(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: visible.maxX - window.frame.width - 160, y: visible.maxY - 6))
    }

    /// Screenshots of the menu bar pill in the app's appearance (the real menu bar follows
    /// the system and the wallpaper, so tests can't switch it).
    private func showMenuBarPreview(_ model: AppModel) {
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: MenuBarPreview(model: model.popover)))
        window.title = "Menu Bar Preview"
        window.identifier = NSUserInterfaceItemIdentifier("MenuBarPreview")
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.level = .floating
        window.orderFrontRegardless()
        previewWindow = window
    }
}

/// Launch arguments for UI tests, screenshots and debugging.
struct LaunchOptions {
    var uiTesting = false
    var showsMainWindow = false
    var showsMenuBarPreview = false
    var showsCountdown = false
    var appearance: NSAppearance.Name?
    var deviceState: DeviceState?
    var crowdMenuBar: Int?
    /// Routed through the URL scheme at launch (`-UITestOpenURL uawake://…`).
    var url: URL?

    init(_ arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        uiTesting = arguments.contains("-UITesting")
        showsMainWindow = arguments.contains("-UITestMainWindow")
        showsMenuBarPreview = arguments.contains("-UITestMenuBarPreview")
        showsCountdown = arguments.contains("-UITestCountdown")
        switch value(after: "-UITestAppearance") {
        case "dark": appearance = .darkAqua
        case "light": appearance = .aqua
        default: appearance = nil
        }
        // A fixed, plausible power state so screenshots don't depend on the test Mac.
        switch value(after: "-UITestDeviceState") {
        case "lowPower":
            deviceState = DeviceState(
                batteryLevel: 64, powerSource: .battery, isLowPowerModeEnabled: true, thermalState: .nominal)
        case "battery":
            deviceState = DeviceState(
                batteryLevel: 76, powerSource: .battery, isLowPowerModeEnabled: false, thermalState: .nominal)
        default:
            deviceState = nil
        }
        crowdMenuBar = value(after: "-CrowdMenuBar").flatMap(Int.init)
        url = value(after: "-UITestOpenURL").flatMap(URL.init(string:))
    }
}

/// The status item's pill drawn on light and dark menu-bar backgrounds.
private struct MenuBarPreview: View {
    let model: PopoverViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let image = StatusItemController.statusImage(
                style: model.settings.iconStyle, active: model.isAwake,
                countdown: model.settings.showsCountdown ? model.countdown(now: context.date) : nil)
            HStack(spacing: 14) {
                Image(systemName: "wifi")
                Image(nsImage: image).renderingMode(.template)
                Image(systemName: "battery.75percent")
                Text(verbatim: "Sun 8 Nov  09:41")
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(.bar)
        }
    }
}

/// The popover's material, for the UI-test stand-in.
private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Borderless windows can't become key by default, so their first click would be lost.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
