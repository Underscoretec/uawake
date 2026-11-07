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
        fatalError("Not implemented until Phase B")
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
