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
/// | `uawake://activate?display=0` | system only, whatever the display setting |
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
            guard let duration = DurationText.parse(value) else {
                throw .invalidValue(parameter: "duration", value: value)
            }
            options.endCondition = .duration(duration)
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
    /// `display=1`/`true` adds ``AwakeMode/display``, `display=0`/`false` forces system only;
    /// `nil` (no `display=`) follows the "Allow the display to sleep" setting.
    public var keepsDisplayAwake: Bool?
    /// Caller-supplied reason (``SessionReason/custom(_:)``), 1–128 characters;
    /// `nil` means ``SessionReason/standard(_:_:)`` with source `.url`.
    public var reason: String?

    public init(endCondition: EndCondition = .indefinite, keepsDisplayAwake: Bool? = nil, reason: String? = nil) {
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
