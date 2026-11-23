import AppKit
import Testing
import UAwakeCore

@testable import uawake

@MainActor
struct StatusItemControllerTests {
    @Test func menuClicksOpenThePopoverAtOnce() {
        let wantsMenu = StatusItemController.wantsMenu
        #expect(wantsMenu(.rightMouseUp, []))
        #expect(wantsMenu(.leftMouseUp, .option))
        #expect(wantsMenu(.leftMouseUp, .control))
        #expect(!wantsMenu(.leftMouseUp, []))
        #expect(!wantsMenu(.leftMouseUp, .command))
    }

    /// The menu bar reports every click with a click count of 1, so doubles are timed.
    @Test func doubleClicksAreTwoClicksWithinTheInterval() {
        var clicks = ClickSequence(interval: 0.5)
        #expect(clicks.click(at: 10) == .single)
        #expect(clicks.click(at: 10.2) == .double)
        #expect(clicks.click(at: 10.4) == .ignored, "a third click")
        #expect(clicks.click(at: 12) == .single)
        #expect(clicks.click(at: 12.6) == .single, "too slow for a double")
        // The interval ran out while the button was held for the second click.
        clicks.awaitSecondClick()
        #expect(clicks.click(at: 13.2) == .double)
        #expect(clicks.click(at: 20) == .single)
        clicks.awaitSecondClick()  // Held somewhere else; a much later click is a new one.
        #expect(clicks.click(at: 30) == .single)
    }

    @Test func iconIsDimmedWhenIdleAndHighlightedWhenActive() {
        func render(_ highlight: MenuBarHighlight, _ tone: PopoverViewModel.MenuBarTone, _ countdown: String? = nil)
            -> (
                image: NSImage, tint: NSColor?, dimmed: Bool
            )
        {
            StatusItemController.render(.init(style: .uawake, highlight: highlight, tone: tone, countdown: countdown))
        }
        for highlight in MenuBarHighlight.allCases {
            let idle = render(highlight, .idle, "1:42")
            #expect(idle.dimmed && idle.image.isTemplate && idle.tint == nil)
            #expect(idle.image == StatusItemController.symbolImage(style: .uawake, active: false))
        }

        let capsule = render(.capsule, .awake)
        #expect(!capsule.dimmed && !capsule.image.isTemplate && capsule.tint == nil)
        #expect(render(.capsule, .awake, "1:42").image.size.width > capsule.image.size.width)
        #expect(!render(.capsule, .stopped).dimmed)

        let coloured = render(.colouredIcon, .awake, "42m")
        #expect(coloured.image.isTemplate && coloured.tint == .systemBlue && !coloured.dimmed)
        #expect(render(.colouredIcon, .endingSoon).tint == .systemOrange)
        #expect(render(.colouredIcon, .stopped).tint == .systemRed)

        let none = render(.none, .awake)
        #expect(none.image.isTemplate && none.tint == nil && !none.dimmed)
        #expect(render(.none, .stopped).dimmed, "no highlight, no red flash")
    }

    @Test func increaseContrastDarkensTheCapsule() {
        let colours = StatusItemController.capsuleColours
        for tone in [PopoverViewModel.MenuBarTone.awake, .stopped] {
            let normal = colours(tone, false).fill.brightnessComponent
            #expect(colours(tone, true).fill.brightnessComponent < normal)
            #expect(colours(tone, false).content == .white)
        }
    }
}
