import SwiftUI
import UAwakeCore

/// Edits a draft copy of a rule, with a live Test view. Nothing is saved until Save.
struct RuleEditorView: View {
    enum Tab: Hashable { case edit, test }

    let model: RulesModel
    private let isExisting: Bool
    @State private var draft: Rule
    @State private var tab: Tab
    @Environment(\.dismiss) private var dismiss

    init(model: RulesModel, rule: Rule, tab: Tab = .edit) {
        self.model = model
        isExisting = model.rules.contains { $0.id == rule.id }
        _draft = State(initialValue: rule)
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Edit").tag(Tab.edit)
                Text("Test").tag(Tab.test)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(12)
            .accessibilityLabel(Text("Rule editor view"))
            .accessibilityIdentifier("RuleEditorTab")
            Divider()
            switch tab {
            case .edit:
                RuleEditTab(model: model, draft: $draft, isExisting: isExisting) {
                    model.delete(draft.id)
                    dismiss()
                }
            case .test:
                RuleTestTab(model: model, draft: draft)
            }
            Divider()
            footer.padding(12)
        }
        // Fits the main window's 560 pt minimum height; the tabs scroll.
        .frame(width: 560, height: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RuleEditor")
        .onAppear { model.engine.preview = draft }
        .onChange(of: draft) { _, new in model.engine.preview = new }
        .onDisappear { model.engine.preview = nil }
    }

    private var footer: some View {
        HStack {
            if let problem {
                Label(problem, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("RuleEditorCancel")
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || model.isReadOnly)
                .accessibilityIdentifier("RuleEditorSave")
        }
    }

    private var trimmedName: String {
        String(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Rule.maxNameLength))
    }

    /// Why Save is unavailable, if it is.
    private var problem: String? {
        if trimmedName.isEmpty {
            return String(localized: "Give the rule a name.", comment: "Rule editor: why Save is off")
        }
        if draft.conditions.isEmpty {
            return String(localized: "Add at least one condition.", comment: "Rule editor: why Save is off")
        }
        if !draft.conditions.allSatisfy(\.isComplete) {
            return String(localized: "Finish setting up every condition.", comment: "Rule editor: why Save is off")
        }
        return nil
    }

    private func save() {
        guard problem == nil else { return }
        model.save(
            Rule(
                id: draft.id, name: model.uniqueName(trimmedName, excluding: draft.id), enabled: draft.enabled,
                match: draft.match, conditions: draft.conditions, modes: draft.modes,
                lingerSeconds: draft.lingerSeconds, activeHours: draft.activeHours,
                preventSleepOnPower: draft.preventSleepOnPower))
        dismiss()
    }
}

// MARK: - Edit tab

private struct RuleEditTab: View {
    static let lingerOptions = [0, 30, 60, 120, 300, 600, 900, 1800]

    let model: RulesModel
    @Binding var draft: Rule
    let isExisting: Bool
    let delete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Presenting"))
                    .accessibilityIdentifier("RuleName")
            }
            Section {
                Picker("Keep awake when", selection: $draft.match) {
                    Text("All of these are true").tag(MatchMode.all)
                    Text("Any of these are true").tag(MatchMode.any)
                }
                ForEach(draft.conditions.indices, id: \.self) { index in
                    ConditionRowView(model: model, condition: condition(at: index)) {
                        if draft.conditions.indices.contains(index) { draft.conditions.remove(at: index) }
                    }
                }
                if draft.conditions.count < Rule.maxConditions {
                    addMenu
                }
            } header: {
                Text("Conditions").accessibilityAddTraits(.isHeader)
            }
            Section {
                Toggle("Mac", isOn: .constant(true)).disabled(true)
                Toggle("Keep the display on", isOn: mode(.display))
                Toggle("Disk", isOn: mode(.disk))
                DurationPicker(
                    title: String(localized: "Keep awake after conditions end for", comment: "Rule editor: linger"),
                    seconds: $draft.lingerSeconds, options: Self.lingerOptions)
                Toggle("On the power adapter, prevent all sleep", isOn: $draft.preventSleepOnPower)
            } header: {
                Text("Keep awake").accessibilityAddTraits(.isHeader)
            } footer: {
                Text(GeneralSettingsView.onPowerHelp)
            }
            Section {
                Toggle("Only during certain hours", isOn: activeHoursOn)
                if draft.activeHours != nil {
                    WeeklyWindowEditor(window: activeHours)
                }
            }
            if isExisting {
                Section {
                    Button("Delete Rule…", role: .destructive) { confirmingDelete = true }
                        .accessibilityLabel(Text("Delete rule \(draft.name)"))
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text("Delete the rule “\(draft.name)”?"), isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Rule", role: .destructive, action: delete)
        } message: {
            Text("This can't be undone.")
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(ConditionKind.allCases, id: \.self) { kind in
                Button {
                    draft.conditions.append(kind.blank)
                } label: {
                    Label(kind.title, systemImage: kind.symbol)
                }
            }
        } label: {
            Label("Add Condition", systemImage: "plus")
        }
        .fixedSize()
    }

    /// Safe against the row being removed while SwiftUI still holds its binding.
    private func condition(at index: Int) -> Binding<Condition> {
        Binding(
            get: { draft.conditions.indices.contains(index) ? draft.conditions[index] : .powerAdapter },
            set: { if draft.conditions.indices.contains(index) { draft.conditions[index] = $0 } })
    }

    private func mode(_ mode: AwakeMode) -> Binding<Bool> {
        Binding(
            get: { draft.modes.contains(mode) },
            set: { on in
                if on { draft.modes.insert(mode) } else { draft.modes.remove(mode) }
            })
    }

    private var activeHoursOn: Binding<Bool> {
        Binding(get: { draft.activeHours != nil }, set: { draft.activeHours = $0 ? .workHours : nil })
    }

    private var activeHours: Binding<WeeklyWindow> {
        Binding(get: { draft.activeHours ?? .workHours }, set: { draft.activeHours = $0 })
    }
}

