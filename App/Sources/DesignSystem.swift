import SwiftUI
import UAwakeCore

// Shared building blocks for the popover and the main window: cards, pills, icon tiles,
// chips, banners and a thin progress bar. Colours always come with an icon and text.

extension Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .good: .green
        case .caution: .orange
        case .critical: .red
        }
    }
}

extension SessionSource {
    var tint: Color {
        switch self {
        case .manual: .blue
        case .url: .purple
        case .rule: .orange
        case .cli: .gray
        case .shortcut: .pink
        case .mdm: .teal
        }
    }
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
            .foregroundStyle(
                prominent
                    ? AnyShapeStyle(.white) : (selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            )
            .background {
                Capsule().fill(
                    prominent
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07)))
            }
            .overlay {
                if contrast == .increased && !prominent {
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
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
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
            Text(chip.text).foregroundStyle(contrast == .increased ? .primary : .secondary)
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
                Text(banner.message).font(.callout).foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
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
