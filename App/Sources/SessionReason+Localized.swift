import Foundation
import UAwakeCore

/// UI rendering of structured reasons. Assertion names use the English
/// `englishDescription` from Core instead.
extension SessionReason {
    var localizedDescription: String {
        switch self {
        case .custom(let text):
            text
        case .rule(let name):
            String(localized: "Rule: \(name)", comment: "Session reason for a rule; the argument is the rule name")
        case .standard(let source, let condition):
            String(
                localized: "\(source.localizedName): \(condition.localizedDescription)",
                comment: "Session reason: source, then when it ends, e.g. Manual: 2 hours"
            )
        }
    }
}

extension SessionSource {
    var localizedName: String {
        switch self {
        case .manual: String(localized: "Manual", comment: "Session source")
        case .url: String(localized: "URL", comment: "Session source")
        case .rule: String(localized: "Rule", comment: "Session source")
        case .cli: String(localized: "CLI", comment: "Session source")
        case .shortcut: String(localized: "Shortcut", comment: "Session source")
        case .mdm: String(localized: "Managed", comment: "Session source: set by the organisation")
        }
    }
}

extension EndCondition {
    var localizedDescription: String {
        switch self {
        case .indefinite:
            String(localized: "indefinite", comment: "Session with no end time")
        case .duration(let duration):
            duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        case .until(let time):
            String(localized: "until \(time.formatted)", comment: "Session end; the argument is a time of day")
        case .batteryLevel(let level):
            String(
                localized: "until battery \((Double(level) / 100).formatted(.percent))",
                comment: "Session end; the argument is a battery percentage"
            )
        }
    }
}

extension ClockTime {
    /// Today's date at this time, formatted in the user's locale (e.g. 18:30 or 6:30 PM).
    var formatted: String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
