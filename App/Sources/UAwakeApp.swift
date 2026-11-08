import SwiftUI
import UAwakeCore

@main
struct UAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(systemName: model.engine.sessions.isEmpty ? "cup.and.saucer" : "cup.and.saucer.fill")
                .accessibilityLabel(
                    model.engine.sessions.isEmpty ? Text("uawake: off") : Text("uawake: keeping your Mac awake"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
