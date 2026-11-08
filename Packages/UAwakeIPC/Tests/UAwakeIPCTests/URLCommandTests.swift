import Foundation
import Testing
import UAwakeCore

@testable import UAwakeIPC

struct URLCommandTests {
    func parse(_ string: String) throws(URLCommandError) -> URLCommand {
        try URLCommand(url: URL(string: string)!)
    }

    @Test(arguments: [
        ("uawake://activate", URLCommand.activate(ActivateOptions())),
        ("uawake://activate?duration=90m", .activate(ActivateOptions(endCondition: .duration(.seconds(5400))))),
        ("uawake://activate?duration=1h30m", .activate(ActivateOptions(endCondition: .duration(.seconds(5400))))),
        ("uawake://activate?duration=2h15m", .activate(ActivateOptions(endCondition: .duration(.seconds(8100))))),
        ("uawake://activate?duration=45s", .activate(ActivateOptions(endCondition: .duration(.seconds(45))))),
        ("uawake://activate?duration=1h2m3s", .activate(ActivateOptions(endCondition: .duration(.seconds(3723))))),
        (
            "uawake://activate?until=18:30",
            .activate(ActivateOptions(endCondition: .until(ClockTime(hour: 18, minute: 30)!)))
        ),
        (
            "uawake://activate?display=1&reason=Render",
            .activate(ActivateOptions(keepsDisplayAwake: true, reason: "Render"))
        ),
        (
            "uawake://activate?display=true&reason=Long%20export",
            .activate(ActivateOptions(keepsDisplayAwake: true, reason: "Long export"))
        ),
        ("uawake://deactivate", .deactivate),
        ("uawake://toggle", .toggle),
        ("UAWAKE://Toggle", .toggle),
    ])
    func validURLs(url: String, expected: URLCommand) throws {
        #expect(try parse(url) == expected)
    }

    @Test(arguments: [
        ("https://activate", URLCommandError.wrongScheme),
        ("uawake://sleep", .unknownCommand("sleep")),
        ("uawake://activate/extra", .unknownCommand("activate/extra")),
        ("uawake://activate?disk=1", .unknownParameter("disk")),
        ("uawake://toggle?duration=1h", .unknownParameter("duration")),
        ("uawake://activate?duration=1h&until=18:30", .conflictingParameters),
        ("uawake://activate?duration=1h&duration=2h", .conflictingParameters),
        ("uawake://activate?duration=0", .invalidValue(parameter: "duration", value: "0")),
        ("uawake://activate?duration=0m", .invalidValue(parameter: "duration", value: "0m")),
        ("uawake://activate?duration=-5m", .invalidValue(parameter: "duration", value: "-5m")),
        ("uawake://activate?duration=90", .invalidValue(parameter: "duration", value: "90")),
        ("uawake://activate?duration=30m1h", .invalidValue(parameter: "duration", value: "30m1h")),
        ("uawake://activate?duration=1h1h", .invalidValue(parameter: "duration", value: "1h1h")),
        ("uawake://activate?duration=1.5h", .invalidValue(parameter: "duration", value: "1.5h")),
        ("uawake://activate?duration=", .invalidValue(parameter: "duration", value: "")),
        ("uawake://activate?duration=9999999h", .invalidValue(parameter: "duration", value: "9999999h")),
        ("uawake://activate?until=24:00", .invalidValue(parameter: "until", value: "24:00")),
        ("uawake://activate?until=6:30", .invalidValue(parameter: "until", value: "6:30")),
        ("uawake://activate?display=yes", .invalidValue(parameter: "display", value: "yes")),
        ("uawake://activate?reason=%20", .invalidValue(parameter: "reason", value: " ")),
    ])
    func invalidURLs(url: String, expected: URLCommandError) {
        #expect(throws: expected) { try parse(url) }
    }
}
