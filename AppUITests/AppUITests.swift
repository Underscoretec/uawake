import XCTest

/// Drives the real popover (kept open with `-UITesting`) and the main window. The app
/// runs with throwaway settings and no welcome window. Every test ends by terminating
/// the app, which releases its power assertions even when an assertion fails.
final class AppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = await XCUIApplication()
    }

    override func tearDown() async throws {
        await app.terminate()
    }

    @MainActor
    func testToggleStartsAndStopsTheDefaultSession() throws {
        app.launchArguments = ["-UITesting", "-UITestDeviceState", "battery"]
        app.launch()
        let popover = app.windows["Popover"]
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        XCTAssertTrue(popover.text("Your Mac can sleep normally").waitForExistence(timeout: 3))
        popover.labeled("Keep awake").click()
        XCTAssertTrue(popover.text("Started manually at").waitForExistence(timeout: 2))
        XCTAssertTrue(popover.text("Keeping your Mac awake").exists)
        XCTAssertTrue(popover.text("Change to").exists)
        XCTAssertFalse(popover.text("Sessions").exists)  // One session: shown in the hero.
        XCTAssertTrue(popover.labeled("Safety guards are on").exists)
        popover.labeled("Keep awake").click()
        XCTAssertTrue(popover.text("Your Mac can sleep normally").waitForExistence(timeout: 2))
    }

    @MainActor
    func testPresetChipExtendAndStop() throws {  // Single session: extend in the hero.
        app.launchArguments = ["-UITesting", "-UITestDeviceState", "battery"]
        app.launch()
        let popover = app.windows["Popover"]
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        popover.buttons["Keep awake: 15 min"].click()
        XCTAssertTrue(popover.text("15 minutes").waitForExistence(timeout: 2))
        let extend = popover.buttons["Extend 15 minutes by 15 minutes"]
        XCTAssertTrue(extend.exists)
        extend.click()
        XCTAssertTrue(popover.text("29:").waitForExistence(timeout: 2))
        popover.labeled("Keep awake").click()
        XCTAssertTrue(popover.text("Your Mac can sleep normally").waitForExistence(timeout: 2))
    }

    @MainActor
    func testTwoSessionsShowTheList() throws {
        app.launchArguments = [
            "-UITesting", "-UITestDeviceState", "battery", "-UITestOpenURL",
            "uawake://activate?duration=45m&reason=Render",
        ]
        app.launch()
        let popover = app.windows["Popover"]
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        popover.buttons["Keep awake: 1 hr"].click()
        XCTAssertTrue(popover.text("Sessions").waitForExistence(timeout: 2))
        XCTAssertTrue(popover.text("Started from a link at").exists)
        XCTAssertTrue(popover.buttons["Stop Render"].exists)
        popover.buttons["Stop Render"].click()
        XCTAssertFalse(popover.text("Sessions").waitForExistence(timeout: 1))
    }

    /// The real NSPopover sizes to its whole content: header to footer on screen with no
    /// scrolling, idle, with one and two sessions, the Until… picker open, and a banner.
    @MainActor
    func testRealPopoverFitsItsContent() throws {
        let base = ["-UITesting", "-UITestRealPopover", "-UITestDeviceState"]
        app.launchArguments = base + ["battery", "-UITestOpenURL", "uawake://activate?duration=45m&reason=Render"]
        app.launch()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.text("Started from a link at").waitForExistence(timeout: 10))
        assertFits(popover, "real-popover-one-session")
        popover.buttons["Keep awake: 1 hr"].click()
        XCTAssertTrue(popover.text("Sessions").waitForExistence(timeout: 3))
        assertFits(popover, "real-popover-two-sessions")
        popover.buttons["Until…"].click()
        XCTAssertTrue(popover.buttons["Keep awake until the chosen time"].waitForExistence(timeout: 3))
        assertFits(popover, "real-popover-until", also: ["Keep awake until the chosen time"])
        app.terminate()

        app.launchArguments = base + ["battery"]
        app.launch()
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        assertFits(popover, "real-popover-idle")
        app.terminate()

        app.launchArguments = base + ["lowPower"]
        app.launch()
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        popover.labeled("Keep awake").click()
        XCTAssertTrue(popover.text("Low Power Mode is on.").waitForExistence(timeout: 3))
        assertFits(popover, "real-popover-banner")
    }

    @MainActor
    private func assertFits(_ popover: XCUIElement, _ name: String, also extra: [String] = []) {
        sleep(1)  // Let the popover finish resizing.
        let attachment = XCTAttachment(screenshot: popover.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(popover.scrollViews.count, 0, "\(name): the popover scrolls")
        for label in ["Settings…", "Until…", "Battery", "Open uawake"] + extra {
            let element = popover.text(label)
            XCTAssertTrue(element.exists, "\(name): no \(label)")
            XCTAssertTrue(popover.frame.contains(element.frame), "\(name): \(label) is cut off")
        }
    }

    @MainActor
    func testRefusalBannerOpensSafety() throws {
        app.launchArguments = ["-UITesting", "-UITestDeviceState", "lowPower"]
        app.launch()
        let popover = app.windows["Popover"]
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        popover.labeled("Keep awake").click()
        XCTAssertTrue(popover.text("Low Power Mode is on.").waitForExistence(timeout: 2))
        popover.buttons["Open Safety Settings"].click()
        let window = app.windows["Main"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.text("Stop when Low Power Mode turns on").waitForExistence(timeout: 2))
    }

    @MainActor
    func testMainWindowSections() throws {
        app.launchArguments = ["-UITesting", "-UITestMainWindow", "-UITestDeviceState", "battery"]
        app.launch()
        let window = app.windows["Main"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.text("What keeps your Mac awake right now.").exists)
        window.text("General").click()
        XCTAssertTrue(window.buttons["Record a shortcut"].waitForExistence(timeout: 2))
        window.text("Safety").click()
        XCTAssertTrue(window.text("Stop when Low Power Mode turns on").waitForExistence(timeout: 2))
        window.text("About").click()
        XCTAssertTrue(window.text("Created by Abhijit Roy · Underscore Technology").waitForExistence(timeout: 2))
    }
}

