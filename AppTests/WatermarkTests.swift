import Testing

@testable import uawake

struct WatermarkTests {
    @MainActor @Test func colours() {
        #expect(WatermarkController.hex("amber") == 0xFFB340)
        #expect(WatermarkController.hex("#123456") == 0x123456)
        #expect(WatermarkController.hex("nonsense") == 0x1F6FE5)
        #expect(WatermarkController.hexText(WatermarkController.colour("#FF8000")) == "#FF8000")
    }
}
