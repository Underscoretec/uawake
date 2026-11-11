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

extension EndCondition {
    /// Short preset label: "15 min", "1 hr, 30 min", "Indefinite".
    var chipTitle: String {
        switch self {
        case .indefinite:
            String(localized: "Indefinite", comment: "Preset chip: no end time")
        case .duration(let duration):
            duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        case .until, .batteryLevel:
            localizedDescription
        }
    }
}

extension IconStyle {
    var localizedName: String {
        switch self {
        case .uawake: String(localized: "uawake", comment: "Menu bar icon style: the app's own cup")
        case .cup: String(localized: "Cup", comment: "Menu bar icon style")
        case .eye: String(localized: "Eye", comment: "Menu bar icon style")
        case .bolt: String(localized: "Bolt", comment: "Menu bar icon style")
        }
    }
}

extension PresetError {
    var localizedMessage: String {
        switch self {
        case .duplicate: String(localized: "That preset already exists.", comment: "Durations settings error")
        case .tooMany: String(localized: "You can have up to 12 presets.", comment: "Durations settings error")
        case .unsupported, .indexOutOfRange:
            String(localized: "That preset can't be used.", comment: "Durations settings error")
        }
    }
}

extension EndCause {
    /// The guard's name and what happened, for notifications and banners;
    /// `nil` for causes that are not guards.
    func guardText(settings: UAwakeSettings) -> (title: String, detail: String)? {
        switch self {
        case .batteryGuard:
            (
                String(localized: "Battery guard", comment: "Notification title"),
                String(
                    localized: "The battery reached the \(settings.batteryGuardThreshold)% limit.",
                    comment: "Notification detail")
            )
        case .lowPowerMode:
            (
                String(localized: "Low Power Mode", comment: "Notification title"),
                String(localized: "Low Power Mode turned on.", comment: "Notification detail")
            )
        case .thermalGuard:
            (
                String(localized: "Thermal guard", comment: "Notification title"),
                String(localized: "Your Mac got too warm.", comment: "Notification detail")
            )
        case .maximumCap:
            (
                String(localized: "Maximum duration", comment: "Notification title"),
                String(
                    localized: "It reached the \(settings.maximumCapHours)-hour limit.", comment: "Notification detail")
            )
        case .expired, .stoppedByUser, .appQuit:
            nil
        }
    }
}

extension SessionSource {
    /// Icon tile for session rows. Rules and the rest arrive with their releases.
    var symbol: String {
        switch self {
        case .manual: "hand.tap.fill"
        case .url: "link"
        case .rule: "wand.and.stars"
        case .cli: "terminal.fill"
        case .shortcut: "square.stack.3d.up.fill"
        case .mdm: "building.2.fill"
        }
    }
}

extension MainSection {
    var title: String {
        switch self {
        case .overview: String(localized: "Overview", comment: "Main window section")
        case .rules: String(localized: "Rules", comment: "Main window section")
        case .durations: String(localized: "Durations", comment: "Main window section")
        case .safety: String(localized: "Safety", comment: "Main window section")
        case .appearance: String(localized: "Appearance", comment: "Main window section")
        case .general: String(localized: "General", comment: "Main window section")
        case .updates: String(localized: "Updates", comment: "Main window section")
        case .about: String(localized: "About", comment: "Main window section")
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            String(localized: "What keeps your Mac awake right now.", comment: "Main window section subtitle")
        case .rules:
            String(localized: "Keep your Mac awake automatically.", comment: "Main window section subtitle")
        case .durations:
            String(localized: "The presets in the menu bar popover.", comment: "Main window section subtitle")
        case .safety:
            String(
                localized: "When uawake stops by itself to protect your Mac.", comment: "Main window section subtitle")
        case .appearance:
            String(localized: "How uawake looks in the menu bar.", comment: "Main window section subtitle")
        case .general:
            String(
                localized: "Startup, the menu bar click and the global shortcut.",
                comment: "Main window section subtitle")
        case .updates: String(localized: "How uawake keeps itself up to date.", comment: "Main window section subtitle")
        case .about: String(localized: "Version and credits.", comment: "Main window section subtitle")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .rules: "wand.and.stars"
        case .durations: "timer"
        case .safety: "shield.lefthalf.filled"
        case .appearance: "paintbrush"
        case .general: "gearshape"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }
}

extension Session {
    /// Row and hero title: the caller's reason, or what the session runs for.
    var title: String {
        switch reason {
        case .custom(let text): text
        case .rule(let name): name
        case .standard(_, let condition): condition.sessionTitle
        }
    }
}

extension EndCondition {
    /// "1 hour", "Indefinite", "Until 18:30", "Until battery 20%".
    var sessionTitle: String {
        switch self {
        case .duration(let duration):
            duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        case .indefinite:
            String(localized: "Indefinite", comment: "Preset chip: no end time")
        case .until(let time):
            String(localized: "Until \(time.formatted)", comment: "Session title; the argument is a time of day")
        case .batteryLevel(let level):
            String(
                localized: "Until battery \((Double(level) / 100).formatted(.percent))",
                comment: "Session title; the argument is a battery percentage")
        }
    }
}

extension SessionSource {
    func startedText(at time: String) -> String {
        switch self {
        case .manual: String(localized: "Started manually at \(time)", comment: "Session subtitle")
        case .url: String(localized: "Started from a link at \(time)", comment: "Session subtitle")
        case .rule: String(localized: "Started by a rule at \(time)", comment: "Session subtitle")
        case .cli: String(localized: "Started from the command line at \(time)", comment: "Session subtitle")
        case .shortcut: String(localized: "Started from Shortcuts at \(time)", comment: "Session subtitle")
        case .mdm: String(localized: "Started by your organisation at \(time)", comment: "Session subtitle")
        }
    }
}
