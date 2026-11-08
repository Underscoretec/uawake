import SwiftUI

/// Tab structure from the spec. Contents arrive with 0.1.
struct SettingsView: View {
    var body: some View {
        TabView {
            placeholder.tabItem { Label("General", systemImage: "gearshape") }
            placeholder.tabItem { Label("Durations", systemImage: "timer") }
            placeholder.tabItem { Label("Safety", systemImage: "shield") }
            placeholder.tabItem { Label("Appearance", systemImage: "paintbrush") }
            placeholder.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 300)
    }

    private var placeholder: some View {
        Text("Coming in 0.1.").foregroundStyle(.secondary)
    }

    private var about: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return VStack(spacing: 8) {
            Text("uawake — keep your Mac awake").font(.headline)
            Text("Version \(version)")
            Text("Copyright © 2026 Underscore Technology Pvt. Ltd. MIT licence.").font(.footnote)
        }
    }
}
