import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private var testWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting unit tests: they build their own models; show nothing.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let arguments = ProcessInfo.processInfo.arguments
        let uiTesting = arguments.contains("-UITesting")
        let model = AppModel(uiTesting: uiTesting)
        self.model = model
        let settingsWindow = SettingsWindowController(model: model)
        self.settingsWindow = settingsWindow
        model.popover.openSettings = { tab in settingsWindow.show(tab: tab) }

        // Debug aid for the notch check: crowd the menu bar before adding our item.
        if let index = arguments.firstIndex(of: "-CrowdMenuBar"), index + 1 < arguments.count,
            let count = Int(arguments[index + 1])
        {
            StatusItemController.crowdMenuBar(count: count)
        }
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem

        if uiTesting {
            showPopoverInWindow(model)
            if arguments.contains("-UITestSettings") { settingsWindow.show(tab: nil) }
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

    /// UI tests drive the popover's content in a normal window, which XCUITest can reach
    /// without clicking the status item.
    private func showPopoverInWindow(_ model: AppModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PopoverView(model: model.popover)))
        window.title = "Popover"
        window.identifier = NSUserInterfaceItemIdentifier("PopoverTestWindow")
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        testWindow = window
    }
}
