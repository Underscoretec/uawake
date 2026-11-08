import AppKit
import SwiftUI
import UAwakeCore

struct PopoverView: View {
    @Bindable var model: PopoverViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .padding()
        .frame(width: 340)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: Binding(get: { model.isOn }, set: { _ in model.toggle() })) {
                    Text("Keep awake").font(.headline)
                }
                .toggleStyle(.switch)
                Spacer()
                if let countdown = model.countdown(now: now) {
                    Text(countdown)
                        .monospacedDigit()
                        .accessibilityLabel(Text("\(countdown) left", comment: "Popover: time remaining"))
                }
            }

            if let refusal = model.refusal {
                RefusalView(refusal: refusal, open: model.openRefusalSettings)
            }

            Text("Keep awake for").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(model.presets, id: \.self) { preset in
                    Button(preset.chipTitle) { model.start(preset) }
                        .accessibilityLabel(Text("Keep awake: \(preset.chipTitle)", comment: "Preset chip, VoiceOver"))
                }
            }
            HStack {
                DatePicker(selection: $model.untilTime, displayedComponents: .hourAndMinute) {
                    Text("Until")
                }
                Button("Start") { model.startUntil() }
                    .accessibilityLabel(Text("Keep awake until the chosen time"))
            }

            Divider()
            if model.rows.isEmpty {
                Text("No active sessions").foregroundStyle(.secondary)
            } else {
                ForEach(model.rows) { row in
                    SessionRowView(row: row, remaining: model.remaining(row, now: now), model: model)
                }
            }

            Divider()
            HStack {
                Button("Settings…") { model.openSettings(nil) }
                Spacer()
                Button("Quit uawake") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
    }
}

private struct RefusalView: View {
    let refusal: Refusal
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(refusal.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if refusal.settingsTab != nil {
                Button("Open Safety Settings", action: open)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SessionRowView: View {
    let row: SessionRow
    let remaining: String?
    let model: PopoverViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                HStack(spacing: 6) {
                    Text(row.sourceName)
                    if row.isPaused {
                        Text("Paused")
                    } else if let remaining {
                        Text(remaining).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if row.canExtend {
                Button("+15 min") { model.extend(row.id, by: .seconds(900)) }
                    .accessibilityLabel(Text("Extend \(row.title) by 15 minutes"))
                Button("+1 hr") { model.extend(row.id, by: .seconds(3600)) }
                    .accessibilityLabel(Text("Extend \(row.title) by 1 hour"))
            }
            Button {
                model.stop(row.id)
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Stop \(row.title)"))
        }
    }
}
