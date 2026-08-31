import SwiftUI

struct VUMeter: View {
    var level: Double
    var clip: Bool
    var label: String = "OUT"

    private let segments = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(AmpTheme.label(9))
                    .tracking(1.6)
                    .foregroundStyle(AmpTheme.muted)
                Spacer()
                if clip {
                    Text("CLIP")
                        .font(AmpTheme.label(9))
                        .tracking(1.4)
                        .foregroundStyle(AmpTheme.danger)
                }
            }
            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { i in
                    let t = Double(i) / Double(segments - 1)
                    let lit = level > t
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color(for: t, lit: lit))
                        .frame(height: 10)
                }
            }
        }
    }

    private func color(for t: Double, lit: Bool) -> Color {
        guard lit else { return AmpTheme.inset }
        if t > 0.86 { return AmpTheme.danger }
        if t > 0.68 { return AmpTheme.warn }
        return AmpTheme.accent
    }
}

struct LevelPills: View {
    let input: Double
    let output: Double
    let inClip: Bool
    let outClip: Bool

    var body: some View {
        VStack(spacing: 10) {
            VUMeter(level: input, clip: inClip, label: "IN")
            VUMeter(level: output, clip: outClip, label: "OUT")
        }
    }
}
