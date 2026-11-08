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
        let base = ["-UITesting", "-UITestAppearance", mode, "-UITestDeviceState", "battery"]

        // Popover: idle and one timed session; the menu bar pill.
        launch(base + ["-UITestCountdown", "-UITestMenuBarPreview"])
        let popover = app.windows["Popover"]
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        shoot(popover, "popover-idle-\(mode)")
        popover.buttons["Keep awake: 1 hr"].click()
        XCTAssertTrue(popover.text("Manual: 1 hour").waitForExistence(timeout: 3))
        shoot(popover, "popover-one-session-\(mode)")
        shoot(app.windows["MenuBarPreview"], "menubar-pill-\(mode)")
        app.terminate()

        // Popover: a URL session plus a manual one.
        launch(base + ["-UITestOpenURL", "uawake://activate?duration=45m&reason=Render"])
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        popover.buttons["Keep awake: 2 hrs"].click()
        XCTAssertTrue(popover.text("Manual: 2 hours").waitForExistence(timeout: 3))
        shoot(popover, "popover-two-sessions-\(mode)")
        app.terminate()

        // Popover: refusal banner.
        launch(["-UITesting", "-UITestAppearance", mode, "-UITestDeviceState", "lowPower"])
        XCTAssertTrue(popover.text("Keep awake for").waitForExistence(timeout: 10))
        popover.labeled("Keep awake").click()
        XCTAssertTrue(popover.text("Low Power Mode is on.").waitForExistence(timeout: 3))
        shoot(popover, "popover-refusal-\(mode)")
        app.terminate()

        // Main window: every section, with a session running on Overview.
        launch(base + ["-UITestMainWindow"])
        let window = app.windows["Main"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["Keep awake: 2 hrs"].click()
        XCTAssertTrue(window.text("Manual: 2 hours").waitForExistence(timeout: 2))
        shoot(window, "main-overview-\(mode)")
        for section in ["Durations", "Safety", "Appearance", "General", "About"] {
            window.text(section).click()
            sleep(1)
            shoot(window, "main-\(section.lowercased())-\(mode)")
        }
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
