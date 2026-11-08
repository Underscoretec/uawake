import XCTest

/// Drives the popover's content in a test window and the Settings window. The app runs
/// with `-UITesting`: throwaway settings and no welcome window.
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
        app.launchArguments = ["-UITesting"]
        app.launch()
        let window = app.windows["Popover"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.text("No active sessions").exists)
        window.switches.firstMatch.click()
        XCTAssertTrue(window.text("Manual: indefinite").waitForExistence(timeout: 2))
        attach("Popover, session on")
        window.switches.firstMatch.click()
        XCTAssertTrue(window.text("No active sessions").waitForExistence(timeout: 2))
    }

    @MainActor
    func testPresetChipAndExtend() throws {
        app.launchArguments = ["-UITesting"]
        app.launch()
        let window = app.windows["Popover"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.buttons["Keep awake: 15 min"].click()
        XCTAssertTrue(window.text("Manual: 15 minutes").waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Extend Manual: 15 minutes by 15 minutes"].exists)
        attach("Popover, timed session")
        window.buttons["Stop Manual: 15 minutes"].click()
        XCTAssertTrue(window.text("No active sessions").waitForExistence(timeout: 2))
    }

    @MainActor
    func testSettingsTabs() throws {
        app.launchArguments = ["-UITesting", "-UITestSettings"]
        app.launch()
        let settings = app.windows["uawake Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons["Record a shortcut"].exists)
        attach("Settings, General")
        for tab in ["Durations", "Safety", "Appearance", "About"] {
            settings.tabs[tab].click()
            attach("Settings, \(tab)")
        }
        settings.tabs["Safety"].click()
        XCTAssertTrue(settings.text("Stop when Low Power Mode turns on").exists)
        settings.tabs["About"].click()
        XCTAssertTrue(settings.text("Created by Abhijit Roy · Underscore Technology").exists)
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIElement {
    /// Any descendant whose label or value starts with `text` (SwiftUI text exposes its
    /// string as the value; combined rows join several strings)
    func text(_ text: String) -> XCUIElement {
        descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", text, text)
        ).firstMatch
    }
}
