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
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        BannerList(model: model)
                        HeroView(model: model, now: context.date)
                        QuickStartView(model: model, columns: 3)
                        if model.showsSessionList {
                            SessionList(model: model, now: context.date)
                        }
                        RulesStripView(model: model, now: context.date)
                        StatusStrip(chips: model.statusChips)
                    }
                    .padding(16)
                }
                Divider()
                FooterView(model: model, now: context.date, showsQuit: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 360)
        .frame(maxHeight: model.maxHeight)
        // A near-opaque backing keeps text contrast independent of the desktop behind.
        .background(Color.popoverBacking.opacity(0.95))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("uawake", comment: "App name in the popover header").font(.title3.weight(.bold))
            Spacer()
            Button {
                model.openMainWindow(.general)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .help(Text("Settings…"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(Color.secondaryText)
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
        .card(radius: 16, tint: hero.kind == .idle ? nil : (hero.isEndingSoon ? Tone.caution : Tone.good).color)
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
                IconTile(symbol: "moon.zzz.fill", tint: Color(nsColor: Palette.indigo), size: large ? 44 : 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Mac can sleep normally").font(large ? .title2.weight(.semibold) : .headline)
                    Text("Keep it awake for a while, or until you turn it off.")
                        .font(.callout).foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            toggle
        }
    }

    private func active(_ hero: Hero) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(hero.isEndingSoon ? "Ending soon" : "Keeping your Mac awake")
            } icon: {
                Image(systemName: hero.isEndingSoon ? "hourglass" : "checkmark.circle.fill")
                    .foregroundStyle((hero.isEndingSoon ? Tone.caution : Tone.good).color)
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
                .foregroundStyle(hero.isEndingSoon ? Tone.caution.color : Color.primary)
                .contentTransition(.numericText(countsDown: true))
                Spacer()
                toggle
            }
            Text(hero.caption).font(.callout).foregroundStyle(Color.secondaryText)
            if let progress = hero.progress {
                ThinProgressBar(value: progress, tint: (hero.isEndingSoon ? Tone.caution : Tone.good).color)
                    .padding(.top, 4)
            }
            if let row = model.singleRow {
                singleSession(row)
            }
        }
    }

    /// With exactly one session the list is hidden: its name and extend buttons live here.
    private func singleSession(_ row: SessionRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(row.isPaused ? "\(row.subtitle) · Paused" : row.subtitle)
                    .font(.caption).foregroundStyle(Color.secondaryText).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if row.canExtend {
                ExtendButtons(row: row, model: model)
            }
        }
        .padding(.top, 6)
    }
}

struct ExtendButtons: View {
    let row: SessionRow
    let model: PopoverViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button("+15 min") { model.extend(row.id, by: .seconds(900)) }
                .accessibilityLabel(Text("Extend \(row.title) by 15 minutes"))
            Button("+1 hr") { model.extend(row.id, by: .seconds(3600)) }
                .accessibilityLabel(Text("Extend \(row.title) by 1 hour"))
        }
        .buttonStyle(PillButtonStyle(compact: true))
    }
}

struct QuickStartView: View {
    @Bindable var model: PopoverViewModel
    let columns: Int
    @State private var showsUntil = false

    var body: some View {
        let current = model.currentManualCondition
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: current == nil
                    ? String(localized: "Keep awake for")
                    : String(localized: "Change to", comment: "Preset header while a manual session runs"))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), alignment: .leading,
                spacing: 8
            ) {
                ForEach(model.presets, id: \.self) { preset in
                    let selected = preset == current
                    Button {
                        model.start(preset)
                    } label: {
                        Text(preset.chipTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(selected: selected))
                    .accessibilityLabel(Text("Keep awake: \(preset.chipTitle)", comment: "Preset chip, VoiceOver"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Button {
                    showsUntil.toggle()
                } label: {
                    Label("Until…", systemImage: "clock").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(selected: showsUntil || current.map(Self.isUntil) == true))
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

    private static func isUntil(_ condition: EndCondition) -> Bool {
        if case .until = condition { return true }
        return false
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
                        .foregroundStyle(Color.secondaryText)
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
                        let subtitle = model.ruleSubtitle(row, now: now) ?? row.subtitle
                        Text(row.isPaused ? "\(subtitle) · Paused" : subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
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
                        .foregroundStyle(endingSoon ? Tone.caution.color : Color.secondaryText)
                    }
                    Button {
                        model.stop(row.id)
                    } label: {
                        Label("Stop", systemImage: "xmark.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.secondaryText)
                    .accessibilityLabel(
                        row.source == .rule
                            ? Text("Stop rule \(row.title)", comment: "Stop button on a rule's session, VoiceOver")
                            : Text("Stop \(row.title)")
                    )
                    .help(row.source == .rule ? Text("Stop until this rule's conditions end and return") : Text("Stop"))
                }
                if row.canExtend {
                    ExtendButtons(row: row, model: model)
                }
            }
        }
        .padding(large ? 14 : 10)
    }
}

/// Rules at a glance: how many match, and "Pause all rules". Hidden when there are no rules.
struct RulesStripView: View {
    let model: PopoverViewModel
    let now: Date

    var body: some View {
        if let strip = model.rulesStrip(now: now) {
            let tone: Tone = strip.isPaused ? .caution : .neutral
            HStack(spacing: 8) {
                Image(systemName: strip.isPaused ? "pause.circle.fill" : "wand.and.stars")
                    .foregroundStyle(strip.isPaused ? tone.color : SessionSource.rule.tint)
                    .accessibilityHidden(true)
                Text(strip.text).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
                Spacer(minLength: 4)
                if strip.isPaused {
                    Button("Resume") { model.resumeRules() }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .accessibilityLabel(Text("Resume rules"))
                        .accessibilityIdentifier("PopoverResumeRules")
                } else {
                    Menu {
                        ForEach(PauseChoice.allCases, id: \.self) { choice in
                            Button(choice.title) { model.pauseRules(choice) }
                        }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(Text("Pause all rules"))
                    .accessibilityIdentifier("PopoverPauseRules")
                }
                Button {
                    model.openMainWindow(.rules)
                } label: {
                    Label("Open Rules", systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.secondaryText)
                .help(Text("Open Rules"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .card(radius: 12, tint: strip.isPaused ? tone.color : nil)
            .accessibilityElement(children: .contain)
        }
    }
}

struct FooterView: View {
    let model: PopoverViewModel
    let now: Date
    var showsQuit = false

    var body: some View {
        HStack {
            let today = PopoverViewModel.keptAwakeText(model.keptAwakeToday(now: now))
            Label {
                Text("Kept awake today: \(today)").monospacedDigit()
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(Color.secondaryText)
            Spacer()
            if showsQuit {
                Button("Open uawake") { model.openMainWindow(.overview) }
                    .buttonStyle(PillButtonStyle(compact: true))
                Button("Quit uawake") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .keyboardShortcut("q")
            }
        }
    }
}
