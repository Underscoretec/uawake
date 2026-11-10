import Foundation

/// The contents of `rules.json`: `{ "version": 1, "rules": [ … ] }`.
public struct RuleDocument: Equatable, Sendable {
    /// The schema version this build reads and writes.
    public static let currentVersion = 1
    public static let maxRules = 100

    public var rules: [Rule]
    /// Entries this build could not read (e.g. a condition type from a newer uawake).
    /// Written back unchanged so they are never lost; they never run.
    public var unsupported: [JSONValue]

    public init(rules: [Rule] = [], unsupported: [JSONValue] = []) {
        self.rules = rules
        self.unsupported = unsupported
    }
}

/// Reads and writes the rules file. A missing file means no rules (the upgrade path
/// from 0.1). Never deletes data: a file it can't parse is moved aside, and a file
/// from a newer schema version is left untouched.
public struct RuleStore: Sendable {
    public enum Problem: Equatable, Sendable {
        /// The file was written by a newer uawake. Rules stay off and the file must not be saved over.
        case newerVersion(Int)
        /// The file was not valid; it was moved to this path (or could not be moved).
        case corrupt(movedTo: String?)
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    /// `Application Support/uawake/rules.json` (inside the container when sandboxed).
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("uawake", isDirectory: true).appendingPathComponent("rules.json")
    }

    public func load(now: Date = Date()) -> (document: RuleDocument, problem: Problem?) {
        guard let data = try? Data(contentsOf: url) else { return (RuleDocument(), nil) }
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .number(let version)? = root["version"], case .array(let entries)? = root["rules"]
        else {
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("rules.corrupt-\(Int(now.timeIntervalSince1970)).json")
            let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
            return (RuleDocument(), .corrupt(movedTo: moved ? aside.path : nil))
        }
        guard Int(version) <= RuleDocument.currentVersion else { return (RuleDocument(), .newerVersion(Int(version))) }

        var document = RuleDocument()
        var seen: Set<UUID> = []
        for entry in entries {
            if document.rules.count < RuleDocument.maxRules, let entryData = try? JSONEncoder().encode(entry),
                let rule = try? JSONDecoder().decode(Rule.self, from: entryData), seen.insert(rule.id).inserted
            {
                document.rules.append(rule)
            } else {
                document.unsupported.append(entry)
            }
        }
        return (document, nil)
    }

    /// Writes atomically, creating the folder if needed.
    public func save(_ document: RuleDocument) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(document: document)).write(to: url, options: .atomic)
    }

    private struct File: Encodable {
        let document: RuleDocument

        enum CodingKeys: String, CodingKey { case version, rules }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(RuleDocument.currentVersion, forKey: .version)
            var entries = container.nestedUnkeyedContainer(forKey: .rules)
            for rule in document.rules { try entries.encode(rule) }
            for entry in document.unsupported { try entries.encode(entry) }
        }
    }
}

/// Any JSON value, used to carry rule entries this build can't interpret.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
