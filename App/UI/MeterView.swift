import SwiftUI

struct VUMeter: View {
    var level: Double
    var clip: Bool
    var label: String = "OUT"
    var compact: Bool = false

    private var segments: Int { compact ? 18 : 24 }

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                stackedBody
            }
        }
    }

    private var stackedBody: some View {
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
            segmentRow(height: 10, spacing: 3)
        }
    }

    private var compactBody: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(AmpTheme.label(8))
                .tracking(1.2)
                .foregroundStyle(clip ? AmpTheme.danger : AmpTheme.muted)
                .frame(width: 22, alignment: .leading)
            segmentRow(height: 7, spacing: 2)
            Text("CLIP")
                .font(AmpTheme.label(8))
                .tracking(0.8)
                .foregroundStyle(AmpTheme.danger)
                .opacity(clip ? 1 : 0)
                .frame(width: 28, alignment: .leading)
        }
    }

    private func segmentRow(height: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<segments, id: \.self) { i in
                let t = Double(i) / Double(segments - 1)
                let lit = level > t
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(color(for: t, lit: lit))
                    .frame(height: height)
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
    var compact: Bool = false
    var onClearClip: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            VUMeter(level: input, clip: inClip, label: "IN", compact: compact)
            HStack(alignment: .center, spacing: 8) {
                VUMeter(level: output, clip: outClip, label: "OUT", compact: compact)
                if let onClearClip {
                    Button("Clear", action: onClearClip)
                        .buttonStyle(StudioButton())
                        .fixedSize()
                        .opacity(inClip || outClip ? 1 : 0)
                        .disabled(!(inClip || outClip))
                }
            }
        }
    }
}
