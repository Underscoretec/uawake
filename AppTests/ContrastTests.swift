import AppKit
import Testing

@testable import uawake

/// WCAG 2.1 AA for the popover palette in light and dark mode: text 4.5:1, icons and
/// large graphics 3:1, measured against the popover backing and the tinted cards on it.
struct ContrastTests {
    static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    static func rgb(_ color: NSColor, _ appearance: NSAppearance.Name) -> (Double, Double, Double) {
        var result = (0.0, 0.0, 0.0)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? .black
            result = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return result
    }

    static func luminance(_ c: (Double, Double, Double)) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }

    static func blend(_ top: (Double, Double, Double), _ alpha: Double, over base: (Double, Double, Double))
        -> (Double, Double, Double)
    {
        (
            top.0 * alpha + base.0 * (1 - alpha), top.1 * alpha + base.1 * (1 - alpha),
            top.2 * alpha + base.2 * (1 - alpha)
        )
    }

    static func ratio(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test(arguments: appearances)
    func textColorsMeetAA(appearance: NSAppearance.Name) {
        let backing = Self.rgb(Palette.backing, appearance)
        for color in [Palette.secondaryText, Palette.good, Palette.caution, Palette.critical, Palette.blue] {
            let text = Self.rgb(color, appearance)
            #expect(Self.ratio(text, backing) >= 4.5, "\(color) on backing, \(appearance.rawValue)")
            // On a card tinted with the same colour at 10 %.
            let card = Self.blend(text, 0.10, over: backing)
            #expect(Self.ratio(text, card) >= 4.5, "\(color) on its tinted card, \(appearance.rawValue)")
        }
    }

    @Test(arguments: appearances)
    func iconTilesMeetAA(appearance: NSAppearance.Name) {
        let backing = Self.rgb(Palette.backing, appearance)
        let tints = [
            Palette.blue, Palette.purple, Palette.gray, Palette.pink, Palette.teal, Palette.indigo, Palette.caution,
            Palette.critical, Palette.good,
        ]
        for color in tints {
            let icon = Self.rgb(color, appearance)
            let tile = Self.blend(icon, 0.16, over: backing)
            #expect(Self.ratio(icon, tile) >= 3, "\(color) icon on its tile, \(appearance.rawValue)")
        }
    }

    @Test(arguments: appearances)
    func whiteOnProminentButtonsMeetsAA(appearance: NSAppearance.Name) {
        #expect(Self.ratio((1, 1, 1), Self.rgb(Palette.prominent, appearance)) >= 4.5)
    }
}