extension AppUITests {
    /// The Rules section with the screenshot fixture: five rules with scripted signals.
    @MainActor
    func testRulesListShowsLiveStatusAndPauses() throws {
        app.launchArguments = [
            "-UITesting", "-UITestMainWindow", "-UITestRules", "-UITestRulesSection", "-UITestDeviceState", "battery",
        ]
        app.launch()
        let window = app.windows["Main"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.text("Presenting").waitForExistence(timeout: 3))
        XCTAssertTrue(window.text("Matching now").exists)
        XCTAssertTrue(window.text("Needs Location").exists)

        window.descendants(matching: .any)["PauseRulesMenu"].firstMatch.click()
        app.menuItems["For 1 hour"].click()
        XCTAssertTrue(window.text("Rules paused until").waitForExistence(timeout: 2))
        window.descendants(matching: .any)["ResumeRules"].firstMatch.click()
        XCTAssertTrue(window.text("Matching now").waitForExistence(timeout: 2))
    }

    @MainActor
    func testRuleEditorOpensAndCancels() throws {
        app.launchArguments = [
            "-UITesting", "-UITestMainWindow", "-UITestRules", "-UITestRulesSection", "-UITestDeviceState", "battery",
        ]
        app.launch()
        let window = app.windows["Main"]
        XCTAssertTrue(window.text("Presenting").waitForExistence(timeout: 5))
        window.descendants(matching: .any)["Rule-Presenting"].firstMatch.click()
        let editor = app.descendants(matching: .any)["RuleEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(app.text("Keynote is in front").exists)
        app.descendants(matching: .any)["RuleEditorCancel"].firstMatch.click()
        XCTAssertFalse(editor.waitForExistence(timeout: 1))
    }

    /// The popover's Rules strip and a rule session row with its own source.
    @MainActor
    func testPopoverShowsRuleSessionsAndTheRulesStrip() throws {
        app.launchArguments = ["-UITesting", "-UITestRules", "-UITestDeviceState", "battery"]
        app.launch()
        let popover = app.windows["Popover"]
        XCTAssertTrue(popover.text("2 of 5 rules matching").waitForExistence(timeout: 5))
        XCTAssertTrue(popover.text("Rule · Keynote is in front").exists)
        XCTAssertTrue(popover.labeled("Stop rule Presenting").exists)
    }
}

extension XCUIElement {
    /// Any descendant whose label or value contains `text` (SwiftUI text exposes its
    /// string as the value; combined elements join several strings).
    func text(_ text: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).element(boundBy: 0)
    }

    /// The first descendant with exactly this accessibility label. (`firstMatch` misses
    /// elements in the borderless popover stand-in, so these use `element(boundBy: 0)`.)
    func labeled(_ label: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).element(boundBy: 0)
    }
}
