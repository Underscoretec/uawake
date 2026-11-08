import SwiftUI
import os

// Developer tool, never shipped: strings are `verbatim` and stay out of the String Catalog.

enum ProbeResult: String, Codable, Sendable {
    case notRun = "Not run"
    case works = "Works"
    case worksWithPermission = "Works with permission"
    case limited = "Limited"
    case blocked = "Blocked"
}

struct ProbeOutcome: Codable, Sendable {
    var value: String
    var result: ProbeResult
    var events: [String] = []
}

/// Holds outcomes, logs every result and event to the unified log
/// (subsystem `com.underscoretec.uawake.probe`) and to `Documents/probe-results.json`
/// in the app container.
@MainActor
@Observable
final class ProbeModel {
    static let shared = ProbeModel()

    var outcomes: [String: ProbeOutcome] = [:]
    var running: Set<String> = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.underscoretec.uawake.probe", category: "probe")

    func run(_ probe: Probe, interactive: Bool) async {
        running.insert(probe.id)
        var outcome = await probe.run(interactive)
        outcome.events = outcomes[probe.id]?.events ?? []
        outcomes[probe.id] = outcome
        running.remove(probe.id)
        logger.notice(
            "RESULT \(probe.id, privacy: .public) | \(outcome.result.rawValue, privacy: .public) | \(outcome.value, privacy: .public)"
        )
        save()
    }

    func runAll(interactive: Bool) async {
        for probe in Probe.all { await run(probe, interactive: interactive) }
        logger.notice("RUN-ALL DONE")
    }

    func event(_ id: String, _ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        outcomes[id, default: ProbeOutcome(value: "", result: .notRun)].events.append("\(stamp) \(text)")
        logger.notice("EVENT \(id, privacy: .public) | \(text, privacy: .public)")
        save()
    }

    private func save() {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(outcomes).write(to: directory.appending(path: "probe-results.json"))
    }
}

@main
struct SandboxProbeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// `--run-all` runs every probe without permission prompts and keeps listening;
/// `--cleanup` unregisters the probe's launch agent and quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if arguments.contains("--cleanup") {
            Task {
                await Probes.cleanup()
                NSApplication.shared.terminate(nil)
            }
        } else if arguments.contains("--run-all") {
            Task { await ProbeModel.shared.runAll(interactive: false) }
        }
    }
}

struct ContentView: View {
    private let model = ProbeModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)").font(.headline)
                Spacer()
                Button {
                    Task { await model.runAll(interactive: false) }
                } label: {
                    Text(verbatim: "Run all (no prompts)")
                }
            }
            List(Probe.all) { probe in
                ProbeRow(probe: probe, outcome: model.outcomes[probe.id], isRunning: model.running.contains(probe.id)) {
                    Task { await model.run(probe, interactive: true) }
                }
            }
        }
        .padding()
        .frame(minWidth: 860, minHeight: 680)
    }
}

struct ProbeRow: View {
    let probe: Probe
    let outcome: ProbeOutcome?
    let isRunning: Bool
    let run: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(probe.title)  [\(probe.release)]").bold()
                Text(verbatim: outcome?.value ?? "—").font(.caption.monospaced()).textSelection(.enabled)
                ForEach(Array((outcome?.events ?? []).suffix(4).enumerated()), id: \.offset) { _, event in
                    Text(verbatim: event).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(verbatim: (outcome?.result ?? .notRun).rawValue).foregroundStyle(color)
            Button(action: run) { Text(verbatim: "Run") }.disabled(isRunning)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch outcome?.result ?? .notRun {
        case .works, .worksWithPermission: .green
        case .limited: .orange
        case .blocked: .red
        case .notRun: .secondary
        }
    }
}
