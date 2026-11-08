import AppKit
import SwiftUI

/// A reusable window hosting SwiftUI content, brought to the front on `show()`.
@MainActor
class HostingWindowController {
    private(set) var window: NSWindow?

    func show<Content: View>(title: String, identifier: String, content: () -> Content) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class SettingsSelection {
    var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController: HostingWindowController {
    private let model: AppModel
    private let selection = SettingsSelection()

    init(model: AppModel) {
        self.model = model
    }

    func show(tab: SettingsTab?) {
        if let tab { selection.tab = tab }
        show(title: String(localized: "uawake Settings", comment: "Settings window title"), identifier: "Settings") {
            SettingsView(model: model, selection: selection).defaultAppStorage(model.settings.defaults)
        }
    }
}

@MainActor
final class WelcomeWindowController: HostingWindowController {
    private let model: AppModel
    private let welcome: WelcomeModel

    init(model: AppModel, statusItem: StatusItemController) {
        self.model = model
        welcome = WelcomeModel(model: model, statusItem: statusItem)
    }

    func show() {
        show(title: String(localized: "Welcome to uawake", comment: "Welcome window title"), identifier: "Welcome") {
            WelcomeView(welcome: welcome) { [weak self] in
                self?.model.settings.firstRunCompleted = true
                self?.window?.close()
            }
        }
        welcome.checkIconVisibility()
    }
}
