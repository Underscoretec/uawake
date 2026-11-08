import Testing
import UAwakeCore

@testable import uawake

struct SessionReasonLocalizedTests {
    @Test func standardReasonsRenderInEnglish() {
        #expect(SessionReason.standard(.manual, .duration(.seconds(7200))).localizedDescription == "Manual: 2 hours")
        #expect(SessionReason.standard(.url, .indefinite).localizedDescription == "URL: indefinite")
        #expect(SessionReason.standard(.manual, .batteryLevel(20)).localizedDescription == "Manual: until battery 20%")
        #expect(SessionReason.custom("Render").localizedDescription == "Render")
        #expect(SessionReason.rule(name: "On a call").localizedDescription == "Rule: On a call")
    }
}
