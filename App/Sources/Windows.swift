import AppKit
import SwiftUI

/// A reusable window hosting SwiftUI content, brought to the front on `show()`.
@MainActor
class HostingWindowController {
    private(set) var window: NSWindow?

    func show<Content: View>(
        title: String, identifier: String, resizable: Bool = false, content: () -> Content
    ) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
            window.styleMask =
                resizable
                ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled, .closable]
            window.titlebarAppearsTransparent = resizable
            window.setContentSize(window.contentView?.fittingSize ?? .zero)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class MainWindowController: HostingWindowController {
    private let model: AppModel
    private let selection = MainSelection()

    init(model: AppModel) {
        self.model = model
    }

    func show(section: MainSection?) {
        if let section { selection.section = section }
        show(title: String(localized: "uawake", comment: "Main window title"), identifier: "Main", resizable: true) {
            MainWindowView(model: model, selection: selection).defaultAppStorage(model.settings.defaults)
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