// MARK: - Test tab

private struct RuleTestTab: View {
    let model: RulesModel
    let draft: Rule

    var body: some View {
        // Settle times and schedules change without a signal, so refresh every second.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Form {
                Section {
                    if draft.conditions.isEmpty {
                        Text("This rule has no conditions yet. Add one on the Edit tab.")
                            .foregroundStyle(Color.secondaryText)
                    } else {
                        let readings = model.engine.readings(for: draft)
                        ForEach(Array(zip(draft.conditions, readings).enumerated()), id: \.offset) { _, pair in
                            ConditionTestRow(condition: pair.0, reading: pair.1)
                        }
                    }
                } header: {
                    Text("Conditions now").accessibilityAddTraits(.isHeader)
                }
                if !draft.conditions.isEmpty {
                    Section {
                        StatusChipView(chip: overall(now: context.date).chip)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func overall(now: Date) -> RuleStatusPill {
        if model.engine.pause != nil {
            return RuleStatusPill(
                text: String(localized: "Rules are paused", comment: "Test view: overall"), symbol: "pause.fill",
                tone: .neutral)
        }
        if let hours = draft.activeHours, !hours.contains(now, calendar: .autoupdatingCurrent) {
            return RuleStatusPill(
                text: String(localized: "Outside active hours", comment: "Test view: overall"), symbol: "clock",
                tone: .neutral)
        }
        return model.engine.conditionsMatch(draft)
            ? RuleStatusPill(
                text: String(localized: "This rule would be matching now", comment: "Test view: overall"),
                symbol: "checkmark.circle.fill", tone: .good)
            : RuleStatusPill(
                text: String(localized: "This rule would not be matching now", comment: "Test view: overall"),
                symbol: "circle", tone: .neutral)
    }
}

private struct ConditionTestRow: View {
    let condition: Condition
    let reading: ConditionReading

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: condition.kind.symbol, tint: SessionSource.rule.tint, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: condition.isComplete ? condition.summary : condition.kind.title)
                Text(verbatim: reading.text(for: condition))
                    .font(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .monospacedDigit()
                if case .level(let current?, let threshold) = reading.value, threshold > 0 {
                    ThinProgressBar(value: min(current / threshold, 1), tint: mark.tone.color)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
            StatusChipView(chip: mark.chip)
        }
        .accessibilityElement(children: .combine)
    }

    private var mark: RuleStatusPill {
        switch reading.state {
        case .met:
            RuleStatusPill(
                text: String(localized: "Met", comment: "Test view: condition state"), symbol: "checkmark.circle.fill",
                tone: .good)
        case .notMet:
            RuleStatusPill(
                text: String(localized: "Not met", comment: "Test view: condition state"), symbol: "circle",
                tone: .neutral)
        case .unavailable:
            RuleStatusPill(
                text: String(localized: "Needs access", comment: "Test view: condition state"),
                symbol: "exclamationmark.triangle.fill", tone: .caution)
        }
    }
}
