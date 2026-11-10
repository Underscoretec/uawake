import Foundation
import Testing

@testable import UAwakeCore

struct RuleModelTests {
    static let nineToSeven = WeeklyWindow(
        days: Weekday.workdays, start: ClockTime(hour: 9, minute: 0)!, end: ClockTime(hour: 19, minute: 0)!)

    static let everyCondition: [Condition] = [
        .appRunning(AppRef(bundleID: "com.apple.dt.Xcode", name: "Xcode")),
        .appFrontmost(AppRef(bundleID: "com.apple.iWork.Keynote", name: "Keynote")),
        .call(camera: true, microphone: false),
        .audioPlaying,
        .cpuBusy(percent: 50, windowSeconds: 60),
        .networkBusy(bytesPerSecond: 1_000_000, direction: .upload, windowSeconds: 120),
        .powerAdapter,
        .externalDisplay(name: nil),
        .externalDisplay(name: "Studio Display"),
        .device(kind: .usb, id: "05ac:8104", name: "Dock"),
        .device(kind: .bluetooth, id: "a4-83-e7-12-34-56", name: "Headset"),
        .wifi(ssid: "Office"),
        .calendarEvent(calendarID: "abc", calendarName: "Work", keyword: "review"),
        .calendarEvent(calendarID: nil, calendarName: nil, keyword: nil),
        .schedule(nineToSeven),
    ]

    func temporaryStore() -> RuleStore {
        RuleStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("uawake-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("rules.json"))
    }

    func write(_ json: String, to store: RuleStore) throws {
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.url)
    }

    // MARK: Rule and condition coding

    @Test func everyConditionTypeRoundTrips() throws {
        #expect(Set(Self.everyCondition.map(\.kind)) == Set(ConditionKind.allCases))
        let rule = Rule(
            name: "Everything", match: .any, conditions: Self.everyCondition, modes: [.display, .disk],
            lingerSeconds: 300, activeHours: Self.nineToSeven)
        let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        #expect(decoded == rule)
        #expect(decoded.modes == [.system, .display, .disk])
    }

