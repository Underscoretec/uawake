import AppKit
import SwiftUI
import UAwakeCore

/// The menu bar popover: header, banners, hero, quick start, sessions, status, footer.
struct PopoverView: View {
    @Bindable var model: PopoverViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 16) {
                    BannerList(model: model)
                    HeroView(model: model, now: context.date)
                    QuickStartView(model: model, columns: 3)
                    if !model.rows.isEmpty {
                        SessionList(model: model, now: context.date)
                    }
                    StatusStrip(chips: model.statusChips)
                }
                .padding(16)
                Divider()
                FooterView(model: model, now: context.date)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(verbatim: "uawake").font(.title3.weight(.bold))
            Spacer()
            Button {
                model.openMainWindow(.general)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .help(Text("Settings…"))
            Button {
                model.openMainWindow(.overview)
            } label: {
                Label("Open the uawake window", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help(Text("Open the uawake window"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .medium))
    }
}

struct BannerList: View {
    let model: PopoverViewModel

    var body: some View {
        ForEach(model.banners) { banner in
            BannerView(banner: banner, open: { model.open(banner) }, dismiss: { model.dismiss(banner) })
        }
    }
}

struct HeroView: View {
    let model: PopoverViewModel
    let now: Date
    var large = false

    var body: some View {
        let hero = model.hero(now: now)
        Group {
            if hero.kind == .idle {
                idle
            } else {
                active(hero)
            }
        }
        .padding(large ? 20 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16, tint: hero.kind == .idle ? nil : (hero.isEndingSoon ? .orange : .green))
    }

    private var toggle: some View {
        Toggle(isOn: Binding(get: { model.isOn }, set: { _ in model.toggle() })) {
            Text("Keep awake")
        }
        .toggleStyle(HeroToggleStyle())
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "moon.zzz.fill", tint: .indigo, size: large ? 44 : 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Mac can sleep normally").font(large ? .title2.weight(.semibold) : .headline)
                    Text("Keep it awake for a while, or until you turn it off.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            toggle
        }
    }

    private func active(_ hero: Hero) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if hero.isEndingSoon {
                    Label {
                        Text("Ending soon")
                    } icon: {
                        Image(systemName: "hourglass").foregroundStyle(.orange)
                    }
                } else {
                    Label {
                        Text("Keeping your Mac awake")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .font(.caption.weight(.semibold))
            HStack(alignment: .firstTextBaseline) {
                Group {
                    if let countdown = hero.countdown {
                        Text(countdown)
                            .accessibilityLabel(Text("\(countdown) left", comment: "Popover: time remaining"))
                    } else {
                        Text("Awake")
                    }
                }
                .font(.system(size: large ? 56 : 44, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(hero.isEndingSoon ? .orange : .primary)
                .contentTransition(.numericText(countsDown: true))
                Spacer()
                toggle
            }
            Text(hero.caption).font(.callout).foregroundStyle(.secondary)
            if let progress = hero.progress {
                ThinProgressBar(value: progress, tint: hero.isEndingSoon ? .orange : .green)
                    .padding(.top, 4)
            }
        }
    }
}

struct QuickStartView: View {
    @Bindable var model: PopoverViewModel
    let columns: Int
    @State private var showsUntil = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: String(localized: "Keep awake for"))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), alignment: .leading,
                spacing: 8
            ) {
                ForEach(model.presets, id: \.self) { preset in
                    Button {
                        model.start(preset)
                    } label: {
                        Text(preset.chipTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel(Text("Keep awake: \(preset.chipTitle)", comment: "Preset chip, VoiceOver"))
                }
                Button {
                    showsUntil.toggle()
                } label: {
                    Label("Until…", systemImage: "clock").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(selected: showsUntil))
            }
            if showsUntil {
                HStack {
                    DatePicker(selection: $model.untilTime, displayedComponents: .hourAndMinute) {
                        Text("Until")
                    }
                    Spacer()
                    Button("Start") {
                        model.startUntil()
                        showsUntil = false
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .accessibilityLabel(Text("Keep awake until the chosen time"))
                }
                .padding(10)
                .card(radius: 12)
            }
        }
    }
}

struct SessionList: View {
    let model: PopoverViewModel
    let now: Date
    var large = false

    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: String(localized: "Sessions", comment: "Section header"),
                trailing: String(localized: "\(rows.count) active", comment: "Session count"))
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Text("No active sessions")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    SessionCardRow(row: row, model: model, now: now, large: large)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, large ? 62 : 52)
                    }
                }
            }
            .card(radius: 14)
        }
    }
}

struct SessionCardRow: View {
    let row: SessionRow
    let model: PopoverViewModel
    let now: Date
    let large: Bool

    var body: some View {
        let endingSoon = row.deadline.map { model.isEndingSoon($0, now: now) } ?? false
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: row.source.symbol, tint: row.source.tint, size: large ? 38 : 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.body.weight(.medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(row.sourceName)
                            if row.isPaused {
                                Text("Paused")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    if let remaining = model.remaining(row, now: now), !row.isPaused {
                        HStack(spacing: 3) {
                            if endingSoon {
                                Image(systemName: "hourglass").accessibilityHidden(true)
                            }
                            Text(remaining)
                        }
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(endingSoon ? .orange : .secondary)
                    }
                    Button {
                        model.stop(row.id)
                    } label: {
                        Label("Stop", systemImage: "xmark.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Stop \(row.title)"))
                }
                if row.canExtend {
                    HStack(spacing: 6) {
                        Button("+15 min") { model.extend(row.id, by: .seconds(900)) }
                            .accessibilityLabel(Text("Extend \(row.title) by 15 minutes"))
                        Button("+1 hr") { model.extend(row.id, by: .seconds(3600)) }
                            .accessibilityLabel(Text("Extend \(row.title) by 1 hour"))
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                }
            }
        }
        .padding(large ? 14 : 10)
    }
}

struct FooterView: View {
    let model: PopoverViewModel
    let now: Date

    var body: some View {
        HStack {
            let today = PopoverViewModel.keptAwakeText(model.keptAwakeToday(now: now))
            Label {
                Text("Kept awake today: \(today)").monospacedDigit()
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Quit uawake") { NSApplication.shared.terminate(nil) }
                .buttonStyle(PillButtonStyle(compact: true))
                .keyboardShortcut("q")
        }
    }
}
