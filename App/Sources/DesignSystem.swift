import AppKit
import SwiftUI
import UAwakeCore

// Shared building blocks for the popover and the main window: cards, pills, icon tiles,
// chips, banners and a thin progress bar. Colours always come with an icon and text.

/// Colours checked for WCAG AA against the popover backing in light and dark mode
/// (text 4.5:1, icons 3:1; see ContrastTests). System colours like `.orange` and
/// `.secondary` fall short in light mode, so these are tuned per appearance.
enum Palette {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    /// Near-opaque backing behind the popover's content, so contrast doesn't depend on the desktop.
    static let backing = dynamic(light: 0xF5F5F7, dark: 0x242426)
    static let secondaryText = dynamic(light: 0x5A5A5F, dark: 0xABABB0)
    static let good = dynamic(light: 0x1A7030, dark: 0x4CD964)
    static let caution = dynamic(light: 0x9A5300, dark: 0xFFB340)
    static let critical = dynamic(light: 0xB42318, dark: 0xFF6B60)
    /// Fill behind white text on prominent buttons.
    static let prominent = dynamic(light: 0x0A5BC4, dark: 0x1F6FE5)
    static let blue = dynamic(light: 0x0A5BC4, dark: 0x6AAEFF)
    static let purple = dynamic(light: 0x7E3BC4, dark: 0xC8A2FF)
    static let gray = dynamic(light: 0x5F6368, dark: 0xB0B3B8)
    static let pink = dynamic(light: 0xB5175A, dark: 0xFF85B5)
    static let teal = dynamic(light: 0x00756A, dark: 0x5DD3C3)
    static let indigo = dynamic(light: 0x4A43C7, dark: 0xA29DFF)
}

extension Color {
    static let secondaryText = Color(nsColor: Palette.secondaryText)
    static let popoverBacking = Color(nsColor: Palette.backing)
}

extension Tone {
    var nsColor: NSColor {
        switch self {
        case .neutral: Palette.secondaryText
        case .good: Palette.good
        case .caution: Palette.caution
        case .critical: Palette.critical
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension SessionSource {
    var nsTint: NSColor {
        switch self {
        case .manual: Palette.blue
        case .url: Palette.purple
        case .rule: Palette.caution
        case .cli: Palette.gray
        case .shortcut: Palette.pink
        case .mdm: Palette.teal
        }
    }

    var tint: Color { Color(nsColor: nsTint) }
}

/// Rounded, softly filled card with a hairline border (stronger with Increase Contrast).
struct CardModifier: ViewModifier {
    var radius: CGFloat = 14
    var tint: Color?
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if let tint {
                    shape.fill(tint.opacity(0.10))
                } else {
                    shape.fill(.quinary)
                }
            }
            .overlay {
                shape.strokeBorder(
                    tint?.opacity(contrast == .increased ? 0.8 : 0.25) ?? Color(nsColor: .separatorColor),
                    lineWidth: contrast == .increased ? 1 : 0.5)
            }
    }
}

extension View {
    func card(radius: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(CardModifier(radius: radius, tint: tint))
    }
}

/// Capsule button: preset chips, extend, Quit. `prominent` fills with the accent colour.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 3 : 6)
            .foregroundStyle(prominent ? Color.white : (selected ? Color(nsColor: Palette.blue) : Color.primary))
            .background {
                Capsule().fill(
                    prominent
                        ? Color(nsColor: Palette.prominent)
                        : (selected ? Color(nsColor: Palette.blue).opacity(0.16) : Color.primary.opacity(0.07)))
            }
            .overlay {
                if selected {
                    Capsule().strokeBorder(Color(nsColor: Palette.blue), lineWidth: 1.5)
                } else if contrast == .increased && !prominent {
                    Capsule().strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// A rounded square with a tinted SF Symbol: session sources, banners, empty states.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.secondaryText)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(Color.secondaryText).monospacedDigit()
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct ThinProgressBar: View {
    let value: Double
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint).frame(width: max(4, proxy.size.width * value))
            }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: value)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress", comment: "Hero progress bar, VoiceOver"))
        .accessibilityValue(Text(value.formatted(.percent.precision(.fractionLength(0)))))
    }
}

struct StatusChipView: View {
    let chip: StatusChip
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: chip.symbol).foregroundStyle(chip.tone.color)
            Text(chip.text).foregroundStyle(contrast == .increased ? Color.primary : Color.secondaryText)
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            chip.tone == .neutral ? Color.primary.opacity(0.06) : chip.tone.color.opacity(0.12), in: Capsule()
        )
        .accessibilityElement()
        .accessibilityLabel(chip.accessibilityLabel)
    }
}

struct StatusStrip: View {
    let chips: [StatusChip]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips) { StatusChipView(chip: $0) }
            Spacer(minLength: 0)
        }
    }
}

struct BannerView: View {
    let banner: Banner
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: banner.symbol, tint: banner.tone.color, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title).font(.callout.weight(.semibold))
                Text(banner.message).font(.callout).foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if banner.section == .safety {
                    Button("Open Safety Settings", action: open)
                        .buttonStyle(PillButtonStyle(compact: true))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Color.secondaryText)
            .accessibilityLabel(Text("Dismiss \(banner.title)"))
        }
        .padding(12)
        .card(radius: 14, tint: banner.tone.color)
        .accessibilityElement(children: .contain)
    }
}

/// The on/off control drawn as a big button ("Keep Awake" / "Turn Off") that VoiceOver
/// still reads as the "Keep awake" switch.
struct HeroToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            if configuration.isOn {
                Label("Turn Off", systemImage: "stop.fill")
            } else {
                Label("Keep Awake", systemImage: "cup.and.saucer.fill")
            }
        }
        .buttonStyle(PillButtonStyle(prominent: !configuration.isOn))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
