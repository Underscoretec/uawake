import Foundation
import UAwakeCore

/// A parsed `uawake://` URL. Parsing is pure and never touches the engine, so an
/// invalid URL can be rejected (and logged) before anything changes.
///
/// | URL | Command |
/// | --- | --- |
/// | `uawake://activate` | `.activate(ActivateOptions())` — indefinite |
/// | `uawake://activate?duration=1h30m` | `.duration(.seconds(5400))`; `h`/`m`/`s` parts, descending, each at most once |
/// | `uawake://activate?until=18:30` | `.until(ClockTime(18, 30))`, 24-hour `HH:mm` |
/// | `uawake://activate?display=1&reason=Render` | display mode on, custom reason |
/// | `uawake://deactivate` | `.deactivate` — ends all manual and URL sessions |
/// | `uawake://toggle` | `.toggle` — ``SessionEngine/toggle(_:)`` with the default session |
public enum URLCommand: Equatable, Sendable {
    case activate(ActivateOptions)
    case deactivate
    case toggle

    /// Parses a `uawake://` URL.
    /// - Throws: ``URLCommandError`` for any URL outside the table above,
    ///   including `duration` and `until` together, repeated or unknown query keys,
    ///   a zero duration, units out of order or repeated (`30m1h`, `1h1h`), and
    ///   malformed values.
    public init(url: URL) throws(URLCommandError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "uawake"
        else { throw .wrongScheme }
        let command = components.host?.lowercased() ?? ""
        guard components.path.isEmpty || components.path == "/" else {
            throw .unknownCommand(command + components.path)
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil else { throw .conflictingParameters }
            query[item.name] = item.value ?? ""
        }

        switch command {
        case "deactivate", "toggle":
            if let key = query.keys.sorted().first { throw .unknownParameter(key) }
            self = command == "toggle" ? .toggle : .deactivate
        case "activate":
            self = .activate(try Self.activateOptions(query))
        default:
            throw .unknownCommand(command)
        }
    }

    private static func activateOptions(_ query: [String: String]) throws(URLCommandError) -> ActivateOptions {
        if let key = query.keys.sorted().first(where: { !["duration", "until", "display", "reason"].contains($0) }) {
            throw .unknownParameter(key)
        }
        var options = ActivateOptions()
        switch (query["duration"], query["until"]) {
        case (.some, .some):
            throw .conflictingParameters
        case (let value?, nil):
            guard let seconds = parseDuration(value) else { throw .invalidValue(parameter: "duration", value: value) }
            options.endCondition = .duration(.seconds(seconds))
        case (nil, let value?):
            guard let time = parseClockTime(value) else { throw .invalidValue(parameter: "until", value: value) }
            options.endCondition = .until(time)
        case (nil, nil):
            break
        }
        if let value = query["display"] {
            switch value.lowercased() {
            case "1", "true": options.keepsDisplayAwake = true
            case "0", "false": options.keepsDisplayAwake = false
            default: throw .invalidValue(parameter: "display", value: value)
            }
        }
        if let value = query["reason"] {
            let reason = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...128).contains(reason.count), !reason.contains(where: \.isNewline) else {
                throw .invalidValue(parameter: "reason", value: value)
            }
            options.reason = reason
        }
        return options
    }

    /// `1h30m`, `90m`, `45s`: h/m/s parts in that order, each at most once,
    /// up to six digits each, total above zero.
    static func parseDuration(_ value: String) -> Int? {
        guard let match = value.wholeMatch(of: /(?:(\d{1,6})h)?(?:(\d{1,6})m)?(?:(\d{1,6})s)?/) else { return nil }
        let parts = [match.1, match.2, match.3].map { $0.flatMap { Int($0) } ?? 0 }
        let total = parts[0] * 3600 + parts[1] * 60 + parts[2]
        return total > 0 ? total : nil
    }

    /// 24-hour `HH:mm`.
    static func parseClockTime(_ value: String) -> ClockTime? {
        guard let match = value.wholeMatch(of: /(\d{2}):(\d{2})/),
            let hour = Int(match.1), let minute = Int(match.2)
        else { return nil }
        return ClockTime(hour: hour, minute: minute)
    }
}

public struct ActivateOptions: Equatable, Sendable {
    /// `.indefinite`, `.duration` or `.until` only.
    public var endCondition: EndCondition = .indefinite
    /// `display=1` (or `true`) adds ``AwakeMode/display``.
    public var keepsDisplayAwake = false
    /// Caller-supplied reason (``SessionReason/custom(_:)``), 1–128 characters;
    /// `nil` means ``SessionReason/standard(_:_:)`` with source `.url`.
    public var reason: String?

    public init(endCondition: EndCondition = .indefinite, keepsDisplayAwake: Bool = false, reason: String? = nil) {
        self.endCondition = endCondition
        self.keepsDisplayAwake = keepsDisplayAwake
        self.reason = reason
    }
}

public enum URLCommandError: Error, Equatable, Sendable {
    case wrongScheme
    case unknownCommand(String)
    case unknownParameter(String)
    case invalidValue(parameter: String, value: String)
    case conflictingParameters
}
