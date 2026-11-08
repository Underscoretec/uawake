import SwiftUI
import UAwakeCore

@MainActor
@Observable
final class MainSelection {
    var section: MainSection? = .overview
}

/// The main window: a sidebar of sections. Overview repeats the popover's hero and
/// sessions at a larger size; the rest are settings. Rules (1.0) and Diagnostics (1.2)
/// join the first sidebar group.
struct MainWindowView: View {
    let model: AppModel
    @Bindable var selection: MainSelection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.section) {
                Section {
                    row(.overview)
                }
                Section(String(localized: "Settings", comment: "Sidebar group")) {
                    ForEach([MainSection.durations, .safety, .appearance, .general]) { row($0) }
                }
                Section {
                    row(.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail(selection.section ?? .overview)
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    private func row(_ section: MainSection) -> some View {
        Label(section.title, systemImage: section.symbol).tag(section)
    }

    @ViewBuilder
    private func detail(_ section: MainSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title).font(.title2.weight(.bold))
                Text(section.subtitle).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            switch section {
            case .overview: OverviewSection(model: model.popover)
            case .durations: DurationsSettingsView(settings: model.settings)
            case .safety: SafetySettingsView()
            case .appearance: AppearanceSettingsView()
            case .general: GeneralSettingsView(model: model)
            case .about: AboutView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OverviewSection: View {
    let model: PopoverViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BannerList(model: model)
                    HeroView(model: model, now: context.date, large: true)
                    StatusStrip(chips: model.statusChips)
                    QuickStartView(model: model, columns: 4)
                    SessionList(model: model, now: context.date, large: true)
                    FooterView(model: model, now: context.date)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: 680, alignment: .leading)
            }
        }
    }
}
