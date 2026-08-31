import SwiftUI

struct TunerReading: Equatable {
    let letter: String
    let sharp: Bool
    let octave: Int
    let pitchClass: Int
    let cents: Double
    let hz: Double

    var noteName: String { sharp ? "\(letter)#" : letter }
    var fullName: String { "\(noteName)\(octave)" }
    var inTune: Bool { abs(cents) < 5 }
    var close: Bool { abs(cents) < 12 }
    var isFlat: Bool { cents < -5 }
    var isSharp: Bool { cents > 5 }

    static func detect(hz: Double, confidence: Double) -> TunerReading? {
        guard hz > 28, confidence > 0.32 else { return nil }
        let midi = 69 + 12 * log2(hz / 440.0)
        let nearest = midi.rounded()
        let cents = (midi - nearest) * 100
        let pitchClass = ((Int(nearest) % 12) + 12) % 12
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let name = names[pitchClass]
        let letter = String(name.prefix(1))
        return TunerReading(
            letter: letter,
            sharp: name.count > 1,
            octave: Int(nearest) / 12 - 1,
            pitchClass: pitchClass,
            cents: cents,
            hz: hz
        )
    }
}

struct BassOpenString: Identifiable, Equatable {
    let id: String
    let label: String
    let pitchClass: Int
    let hz: Double

    static let fourString: [BassOpenString] = [
        BassOpenString(id: "E", label: "E", pitchClass: 4, hz: 41.203),
        BassOpenString(id: "A", label: "A", pitchClass: 9, hz: 55.000),
        BassOpenString(id: "D", label: "D", pitchClass: 2, hz: 73.416),
        BassOpenString(id: "G", label: "G", pitchClass: 7, hz: 97.999)
    ]
}

struct TunerDisplay: View {
    var hz: Double
    var confidence: Double
    var isRunning: Bool = true

    private var reading: TunerReading? {
        TunerReading.detect(hz: hz, confidence: confidence)
    }

    var body: some View {
        VStack(spacing: 10) {
            noteStage
            TunerCentsBar(cents: reading?.cents ?? 0, live: reading != nil)
            stringRow
        }
        .frame(height: 133)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tuner")
        .accessibilityValue(Text(accessibilityValue))
    }

    private var noteStage: some View {
        HStack(alignment: .center, spacing: 10) {
            biasMark(
                systemName: "arrowtriangle.left.fill",
                lit: reading?.isFlat == true,
                inTune: reading?.inTune == true
            )
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(reading?.noteName ?? "—")
                        .font(AmpTheme.display(32, weight: .bold))
                        .foregroundStyle(reading.map(noteColor) ?? AmpTheme.faint)
                    Text(reading.map { "\($0.octave)" } ?? " ")
                        .font(AmpTheme.mono(12, weight: .semibold))
                        .foregroundStyle(AmpTheme.muted)
                        .opacity(reading == nil ? 0 : 1)
                }
                Text(reading.map { centsLabel($0.cents) } ?? (isRunning ? "Play a note" : "Power on to tune"))
                    .font(AmpTheme.mono(11, weight: .semibold))
                    .foregroundStyle(reading?.inTune == true ? AmpTheme.ok : AmpTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            biasMark(
                systemName: "arrowtriangle.right.fill",
                lit: reading?.isSharp == true,
                inTune: reading?.inTune == true
            )
        }
        .frame(height: 52)
        .animation(.easeOut(duration: 0.12), value: reading?.fullName)
    }

