import Foundation
import Testing
import UAwakeCore
import UAwakeCoreTesting
import UAwakeSystem

@testable import uawake

@MainActor
struct RulesModelTests {
    final class Permissions: PermissionProvider, @unchecked Sendable {
        var statuses: [RulePermission: PermissionStatus] = [:]
        var requested: [RulePermission] = []

        func status(_ permission: RulePermission) -> PermissionStatus { statuses[permission] ?? .notDetermined }

        func request(_ permission: RulePermission) async -> PermissionStatus {
            requested.append(permission)
            if statuses[permission] == nil { statuses[permission] = .granted }
            return status(permission)
        }
    }

    static let xcode = AppRef(bundleID: "com.apple.dt.Xcode", name: "Xcode")

    let clock = FakeClock(now: Date(timeIntervalSinceReferenceDate: 10 * 3600))
    let assertions = FakeAssertionProvider()
    let defaults: UserDefaults
    let settings: UAwakeSettings
    let engine: DefaultSessionEngine
    let store: RuleStore
    let permissions = Permissions()

    init() {
        defaults = UserDefaults(suiteName: "uawake-rules-tests-\(UUID().uuidString)")!
        settings = UAwakeSettings(defaults: defaults)
        engine = DefaultSessionEngine(
            assertions: assertions, clock: clock, guards: DefaultSessionEngine.standardGuards, policy: settings.policy)
        store = RuleStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("uawake-app-tests-\(UUID().uuidString)").appendingPathComponent("rules.json"))
    }

    func makeModel() -> RulesModel {
        RulesModel(
            sessions: engine, clock: clock, settings: settings, store: store, permissions: permissions, monitors: nil)
    }

    func rule(_ name: String, _ conditions: [Condition]) -> Rule {
        Rule(name: name, conditions: conditions)
    }

    @Test func savedRulesPersistAndRunAfterARelaunch() {
        let model = makeModel()
        model.save(rule("Building", [.appRunning(Self.xcode)]))
        #expect(store.load().document.rules.map(\.name) == ["Building"])

        let relaunched = makeModel()
        #expect(relaunched.rules.map(\.name) == ["Building"])
        relaunched.engine.update(.apps(AppsState(running: [Self.xcode.bundleID], frontmost: nil)))
        #expect(engine.sessions.map(\.reason) == [.rule(name: "Building")])
        #expect(relaunched.matchingCount == 1)
    }

    @Test func editingReplacesAndDeletingRemoves() throws {
        let model = makeModel()
        var building = rule("Building", [.appRunning(Self.xcode)])
        model.save(building)
        building.name = "Compiling"
        model.save(building)
        #expect(model.rules.map(\.name) == ["Compiling"])
        model.setEnabled(false, for: building.id)
        #expect(model.status(of: try #require(model.rules.first)) == .off)
        model.delete(building.id)
        #expect(model.rules.isEmpty)
        #expect(store.load().document.rules.isEmpty)
    }

    @Test func invalidRulesAreNotSaved() {
        let model = makeModel()
        model.save(Rule(name: "No conditions", conditions: []))
        model.save(Rule(name: "   ", conditions: [.audioPlaying]))
        #expect(model.rules.isEmpty)
    }

    @Test func namesStayUnique() {
        let model = makeModel()
        let first = rule("Building", [.audioPlaying])
        model.save(first)
        model.save(rule("Building 2", [.audioPlaying]))
        #expect(model.uniqueName("Building") == "Building 3")
        #expect(model.uniqueName("Building", excluding: first.id) == "Building")
        #expect(model.uniqueName("Other") == "Other")
    }

    @Test func pauseIsStoredInSettingsAndRestored() {
        let model = makeModel()
        model.pause(.oneHour)
        #expect(settings.rulesPause == .until(clock.now + 3600))
        #expect(makeModel().engine.pause == .until(clock.now + 3600))
        model.pause(.untilResumed)
        #expect(settings.rulesPause == .indefinitely)
        model.pause(.untilTomorrow)
        guard case .until(let date) = settings.rulesPause else {
            Issue.record("expected a dated pause")
            return
        }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        #expect(parts.hour == 6 && parts.minute == 0)
        #expect(date > clock.now && date <= clock.now + 30 * 3600)
        model.resume()
        #expect(settings.rulesPause == nil)
        #expect(model.engine.pause == nil)
    }

    @Test func permissionsAreRequestedOnlyWhenAsked() async {
        let model = makeModel()
        model.save(rule("Office", [.wifi(ssid: "Office")]))
        #expect(permissions.requested.isEmpty, "adding or loading a rule never prompts")
        let office = model.rules[0]
        #expect(model.status(of: office) == .needsPermission(.location))
        await model.request(.location)
        #expect(permissions.requested == [.location])
        #expect(model.permissionStatus(.location) == .granted)
        #expect(model.status(of: office) == .idle)
    }

    @Test func aDeniedPermissionKeepsOnlyThatRuleOff() {
        permissions.statuses = [.calendar: .denied]
        let model = makeModel()
        model.save(rule("Meetings", [.calendarEvent(calendarID: nil, calendarName: nil, keyword: nil)]))
        model.save(rule("Building", [.appRunning(Self.xcode)]))
        model.engine.update(.apps(AppsState(running: [Self.xcode.bundleID], frontmost: nil)))
        #expect(model.status(of: model.rules[0]) == .needsPermission(.calendar))
        #expect(model.status(of: model.rules[1]) == .matching)
    }

    @Test func aNewerRulesFileIsNeverWrittenOver() throws {
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{ "version": 9, "rules": [] }"#
        try Data(json.utf8).write(to: store.url)
        let model = makeModel()
        #expect(model.isReadOnly)
        model.save(rule("New", [.audioPlaying]))
        #expect(model.rules.isEmpty)
        #expect(try String(contentsOf: store.url, encoding: .utf8) == json)
    }

    @Test func templatesAreValidOnceCompleted() {
        let templates = RulesModel.templates
        #expect(templates.map(\.id) == ["presenting", "call", "building", "downloading", "office"])
        for template in templates where template.id != "office" {
            #expect(template.rule.isValid && template.rule.conditions.allSatisfy(\.isComplete), "\(template.id)")
        }
        // The office template needs the user's network name before it can be saved.
        #expect(templates[4].rule.conditions.contains { !$0.isComplete })
    }

    // MARK: Popover

    @Test func popoverShowsRuleSessionsWithTheirSourceAndARulesStrip() throws {
        let model = makeModel()
        let popover = PopoverViewModel(engine: engine, settings: settings, now: clock.now)
        #expect(popover.rulesStrip(now: clock.now) == nil, "hidden with no rules")
        popover.rules = model
        #expect(popover.rulesStrip(now: clock.now) == nil)

        model.save(rule("Building", [.appRunning(Self.xcode)]))
        model.save(rule("Calls", [.call(camera: true, microphone: true)]))
        #expect(popover.rulesStrip(now: clock.now)?.text == "0 of 2 rules matching")

        model.engine.update(.apps(AppsState(running: [Self.xcode.bundleID], frontmost: nil)))
        let row = try #require(popover.rows.first)
        #expect(row.source == .rule)
        #expect(row.title == "Building")
        #expect(popover.showsSessionList, "a rule session is listed with its source tile")
        #expect(popover.singleRow == nil)
        #expect(!popover.isOn, "rule sessions are not the manual on/off state")
        #expect(popover.isAwake)
        #expect(popover.ruleSubtitle(row, now: clock.now) == "Rule · Xcode is open")
        #expect(popover.rulesStrip(now: clock.now)?.text == "1 of 2 rules matching")

        model.engine.update(.apps(AppsState(running: [], frontmost: nil)))
        #expect(popover.ruleSubtitle(row, now: clock.now) == "Rule · ends in 2:00")

        popover.pauseRules(.untilResumed)
        #expect(engine.sessions.isEmpty)
        #expect(popover.rulesStrip(now: clock.now) == .init(text: "Rules paused", isPaused: true))
        popover.resumeRules()
        #expect(popover.rulesStrip(now: clock.now)?.isPaused == false)
    }

    @Test func toggleLeavesRuleSessionsRunning() {
        let model = makeModel()
        let popover = PopoverViewModel(engine: engine, settings: settings, now: clock.now)
        popover.rules = model
        model.save(rule("Building", [.appRunning(Self.xcode)]))
        model.engine.update(.apps(AppsState(running: [Self.xcode.bundleID], frontmost: nil)))
        popover.toggle()
        #expect(Set(engine.sessions.map(\.source)) == [.rule, .manual])
        popover.toggle()
        #expect(engine.sessions.map(\.source) == [.rule])
    }

    // MARK: Text

    @Test func statusPillsPairTextWithIconAndTone() {
        let now = clock.now
        #expect(RuleStatus.matching.pill(now: now).text == "Matching now")
        #expect(RuleStatus.matching.pill(now: now).tone == .good)
        #expect(RuleStatus.lingering(until: now + 72).pill(now: now).text == "Ends in 1:12")
        #expect(RuleStatus.waiting(.thermalGuard, until: nil).pill(now: now).text == "Waiting: Mac cooling down")
        #expect(RuleStatus.waiting(.batteryGuard, until: nil).pill(now: now).text == "Waiting: battery low")
        #expect(RuleStatus.waiting(.lowPowerMode, until: nil).pill(now: now).text == "Waiting: Low Power Mode is on")
        #expect(RuleStatus.waiting(.batteryGuard, until: now + 252).pill(now: now).text == "Waiting: restarts in 4:12")
        #expect(RuleStatus.needsPermission(.location).pill(now: now).text == "Needs Location")
        #expect(RuleStatus.stoppedByUser.pill(now: now).tone == .critical)
        for status: RuleStatus in [
            .off, .paused, .idle, .outsideHours, .needsPermission(.calendar), .matching, .lingering(until: now),
            .stoppedByUser, .waiting(.thermalGuard, until: nil), .failed,
        ] {
            let pill = status.pill(now: now)
            #expect(!pill.text.isEmpty && !pill.symbol.isEmpty)
        }
    }

    @Test func summariesDescribeEveryConditionType() {
        for kind in ConditionKind.allCases {
            #expect(!kind.title.isEmpty && !kind.symbol.isEmpty)
            #expect(kind.blank.kind == kind)
            #expect(!kind.blank.summary.isEmpty)
        }
        let rule = Rule(
            name: "Presenting", match: .any,
            conditions: [
                .appFrontmost(AppRef(bundleID: "k", name: "Keynote")),
                .appFrontmost(AppRef(bundleID: "p", name: "PowerPoint")),
            ], modes: [.display])
        #expect(rule.summary == "Any of: Keynote is in front, PowerPoint is in front · Display awake")
        #expect(Condition.cpuBusy(percent: 50, windowSeconds: 60).summary == "Processor above 50% for 1 min")
        #expect(Condition.wifi(ssid: "Office").summary == "On Wi-Fi “Office”")
    }

    @Test func pauseText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = clock.now
        #expect(RulePause.indefinitely.text(now: now) == "Rules paused")
        #expect(RulePause.until(now + 60).text(now: now, calendar: calendar).hasPrefix("Rules paused until "))
        let tomorrow = RulePause.untilTomorrowMorning(from: now, calendar: calendar)
        #expect(tomorrow.text(now: now, calendar: calendar).hasPrefix("Rules paused until tomorrow, "))
        #expect(PauseChoice.untilTomorrow.title == "Until tomorrow, 6:00")
    }
}
