import SwiftUI

struct TunerBadge: View {
    var hz: Double
    var confidence: Double

    private var reading: (note: String, cents: Double)? {
        guard hz > 28, confidence > 0.32 else { return nil }
        let midi = 69 + 12 * log2(hz / 440.0)
        let nearest = midi.rounded()
        let cents = (midi - nearest) * 100
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let note = names[((Int(nearest) % 12) + 12) % 12]
        let octave = Int(nearest) / 12 - 1
        return ("\(note)\(octave)", cents)
    }

    private var inTune: Bool {
        abs(reading?.cents ?? 99) < 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(reading?.note ?? "—")
                    .font(AmpTheme.mono(28, weight: .semibold))
                    .foregroundStyle(inTune ? AmpTheme.accent : AmpTheme.text)
                    .frame(minWidth: 64, alignment: .leading)
                Spacer(minLength: 0)
                Text(reading != nil ? String(format: "%.1f Hz", hz) : "PLAY A NOTE")
                    .font(AmpTheme.mono(10))
                    .foregroundStyle(AmpTheme.faint)
            }

            GeometryReader { geo in
                let live = reading != nil
                let cents = reading?.cents ?? 0
                let x = geo.size.width * 0.5 + geo.size.width * 0.5 * CGFloat(max(-1, min(1, cents / 50)))
                ZStack(alignment: .leading) {
                    Capsule().fill(AmpTheme.inset)
                    Rectangle()
                        .fill(AmpTheme.lineStrong)
                        .frame(width: 1)
                        .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
                    Circle()
                        .fill(live ? (inTune ? AmpTheme.ok : AmpTheme.danger) : AmpTheme.faint)
                        .frame(width: 9, height: 9)
                        .position(x: live ? x : geo.size.width * 0.5, y: geo.size.height * 0.5)
                        .shadow(color: live ? (inTune ? AmpTheme.ok : AmpTheme.danger).opacity(0.7) : .clear, radius: 4)
                }
            }
            .frame(height: 14)
        }
    }
}
