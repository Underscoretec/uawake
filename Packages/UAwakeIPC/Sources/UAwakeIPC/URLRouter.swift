import Foundation
import UAwakeCore
import os

/// Carries out `uawake://` URLs on the engine. Invalid URLs, and starts the engine
/// refuses, change nothing and log a warning.
@MainActor
public enum URLRouter {
    private static let logger = Logger(subsystem: "com.underscoretec.uawake", category: "ipc")

    /// - Parameter defaultCondition: the primary-click preset, used by `uawake://toggle`.
    /// - Returns: `false` if the URL was rejected or the engine refused it.
    @discardableResult
    public static func route(_ url: URL, to engine: any SessionEngine, defaultCondition: EndCondition) -> Bool {
        let command: URLCommand
        do {
            command = try URLCommand(url: url)
        } catch {
            logger.warning(
                "Ignored invalid URL \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return false
        }
        do throws(SessionEngineError) {
            switch command {
            case .activate(let options):
                try engine.start(options.request)
            case .deactivate:
                engine.stopAll(source: .manual, cause: .stoppedByUser)
                engine.stopAll(source: .url, cause: .stoppedByUser)
            case .toggle:
                try engine.toggle(
                    SessionRequest(
                        source: .url, reason: .standard(.url, defaultCondition), endCondition: defaultCondition))
            }
            return true
        } catch {
            logger.warning(
                "Engine refused \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}

extension ActivateOptions {
    /// The URL session this asks for.
    public var request: SessionRequest {
        SessionRequest(
            source: .url,
            reason: reason.map(SessionReason.custom) ?? .standard(.url, endCondition),
            modes: keepsDisplayAwake ? [.system, .display] : [.system],
            endCondition: endCondition
        )
    }
}
