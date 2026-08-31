import SwiftUI

enum AmpTheme {
    static let bg = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let surface = Color(red: 0.090, green: 0.098, blue: 0.112)
    static let surfaceRaised = Color(red: 0.118, green: 0.128, blue: 0.146)
    static let inset = Color(red: 0.035, green: 0.038, blue: 0.044)
    static let line = Color.white.opacity(0.08)
    static let lineStrong = Color.white.opacity(0.14)
    static let text = Color(red: 0.93, green: 0.93, blue: 0.90)
    static let muted = Color(red: 0.52, green: 0.54, blue: 0.58)
    static let faint = Color(red: 0.36, green: 0.38, blue: 0.42)
    static let accent = Color(red: 0.72, green: 0.96, blue: 0.28)
    static let accentDim = Color(red: 0.42, green: 0.58, blue: 0.16)
    static let danger = Color(red: 0.96, green: 0.28, blue: 0.22)
    static let ok = Color(red: 0.38, green: 0.86, blue: 0.48)
    static let warn = Color(red: 0.98, green: 0.72, blue: 0.22)

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func label(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func caption(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(AmpTheme.label(9))
            .tracking(1.8)
            .foregroundStyle(AmpTheme.faint)
    }
}

struct StudioCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(AmpTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AmpTheme.line, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

struct LEDToggle: View {
    @Binding var isOn: Bool
    var title: String
    var onChange: () -> Void = {}

    var body: some View {
        Button {
            isOn.toggle()
            onChange()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? AmpTheme.accent : AmpTheme.inset)
                    .frame(width: 7, height: 7)
                    .shadow(color: isOn ? AmpTheme.accent.opacity(0.85) : .clear, radius: 5)
                Text(title.uppercased())
                    .font(AmpTheme.label(10))
                    .tracking(1.4)
                    .foregroundStyle(isOn ? AmpTheme.text : AmpTheme.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(AmpTheme.inset)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct StudioButton: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AmpTheme.label(11))
            .tracking(0.6)
            .foregroundStyle(prominent ? AmpTheme.bg : AmpTheme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(prominent ? AmpTheme.accent : AmpTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AmpTheme.line, lineWidth: prominent ? 0 : 1)
                    .allowsHitTesting(false)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct DeviceChip: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(AmpTheme.label(8))
                .tracking(1.4)
                .foregroundStyle(AmpTheme.faint)
            Text(value)
                .font(AmpTheme.caption(11))
                .foregroundStyle(AmpTheme.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AmpTheme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
