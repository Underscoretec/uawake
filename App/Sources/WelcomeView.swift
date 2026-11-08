import SwiftUI
import UAwakeCore

@MainActor
@Observable
final class WelcomeModel {
    private let model: AppModel
    private let statusItem: StatusItemController
    var iconHidden = false
    var notificationsAllowed: Bool?
    var launchesAtLogin: Bool {
        didSet { if launchesAtLogin != oldValue { model.setLaunchesAtLogin(launchesAtLogin) } }
    }

    init(model: AppModel, statusItem: StatusItemController) {
        self.model = model
        self.statusItem = statusItem
        launchesAtLogin = model.launchesAtLogin
    }

    var iconName: String { StatusItemController.symbols(model.settings.iconStyle).inactive }

    /// The status item settles a moment after launch, so check after a short delay.
    func checkIconVisibility() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            iconHidden = statusItem.isProbablyHidden
            AppModel.logger.notice("Status item probably hidden: \(self.iconHidden, privacy: .public)")
        }
    }

    func enableNotifications() {
        Task { notificationsAllowed = await model.notifications.requestAuthorization() }
    }
}

struct WelcomeView: View {
    @Bindable var welcome: WelcomeModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to uawake").font(.title.bold())
            Text(
                "uawake keeps your Mac awake when you need it: downloads, presentations, calls and long tasks. It stops by itself at low battery, in Low Power Mode or when your Mac gets too warm."
            )
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: welcome.iconName)
                    .font(.title)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find uawake in the menu bar").font(.headline)
                    Text(
                        "Click the icon to turn uawake on or off. Option-click or right-click it for durations and settings."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if welcome.iconHidden {
                Label {
                    Text(
                        "The uawake icon may be hidden by the camera notch or a full menu bar. To make room, hold Command and drag other icons out of the menu bar, or quit menu bar apps you don't need. You can also set a shortcut to turn uawake on in Settings."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            Divider()
            HStack {
                Button("Turn On Notifications", action: welcome.enableNotifications)
                    .disabled(welcome.notificationsAllowed == true)
                switch welcome.notificationsAllowed {
                case true?: Text("Notifications are on.").foregroundStyle(.secondary)
                case false?:
                    Text("Notifications are off. You can turn them on in System Settings.").foregroundStyle(.secondary)
                case nil: EmptyView()
                }
            }
            Text("uawake tells you before a session ends and when a safety guard stops one.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open uawake at login", isOn: $welcome.launchesAtLogin)

            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
