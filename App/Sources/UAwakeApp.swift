import SwiftUI
import UAwakeCore
import UAwakeSystem

@main
struct UAwakeApp: App {
    @State private var engine: DefaultSessionEngine

    init() {
        let engine = DefaultSessionEngine(assertions: IOKitAssertionProvider(), clock: SystemClock())
        _engine = State(initialValue: engine)
        let deviceState = SystemDeviceStateMonitor()
        let lifecycle = SystemSessionLifecycleMonitor()
        Task { for await state in deviceState.updates() { engine.apply(state) } }
        Task { for await event in lifecycle.events() { engine.handle(event) } }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: engine)
        } label: {
            Image(systemName: engine.sessions.isEmpty ? "cup.and.saucer" : "cup.and.saucer.fill")
                .accessibilityLabel(
                    engine.sessions.isEmpty ? Text("uawake: off") : Text("uawake: keeping your Mac awake"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
