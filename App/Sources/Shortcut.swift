import AppKit
import Carbon.HIToolbox
import SwiftUI
import UAwakeCore

/// Registers the global shortcut with Carbon `RegisterEventHotKey`, which needs no
/// Accessibility permission (confirmed by the sandbox spike).
@MainActor
final class HotKeyController {
    var onPress: () -> Void = {}
    private var reference: EventHotKeyRef?
    private static weak var current: HotKeyController?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                MainActor.assumeIsolated { HotKeyController.current?.onPress() }
                return noErr
            }, 1, &spec, nil, nil)
        Self.current = self
    }

    func register(_ shortcut: GlobalShortcut) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), EventHotKeyID(signature: 0x7561_776B, id: 1),
            GetApplicationEventTarget(), 0, &reference)
        self.reference = reference
        return status
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
}

extension AppModel {
    /// Saves and registers a shortcut; returns a message if it couldn't be registered.
    func setShortcut(_ shortcut: GlobalShortcut?) -> String? {
        settings.globalShortcut = shortcut
        registerShortcut()
        return shortcutProblem
    }
}

extension GlobalShortcut {
    /// From a key-down event; `nil` without Command, Option or Control.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        guard modifiers & (cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: Int(event.keyCode), carbonModifiers: modifiers)
    }

    /// e.g. ⌃⌥⌘U, in the standard modifier order.
    var displayString: String {
        var text = ""
        if carbonModifiers & controlKey != 0 { text += "⌃" }
        if carbonModifiers & optionKey != 0 { text += "⌥" }
        if carbonModifiers & shiftKey != 0 { text += "⇧" }
        if carbonModifiers & cmdKey != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The key's character on the current keyboard layout.
    static func keyName(_ keyCode: Int) -> String {
        if let name = specialKeys[keyCode] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Click, then type a shortcut with Command, Option or Control. Escape cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: GlobalShortcut?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button {
                isRecording ? stop() : record()
            } label: {
                if isRecording {
                    Text("Type a shortcut…")
                } else if let shortcut {
                    Text(shortcut.displayString)
                } else {
                    Text("Record Shortcut")
                }
            }
            .accessibilityLabel(accessibilityLabel)
            if shortcut != nil && !isRecording {
                Button("Clear") { shortcut = nil }
                    .accessibilityLabel(Text("Clear shortcut"))
            }
        }
        .onDisappear(perform: stop)
    }

    private var accessibilityLabel: Text {
        if isRecording { return Text("Recording. Type a shortcut, or press Escape to cancel.") }
        if let shortcut { return Text("Shortcut \(shortcut.displayString). Press to change.") }
        return Text("Record a shortcut")
    }

    private func record() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                MainActor.assumeIsolated { stop() }
            } else if let recorded = GlobalShortcut(event: event) {
                MainActor.assumeIsolated {
                    shortcut = recorded
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
