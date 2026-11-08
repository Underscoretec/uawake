import SwiftUI
import UAwakeCore
import os

struct PopoverView: View {
    let engine: DefaultSessionEngine

    private static let logger = Logger(subsystem: "com.underscoretec.uawake", category: "app")
    private static let defaultRequest = SessionRequest(
        source: .manual,
        reason: .standard(.manual, .indefinite),
        endCondition: .indefinite
    )

    private var isOn: Bool {
        engine.sessions.contains { $0.source == .manual || $0.source == .url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Keep awake", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                .toggleStyle(.switch)
            if engine.sessions.isEmpty {
                Text("No active sessions").foregroundStyle(.secondary)
            } else {
                ForEach(engine.sessions) { session in
                    Text(session.reason.localizedDescription)
                }
            }
            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit uawake") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 280)
    }

    private func toggle() {
        do {
            try engine.toggle(Self.defaultRequest)
        } catch {
            Self.logger.error("Toggle failed: \(String(describing: error), privacy: .public)")
        }
    }
}
