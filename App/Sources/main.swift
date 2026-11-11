import AppKit

// AppKit lifecycle: the status item needs NSStatusItem (MenuBarExtra can't tell
// primary from secondary clicks). SwiftUI views are hosted in the popover and windows.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.mainMenu = makeMainMenu()
NSApplication.shared.run()
