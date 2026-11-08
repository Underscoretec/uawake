/// The text form of a duration used by the URL scheme, settings and (from 1.1) the CLI:
/// `h`, `m`, `s` parts in that order, each at most once, e.g. `1h30m`, `90m`, `45s`.
public enum DurationText {
    /// Returns `nil` for zero, negatives, units out of order or repeated, more than
    /// six digits per part, and anything else.
    public static func parse(_ text: String) -> Duration? {
        guard let match = text.wholeMatch(of: /(?:(\d{1,6})h)?(?:(\d{1,6})m)?(?:(\d{1,6})s)?/) else { return nil }
        let parts = [match.1, match.2, match.3].map { $0.flatMap { Int($0) } ?? 0 }
        let total = parts[0] * 3600 + parts[1] * 60 + parts[2]
        return total > 0 ? .seconds(total) : nil
    }

    /// Canonical form: `5400 s` → `1h30m`.
    public static func format(_ duration: Duration) -> String {
        let total = Int(duration.components.seconds)
        let parts = [(total / 3600, "h"), (total % 3600 / 60, "m"), (total % 60, "s")].filter { $0.0 > 0 }
        return parts.isEmpty ? "0s" : parts.map { "\($0.0)\($0.1)" }.joined()
    }
}

extension EndCondition {
    /// `indefinite` or a ``DurationText``; `nil` for anything a preset can't hold.
    public init?(presetText: String) {
        if presetText == "indefinite" {
            self = .indefinite
        } else if let duration = DurationText.parse(presetText) {
            self = .duration(duration)
        } else {
            return nil
        }
    }

    /// The settings form of a preset; `nil` for until-time and battery-level conditions.
    public var presetText: String? {
        switch self {
        case .indefinite: "indefinite"
        case .duration(let duration): DurationText.format(duration)
        case .until, .batteryLevel: nil
        }
    }
}