    @Test func missingFieldsTakeDefaultsAndValuesAreClamped() throws {
        let json = """
            { "id": "\(UUID().uuidString)", "name": "  Busy  ", "lingerSeconds": 99999,
              "conditions": [ { "type": "cpuBusy", "percent": 3, "windowSeconds": 5 },
                              { "type": "networkBusy", "bytesPerSecond": 1 },
                              { "type": "call" },
                              { "type": "externalDisplay", "name": "" } ] }
            """
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        #expect(rule.name == "Busy")
        #expect(rule.enabled)
        #expect(rule.match == .all)
        #expect(rule.modes == [.system])
        #expect(rule.lingerSeconds == 3600)
        #expect(rule.activeHours == nil)
        #expect(
            rule.conditions == [
                .cpuBusy(percent: 10, windowSeconds: 30),
                .networkBusy(bytesPerSecond: 10_000, direction: .download, windowSeconds: 60),
                .call(camera: true, microphone: true),
                .externalDisplay(name: nil),
            ])
    }

    @Test func invalidRulesDoNotDecode() {
        let id = UUID().uuidString
        for json in [
            #"{ "id": "\#(id)", "name": "", "conditions": [ { "type": "audioPlaying" } ] }"#,
            #"{ "id": "\#(id)", "name": "Empty", "conditions": [] }"#,
            #"{ "id": "\#(id)", "name": "Future", "conditions": [ { "type": "focusMode" } ] }"#,
            #"{ "id": "\#(id)", "name": "No app", "conditions": [ { "type": "appRunning", "bundleID": "" } ] }"#,
            #"{ "id": "\#(id)", "name": "Bad time", "conditions": [ { "type": "schedule", "window": { "days": ["mon"], "start": "25:00", "end": "10:00" } } ] }"#,
        ] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(Rule.self, from: Data(json.utf8)) }
        }
    }

    @Test func longNamesAndTooManyConditionsAreTrimmed() {
        let rule = Rule(
            name: String(repeating: "x", count: 200), conditions: Array(repeating: .audioPlaying, count: 40))
        #expect(rule.name.count == 64)
        #expect(rule.conditions.count == 16)
    }

    @Test func conditionsKnowTheirSignalAndPermission() {
        #expect(Condition.wifi(ssid: "x").permission == .location)
        #expect(Condition.calendarEvent(calendarID: nil, calendarName: nil, keyword: nil).permission == .calendar)
        #expect(Condition.device(kind: .bluetooth, id: "a", name: "a").permission == .bluetooth)
        #expect(Condition.device(kind: .usb, id: "a", name: "a").permission == nil)
        #expect(Condition.device(kind: .usb, id: "a", name: "a").signal == .usbDevices)
        #expect(Condition.schedule(Self.nineToSeven).signal == nil)
        #expect(!Condition.call(camera: false, microphone: false).isComplete)
    }

    // MARK: Weekly window

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// Day 0 is Monday 1 January 2001.
    func date(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(day * 86_400 + hour * 3600 + minute * 60))
    }

    @Test func daytimeWindow() {
        let window = Self.nineToSeven
        #expect(!window.contains(date(day: 0, 8, 59), calendar: Self.utc))
        #expect(window.contains(date(day: 0, 9), calendar: Self.utc))
        #expect(window.contains(date(day: 4, 18, 59), calendar: Self.utc))
        #expect(!window.contains(date(day: 4, 19), calendar: Self.utc))
        #expect(!window.contains(date(day: 5, 12), calendar: Self.utc), "Saturday")
        #expect(window.nextBoundary(after: date(day: 0, 8), calendar: Self.utc) == date(day: 0, 9))
        #expect(window.nextBoundary(after: date(day: 0, 9), calendar: Self.utc) == date(day: 0, 19))
        #expect(window.nextBoundary(after: date(day: 0, 19), calendar: Self.utc) == date(day: 1, 0))
    }

    @Test func overnightWindowBelongsToTheDayItStartsOn() {
        // Friday 22:00 to Saturday 02:00.
        let window = WeeklyWindow(
            days: [.fri], start: ClockTime(hour: 22, minute: 0)!, end: ClockTime(hour: 2, minute: 0)!)
        #expect(!window.contains(date(day: 4, 21, 59), calendar: Self.utc))
        #expect(window.contains(date(day: 4, 22), calendar: Self.utc))
        #expect(window.contains(date(day: 5, 1, 59), calendar: Self.utc))
        #expect(!window.contains(date(day: 5, 2), calendar: Self.utc))
        #expect(!window.contains(date(day: 4, 1), calendar: Self.utc), "Friday 01:00 belongs to Thursday's window")
        #expect(!window.contains(date(day: 5, 23), calendar: Self.utc), "Saturday night is not a Friday start")
        // Sunday night into Monday wraps the week.
        let sunday = WeeklyWindow(
            days: [.sun], start: ClockTime(hour: 23, minute: 0)!, end: ClockTime(hour: 1, minute: 0)!)
        #expect(sunday.contains(date(day: 7, 0, 30), calendar: Self.utc))
    }

    @Test func equalStartAndEndIsTheWholeDay() {
        let window = WeeklyWindow(
            days: [.tue], start: ClockTime(hour: 9, minute: 0)!, end: ClockTime(hour: 9, minute: 0)!)
        #expect(!window.contains(date(day: 0, 23, 59), calendar: Self.utc))
        #expect(window.contains(date(day: 1, 0), calendar: Self.utc))
        #expect(window.contains(date(day: 1, 23, 59), calendar: Self.utc))
        #expect(!window.contains(date(day: 2, 0), calendar: Self.utc))
    }

    @Test func windowsFollowLocalTimeAcrossADaylightSavingChange() throws {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let window = WeeklyWindow(
            days: Set(Weekday.allCases), start: ClockTime(hour: 9, minute: 0)!, end: ClockTime(hour: 17, minute: 0)!)
        // Clocks go forward on Sunday 25 March 2001: 09:00 local is 08:00 UTC that day.
        let saturdayNoon = try #require(london.date(from: DateComponents(year: 2001, month: 3, day: 24, hour: 18)))
        let sundayNine = try #require(london.date(from: DateComponents(year: 2001, month: 3, day: 25, hour: 9)))
        let midnight = try #require(window.nextBoundary(after: saturdayNoon, calendar: london))
        #expect(window.nextBoundary(after: midnight, calendar: london) == sundayNine)
        #expect(sundayNine.timeIntervalSince(saturdayNoon) == 14 * 3600)
        #expect(window.contains(sundayNine, calendar: london))
        #expect(!window.contains(sundayNine - 1, calendar: london))
    }

    @Test func clockTimeText() {
        #expect(ClockTime(text: "09:05") == ClockTime(hour: 9, minute: 5))
        #expect(ClockTime(hour: 9, minute: 5)?.text == "09:05")
        #expect(ClockTime(text: "24:00") == nil)
        #expect(ClockTime(text: "9") == nil)
    }

    // MARK: Store

    @Test func aMissingFileMeansNoRules() {
        let loaded = temporaryStore().load()
        #expect(loaded.document == RuleDocument())
        #expect(loaded.problem == nil)
    }

    @Test func rulesSurviveASaveAndLoad() throws {
        let store = temporaryStore()
        let document = RuleDocument(rules: [
            Rule(name: "A", conditions: Self.everyCondition, activeHours: Self.nineToSeven),
            Rule(name: "B", enabled: false, match: .any, conditions: [.audioPlaying], lingerSeconds: 0),
        ])
        try store.save(document)
        let loaded = store.load()
        #expect(loaded.document == document)
        #expect(loaded.problem == nil)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains(#""version" : 1"#))
    }

    @Test func rulesThisBuildCannotReadAreKeptAndWrittenBack() throws {
        let store = temporaryStore()
        let good = UUID().uuidString
        try write(
            """
            { "version": 1, "rules": [
              { "id": "\(good)", "name": "Good", "conditions": [ { "type": "audioPlaying" } ] },
              { "id": "\(UUID().uuidString)", "name": "Future", "conditions": [ { "type": "focusMode", "mode": "Work" } ] },
              { "id": "\(good)", "name": "Duplicate id", "conditions": [ { "type": "powerAdapter" } ] }
            ] }
            """, to: store)
        var loaded = store.load()
        #expect(loaded.problem == nil)
        #expect(loaded.document.rules.map(\.name) == ["Good"])
        #expect(loaded.document.unsupported.count == 2)

        loaded.document.rules[0].name = "Renamed"
        try store.save(loaded.document)
        let again = store.load()
        #expect(again.document.rules.map(\.name) == ["Renamed"])
        #expect(again.document.unsupported == loaded.document.unsupported)
        #expect(try String(contentsOf: store.url, encoding: .utf8).contains("focusMode"))
    }

    @Test func aFileFromANewerVersionIsLeftUntouched() throws {
        let store = temporaryStore()
        let json = #"{ "version": 2, "rules": [ { "anything": true } ] }"#
        try write(json, to: store)
        let loaded = store.load()
        #expect(loaded.problem == .newerVersion(2))
        #expect(loaded.document == RuleDocument())
        #expect(try String(contentsOf: store.url, encoding: .utf8) == json)
    }

    @Test func aCorruptFileIsMovedAsideNotDeleted() throws {
        for json in ["{ not json", #"{ "rules": [] }"#, "[1, 2, 3]"] {
            let store = temporaryStore()
            try write(json, to: store)
            let loaded = store.load(now: Date(timeIntervalSince1970: 1000))
            let aside = store.url.deletingLastPathComponent().appendingPathComponent("rules.corrupt-1000.json")
            #expect(loaded.problem == .corrupt(movedTo: aside.path))
            #expect(loaded.document == RuleDocument())
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
            #expect(try String(contentsOf: aside, encoding: .utf8) == json)
        }
    }

    @Test func atMostAHundredRulesAreLoaded() throws {
        let store = temporaryStore()
        try store.save(RuleDocument(rules: (0..<105).map { Rule(name: "Rule \($0)", conditions: [.audioPlaying]) }))
        let loaded = store.load()
        #expect(loaded.document.rules.count == 100)
        #expect(loaded.document.unsupported.count == 5)
    }
}
