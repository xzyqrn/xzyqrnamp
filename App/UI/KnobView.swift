import SwiftUI

struct AmpKnob: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var label: String
    var size: CGFloat = 56
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    var onChange: () -> Void = {}

    @State private var dragOrigin: Double?

    private var normalized: Double {
        let span = range.upperBound - range.lowerBound
        guard span != 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    private var startAngle: Angle { .degrees(-135) }
    private var sweep: Double { 270 }
    private var angle: Angle { .degrees(-135 + sweep * normalized) }

    var body: some View {
        VStack(spacing: size < 44 ? 4 : 8) {
            ZStack {
                Circle()
                    .stroke(AmpTheme.inset, lineWidth: 6)
                    .frame(width: size, height: size)

                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(AmpTheme.lineStrong, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: size, height: size)

                Circle()
                    .trim(from: 0, to: 0.75 * normalized)
                    .stroke(AmpTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: size, height: size)

                Circle()
                    .fill(AmpTheme.surfaceRaised)
                    .frame(width: size - 14, height: size - 14)
                    .overlay(
                        Circle().strokeBorder(AmpTheme.line, lineWidth: 1)
                            .allowsHitTesting(false)
                    )

                Capsule()
                    .fill(AmpTheme.accent)
                    .frame(width: 2, height: size * 0.22)
                    .offset(y: -size * 0.16)
                    .rotationEffect(angle)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if dragOrigin == nil { dragOrigin = value }
                        let delta = -drag.translation.height / 140
                        let span = range.upperBound - range.lowerBound
                        let next = (dragOrigin ?? value) + delta * span
                        value = min(range.upperBound, max(range.lowerBound, next))
                        onChange()
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                    }
            )
            .accessibilityLabel(label)
            .accessibilityValue(Text(format(value)))
            .accessibilityAdjustableAction { direction in
                let step = (range.upperBound - range.lowerBound) / 24
                switch direction {
                case .increment:
                    value = min(range.upperBound, value + step)
                    onChange()
                case .decrement:
                    value = max(range.lowerBound, value - step)
                    onChange()
                default: break
                }
            }

            VStack(spacing: 1) {
                Text(label.uppercased())
                    .font(AmpTheme.label(size < 44 ? 8 : 10))
                    .tracking(1.2)
                    .foregroundStyle(AmpTheme.muted)
                Text(format(value))
                    .font(AmpTheme.mono(size < 44 ? 8 : 10))
                    .foregroundStyle(AmpTheme.faint)
            }
        }
    }
}
