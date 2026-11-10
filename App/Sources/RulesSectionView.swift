import SwiftUI
import UAwakeCore

/// The Rules section of the main window: the rule list, pause controls, notices and the
/// empty state with templates. Rules open in `RuleEditorView` as a sheet.
struct RulesSectionView: View {
    let model: RulesModel
    @State private var editing: RuleEditorRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RulesHeader(model: model) { editing = RuleEditorRequest(rule: $0) }
                RulesNotices(model: model)
                if model.rules.isEmpty {
                    RulesEmptyState(model: model) { editing = RuleEditorRequest(rule: $0) }
                } else if needsTicking {
                    TimelineView(.periodic(from: .now, by: 1)) { context in list(now: context.date) }
                } else {
                    list(now: .now)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .sheet(item: $editing) { request in
            RuleEditorView(model: model, rule: request.rule, tab: request.tab)
        }
        .task {
            // Screenshots: open the editor once the section is on screen.
            if let tab = model.uiTestEditor, let first = model.rules.first {
                model.uiTestEditor = nil
                editing = RuleEditorRequest(rule: first, tab: tab == .test ? .test : .edit)
            }
        }
    }

    private func list(now: Date) -> some View {
        RulesList(model: model, now: now) { editing = RuleEditorRequest(rule: $0) }
    }

    /// Only countdown pills need a redraw every second.
    private var needsTicking: Bool {
        model.rules.contains { rule in
            switch model.status(of: rule) {
            case .lingering, .waiting(_, .some): true
            default: false
            }
        }
    }
}

struct RuleEditorRequest: Identifiable {
    let id = UUID()
    let rule: Rule
    var tab: RuleEditorView.Tab = .edit
}

extension RuleStatusPill {
    var chip: StatusChip { StatusChip(id: text, symbol: symbol, text: text, tone: tone, accessibilityLabel: text) }
}

private struct RulesHeader: View {
    let model: RulesModel
    let open: (Rule) -> Void

    var body: some View {
        HStack {
            Menu {
                Button("Blank Rule") { open(Rule(name: "", conditions: [])) }
                Divider()
                ForEach(RulesModel.templates) { template in
                    Button {
                        open(template.rule)
                    } label: {
                        Label(template.title, systemImage: template.symbol)
                    }
                }
            } label: {
                Label("New Rule", systemImage: "plus")
            }
            .fixedSize()
            .disabled(model.isReadOnly)
            .accessibilityIdentifier("NewRuleMenu")
            Spacer()
            if model.engine.pause == nil {
                Menu {
                    ForEach(PauseChoice.allCases, id: \.self) { choice in
                        Button(choice.title) { model.pause(choice) }
                    }
                } label: {
                    Label("Pause Rules", systemImage: "pause.circle")
                }
                .fixedSize()
                .accessibilityIdentifier("PauseRulesMenu")
            }
        }
    }
}

/// Pause, file and save problems. Each is a tinted card with an icon and text.
private struct RulesNotices: View {
    let model: RulesModel

    var body: some View {
        if let pause = model.engine.pause {
            RulesNotice(symbol: "pause.circle.fill", tone: .caution, title: pause.text(now: .now)) {
                Button("Resume") { model.resume() }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .accessibilityLabel(Text("Resume rules"))
                    .accessibilityIdentifier("ResumeRules")
            }
        }
        switch model.problem {
        case .newerVersion:
            RulesNotice(
                symbol: "exclamationmark.triangle.fill", tone: .caution,
                title: String(localized: "Rules from a newer version of uawake", comment: "Rules notice"),
                message: String(
                    localized: "These rules were made by a newer uawake. They are off and can't be edited here.",
                    comment: "Rules notice"))
        case .corrupt:
            RulesNotice(
                symbol: "exclamationmark.triangle.fill", tone: .caution,
                title: String(localized: "The rules file couldn't be read", comment: "Rules notice"),
                message: String(localized: "It was set aside, so rules start empty.", comment: "Rules notice"))
        case nil:
            EmptyView()
        }
        if model.saveFailed {
            RulesNotice(
                symbol: "xmark.octagon.fill", tone: .critical,
                title: String(localized: "Couldn't save rules", comment: "Rules notice"),
                message: String(
                    localized: "Your changes apply until uawake quits, but they weren't saved.", comment: "Rules notice"
                ))
        }
        if model.unsupportedCount > 0 {
            RulesNotice(
                symbol: "info.circle.fill", tone: .neutral,
                title: String(
                    localized: "\(model.unsupportedCount) rules from a newer version are kept but not shown.",
                    comment: "Rules notice: rules this version can't read"))
        }
    }
}

private struct RulesNotice<Actions: View>: View {
    let symbol: String
    let tone: Tone
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: symbol, tint: tone.color, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                if let message {
                    Text(message).font(.callout).foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(12)
        .card(radius: 14, tint: tone == .neutral ? nil : tone.color)
        .accessibilityElement(children: .contain)
    }
}

extension RulesNotice where Actions == EmptyView {
    init(symbol: String, tone: Tone, title: String, message: String? = nil) {
        self.init(symbol: symbol, tone: tone, title: title, message: message) { EmptyView() }
    }
}

private struct RulesList: View {
    let model: RulesModel
    let now: Date
    let open: (Rule) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                if index > 0 { Divider().padding(.leading, 54) }
                RuleRowView(model: model, rule: rule, now: now) { open(rule) }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RulesList")
    }
}

private struct RuleRowView: View {
    let model: RulesModel
    let rule: Rule
    let now: Date
    let open: () -> Void

    var body: some View {
        let status = model.status(of: rule)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(
                            symbol: rule.conditions.first?.kind.symbol ?? "wand.and.stars",
                            tint: SessionSource.rule.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: rule.name).font(.body.weight(.semibold))
                            Text(verbatim: rule.summary)
                                .font(.callout)
                                .foregroundStyle(Color.secondaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isReadOnly)
                .accessibilityLabel(Text("Edit rule \(rule.name)"))
                .accessibilityValue(Text(verbatim: rule.summary))
                StatusChipView(chip: status.pill(now: now).chip)
                Toggle(
                    isOn: Binding(get: { rule.enabled }, set: { model.setEnabled($0, for: rule.id) })
                ) {
                    Text("Enable rule \(rule.name)")
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.isReadOnly)
            }
            if case .needsPermission(let permission) = status {
                PermissionActionButton(model: model, permission: permission, firstAskTitle: .grantAccess)
                    .padding(.leading, 42)
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Rule-\(rule.name)")
    }
}

private struct RulesEmptyState: View {
    let model: RulesModel
    let open: (Rule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No rules yet. Start from one of these, or choose New Rule.")
                .foregroundStyle(Color.secondaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(RulesModel.templates) { template in
                    Button {
                        open(template.rule)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            IconTile(symbol: template.symbol, tint: SessionSource.rule.tint)
                            Text(template.title).font(.headline)
                            Text(template.detail).font(.callout).foregroundStyle(Color.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .card()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isReadOnly)
                    .accessibilityLabel(Text("New rule from template: \(template.title)"))
                    .accessibilityValue(Text(template.detail))
                }
            }
        }
    }
}
