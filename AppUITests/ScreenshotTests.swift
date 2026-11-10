import XCTest

/// Captures the design screenshots in docs/design/screenshots/ (`make screenshots`).
/// Uses a fixed power state so the status strip is the same on every Mac.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = await XCUIApplication()
    }

    override func tearDown() async throws {
        await app.terminate()
    }

    @MainActor func testLight() throws { try capture("light") }
    @MainActor func testDark() throws { try capture("dark") }

    @MainActor
    private func capture(_ mode: String) throws {
        let base = ["-UITesting", "-UITestAppearance", mode, "-UITestBackdrop", mode, "-UITestDeviceState", "battery"]

        // Popover: idle and one timed session; the menu bar pill.
        launch(base + ["-UITestCountdown", "-UITestMenuBarPreview"])
        let popover = app.windows["Popover"]
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        shoot(popover, "popover-idle-\(mode)")
        popover.buttons["Keep awake: 1 hr"].click()
        XCTAssertTrue(popover.text("Started manually at").waitForExistence(timeout: 3))
        shoot(popover, "popover-one-session-\(mode)")
        shoot(app.windows["MenuBarPreview"], "menubar-pill-\(mode)")
        app.terminate()

        // Popover: a URL session plus a manual one.
        launch(base + ["-UITestOpenURL", "uawake://activate?duration=45m&reason=Render"])
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        popover.buttons["Keep awake: 2 hrs"].click()
        XCTAssertTrue(popover.text("Sessions").waitForExistence(timeout: 3))
        shoot(popover, "popover-two-sessions-\(mode)")
        app.terminate()

        // Popover: refusal banner.
        launch(["-UITesting", "-UITestAppearance", mode, "-UITestBackdrop", mode, "-UITestDeviceState", "lowPower"])
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        popover.labeled("Keep awake").click()
        XCTAssertTrue(popover.text("Low Power Mode is on.").waitForExistence(timeout: 3))
        shoot(popover, "popover-refusal-\(mode)")
        app.terminate()

        // The real NSPopover's own chrome, for comparison with the stand-in.
        launch(base + ["-UITestRealPopover"])
        let real = app.popovers.firstMatch
        XCTAssertTrue(real.waitForExistence(timeout: 10))
        shoot(real, "popover-real-chrome-\(mode)")
        app.terminate()

        // Main window: every section, with a session running on Overview.
        launch(base + ["-UITestMainWindow"])
        let window = app.windows["Main"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["Keep awake: 2 hrs"].click()
        XCTAssertTrue(window.text("Started manually at").waitForExistence(timeout: 2))
        shoot(window, "main-overview-\(mode)")
        for section in ["Durations", "Safety", "Appearance", "General", "Updates", "About"] {
            window.text(section).click()
            sleep(1)
            shoot(window, "main-\(section.lowercased())-\(mode)")
        }
        app.terminate()

        // Rules (fixture rules with scripted signals): the list, the editor, the Test view,
        // and the popover with rule sessions and the Rules strip.
        let rules = base + ["-UITestRules"]
        launch(rules + ["-UITestMainWindow", "-UITestRulesSection"])
        XCTAssertTrue(window.text("Matching now").waitForExistence(timeout: 10))
        window.text("Rules").click()  // Brings the app and its window in front of the backdrop.
        shoot(window, "main-rules-\(mode)")
        app.terminate()
        for (tab, name) in [("edit", "rule-editor"), ("test", "rule-test")] {
            launch(rules + ["-UITestMainWindow", "-UITestRulesSection", "-UITestRuleEditor", tab])
            let editor = app.descendants(matching: .any)["RuleEditor"].firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            // Activates the app with a click on the sheet's empty bottom-left corner.
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.98)).click()
            shoot(window, "\(name)-\(mode)")
            app.terminate()
        }
        launch(rules)
        XCTAssertTrue(popover.text("rules matching").waitForExistence(timeout: 10))
        shoot(popover, "popover-rules-\(mode)")
    }

    @MainActor
    private func launch(_ arguments: [String]) {
        sleep(2)  // Let the previous instance's windows finish closing.
        app.launchArguments = arguments
        app.launch()
    }

    @MainActor
    private func shoot(_ element: XCUIElement, _ name: String) {
        sleep(1)  // Let size changes and transitions settle.
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
