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
    private var closeObserver: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
    }

    /// While the main window is open uawake is a regular app (Dock icon, ⌘-Tab, menu bar)
    /// so the window can be found again; it goes back to menu-bar-only when it closes.
    func show(section: MainSection?) {
        if let section { selection.section = section }
        NSApplication.shared.setActivationPolicy(.regular)
        show(title: String(localized: "uawake", comment: "Main window title"), identifier: "Main", resizable: true) {
            MainWindowView(model: model, selection: selection).defaultAppStorage(model.settings.defaults)
        }
        if closeObserver == nil, let window {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { _ = NSApplication.shared.setActivationPolicy(.accessory) }
            }
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

/// The menu bar shown while the main window makes uawake a regular app. The Edit menu
/// also gives text fields their ⌘C/⌘V/⌘Z key equivalents.
@MainActor
func makeMainMenu() -> NSMenu {
    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: title)
        items.forEach { item.submenu?.addItem($0) }
        return item
    }
    let menu = NSMenu()
    menu.addItem(
        submenu(
            "uawake",
            [
                NSMenuItem(
                    title: String(localized: "Close Window", comment: "Menu item"),
                    action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
                .separator(),
                NSMenuItem(
                    title: String(localized: "Quit uawake", comment: "Menu item"),
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
            ]))
    menu.addItem(
        submenu(
            String(localized: "Edit", comment: "Menu title"),
            [
                NSMenuItem(
                    title: String(localized: "Undo", comment: "Menu item"), action: Selector(("undo:")),
                    keyEquivalent: "z"),
                NSMenuItem(
                    title: String(localized: "Redo", comment: "Menu item"), action: Selector(("redo:")),
                    keyEquivalent: "Z"),
                .separator(),
                NSMenuItem(
                    title: String(localized: "Cut", comment: "Menu item"), action: #selector(NSText.cut(_:)),
                    keyEquivalent: "x"),
                NSMenuItem(
                    title: String(localized: "Copy", comment: "Menu item"), action: #selector(NSText.copy(_:)),
                    keyEquivalent: "c"),
                NSMenuItem(
                    title: String(localized: "Paste", comment: "Menu item"), action: #selector(NSText.paste(_:)),
                    keyEquivalent: "v"),
                NSMenuItem(
                    title: String(localized: "Select All", comment: "Menu item"),
                    action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            ]))
    return menu
}