    private var stringRow: some View {
        HStack(spacing: 6) {
            ForEach(BassOpenString.fourString) { string in
                let active = reading?.pitchClass == string.pitchClass
                let inTune = active && (reading?.inTune == true)
                Text(string.label)
                    .font(AmpTheme.label(11))
                    .foregroundStyle(active ? (inTune ? AmpTheme.bg : AmpTheme.text) : AmpTheme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(inTune ? AmpTheme.ok : (active ? AmpTheme.accent.opacity(0.22) : AmpTheme.inset))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                inTune ? AmpTheme.ok : (active ? AmpTheme.accent.opacity(0.7) : AmpTheme.line),
                                lineWidth: 1
                            )
                    )
            }
            Text(reading != nil ? String(format: "%.1f Hz", hz) : "A4 440")
                .font(AmpTheme.mono(9))
                .foregroundStyle(AmpTheme.faint)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 26)
    }

    private func biasMark(systemName: String, lit: Bool, inTune: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(inTune ? AmpTheme.ok : (lit ? AmpTheme.danger : AmpTheme.faint))
            .frame(width: 16)
    }

    private func noteColor(_ reading: TunerReading) -> Color {
        if reading.inTune { return AmpTheme.ok }
        if reading.close { return AmpTheme.warn }
        return AmpTheme.text
    }

    private func centsLabel(_ cents: Double) -> String {
        if abs(cents) < 0.5 { return "0 ¢" }
        return String(format: "%+.0f ¢", cents)
    }

    private var accessibilityValue: String {
        guard let reading else {
            return isRunning ? "Waiting for a note" : "Power on to tune"
        }
        if reading.inTune {
            return "\(reading.fullName), in tune, \(String(format: "%.1f hertz", reading.hz))"
        }
        let side = reading.cents < 0 ? "flat" : "sharp"
        return "\(reading.fullName), \(String(format: "%.0f cents", abs(reading.cents))) \(side)"
    }
}

struct TunerCentsBar: View {
    var cents: Double
    var live: Bool

    private let segments = 25

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let clamped = max(-1, min(1, cents / 50))
                let needleX = geo.size.width * 0.5 + geo.size.width * 0.48 * CGFloat(clamped)
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(AmpTheme.inset)

                    HStack(spacing: 2) {
                        ForEach(0..<segments, id: \.self) { i in
                            let t = Double(i) / Double(segments - 1)
                            let centsAt = (t - 0.5) * 100
                            let lit = live && shouldLight(centsAt: centsAt, needle: cents)
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(segmentColor(centsAt: centsAt, lit: lit))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)

                    Rectangle()
                        .fill(AmpTheme.lineStrong)
                        .frame(width: 1, height: geo.size.height - 4)

                    Capsule()
                        .fill(live ? needleColor : AmpTheme.faint)
                        .frame(width: 3, height: geo.size.height - 2)
                        .offset(x: live ? needleX - geo.size.width * 0.5 : 0)
                        .shadow(color: live ? needleColor.opacity(0.8) : .clear, radius: 4)
                        .animation(.interpolatingSpring(stiffness: 260, damping: 24), value: live ? cents : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 20)

            HStack {
                Text("FLAT")
                Spacer()
                Text("0")
                Spacer()
                Text("SHARP")
            }
            .font(AmpTheme.label(8))
            .tracking(1.1)
            .foregroundStyle(AmpTheme.faint)
            .frame(height: 10)
        }
        .frame(height: 35)
    }

    private var needleColor: Color {
        if abs(cents) < 5 { return AmpTheme.ok }
        if abs(cents) < 12 { return AmpTheme.warn }
        return AmpTheme.danger
    }

    private func shouldLight(centsAt: Double, needle: Double) -> Bool {
        let span = 100.0 / Double(segments - 1)
        if abs(needle) < 5 {
            return abs(centsAt) < 8
        }
        if needle < 0 {
            return centsAt <= 0 && centsAt >= needle - span
        }
        return centsAt >= 0 && centsAt <= needle + span
    }

    private func segmentColor(centsAt: Double, lit: Bool) -> Color {
        guard lit else { return AmpTheme.surfaceRaised }
        if abs(centsAt) < 8 { return AmpTheme.ok }
        if abs(centsAt) < 22 { return AmpTheme.warn }
        return AmpTheme.danger
    }
}

struct TunerBadge: View {
    var hz: Double
    var confidence: Double
    var isRunning: Bool = true

    var body: some View {
        TunerDisplay(hz: hz, confidence: confidence, isRunning: isRunning)
    }
}
