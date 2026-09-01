import SwiftUI

struct EffectsRail: View {
    @EnvironmentObject private var session: AmpSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignalPathStrip()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 520), spacing: 10)], spacing: 10) {
                PedalCard(title: "Comp", pedal: "comp", isOn: $session.compOn) {
                    AmpKnob(value: $session.compThresholdDb, range: -40 ... -6, label: "Thr", size: 40, format: { String(format: "%.0f dB", $0) }, onChange: session.pushAllParams)
                    AmpKnob(value: $session.compRatio, range: 1.5...12, label: "Ratio", size: 40, format: { String(format: "%.1f:1", $0) }, onChange: session.pushAllParams)
                    AmpKnob(value: $session.compMakeupDb, range: 0...12, label: "Make", size: 40, format: { String(format: "%+.1f", $0) }, onChange: session.pushAllParams)
                }
                PedalCard(title: "Octaver", pedal: "octaver", isOn: $session.octaverOn) {
                    AmpKnob(value: $session.octaverMix, range: 0...1, label: "Sub", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.octaverTone, range: 0...1, label: "Tone", size: 40, format: pct, onChange: session.pushAllParams)
                }
                PedalCard(title: "Envelope", pedal: "envelope", isOn: $session.envelopeOn) {
                    AmpKnob(value: $session.envelopeSensitivity, range: 0...1, label: "Sens", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.envelopeResonance, range: 0...0.95, label: "Res", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.envelopeMix, range: 0...1, label: "Mix", size: 40, format: pct, onChange: session.pushAllParams)
                }
                PedalCard(title: "Drive", pedal: "drive", isOn: $session.driveOn) {
                    AmpKnob(value: $session.driveAmount, range: 0...1, label: "Drive", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.driveTone, range: 0...1, label: "Tone", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.driveMix, range: 0...1, label: "Mix", size: 40, format: pct, onChange: session.pushAllParams)
                }
                PedalCard(title: "Chorus", pedal: "chorus", isOn: $session.chorusOn) {
                    AmpKnob(value: $session.chorusRate, range: 0.1...4, label: "Rate", size: 40, format: { String(format: "%.2f Hz", $0) }, onChange: session.pushAllParams)
                    AmpKnob(value: $session.chorusDepth, range: 0...1, label: "Depth", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.chorusMix, range: 0...1, label: "Mix", size: 40, format: pct, onChange: session.pushAllParams)
                }
                PedalCard(title: "Delay", pedal: "delay", isOn: $session.delayOn) {
                    AmpKnob(value: $session.delayTimeMs, range: 50...600, label: "Time", size: 40, format: { String(format: "%.0f ms", $0) }, onChange: session.pushAllParams)
                    AmpKnob(value: $session.delayFeedback, range: 0...0.85, label: "Fdbk", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.delayMix, range: 0...1, label: "Mix", size: 40, format: pct, onChange: session.pushAllParams)
                }
                PedalCard(title: "Reverb", pedal: "reverb", isOn: $session.reverbOn) {
                    AmpKnob(value: $session.reverbSize, range: 0...1, label: "Size", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.reverbDamp, range: 0...1, label: "Damp", size: 40, format: pct, onChange: session.pushAllParams)
                    AmpKnob(value: $session.reverbMix, range: 0...1, label: "Mix", size: 40, format: pct, onChange: session.pushAllParams)
                }
                PedalCard(title: "Filter", pedal: "filter", isOn: $session.utilityFilterOn) {
                    AmpKnob(value: $session.highPassHz, range: 20...180, label: "HPF", size: 40, format: { String(format: "%.0f Hz", $0) }, onChange: session.pushAllParams)
                    AmpKnob(value: $session.lowPassHz, range: 1200...16000, label: "LPF", size: 40, format: { $0 >= 1000 ? String(format: "%.1f k", $0 / 1000) : String(format: "%.0f", $0) }, onChange: session.pushAllParams)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pct: (Double) -> String {
        { String(format: "%.0f%%", $0 * 100) }
    }
}

private struct SignalPathStrip: View {
    @EnvironmentObject private var session: AmpSession

    private var stages: [SignalStage] {
        [
            SignalStage(id: "gain", label: "GAIN", isOn: true, toggleable: false),
            SignalStage(id: "gate", label: "GATE", isOn: session.gateOn, toggleable: true, toggle: { session.gateOn.toggle() }),
            SignalStage(id: "comp", label: "COMP", isOn: session.compOn, toggleable: true, toggle: { session.compOn.toggle() }),
            SignalStage(id: "oct", label: "OCT", isOn: session.octaverOn, toggleable: true, toggle: { session.octaverOn.toggle() }),
            SignalStage(id: "env", label: "ENV", isOn: session.envelopeOn, toggleable: true, toggle: { session.envelopeOn.toggle() }),
            SignalStage(id: "drive", label: "DRIVE", isOn: session.driveOn, toggleable: true, toggle: { session.driveOn.toggle() }),
            SignalStage(id: "amp", label: "AMP", isOn: session.namOn, toggleable: true, toggle: { session.namOn.toggle() }),
            SignalStage(id: "ir", label: "IR", isOn: session.irOn, toggleable: true, toggle: { session.irOn.toggle() }),
            SignalStage(id: "eq", label: "EQ", isOn: session.eqOn, toggleable: true, toggle: { session.eqOn.toggle() }),
            SignalStage(id: "cho", label: "CHO", isOn: session.chorusOn, toggleable: true, toggle: { session.chorusOn.toggle() }),
            SignalStage(id: "dly", label: "DLY", isOn: session.delayOn, toggleable: true, toggle: { session.delayOn.toggle() }),
            SignalStage(id: "rev", label: "REV", isOn: session.reverbOn, toggleable: true, toggle: { session.reverbOn.toggle() }),
            SignalStage(id: "filter", label: "FILTER", isOn: session.utilityFilterOn, toggleable: true, toggle: { session.utilityFilterOn.toggle() })
        ]
    }

    var body: some View {
        StudioCard(padding: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("PATH")
                        .font(AmpTheme.label(9))
                        .tracking(1.6)
                        .foregroundStyle(AmpTheme.faint)
                        .frame(width: 40, alignment: .leading)
                    ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(AmpTheme.faint)
                        }
                        Button {
                            guard stage.toggleable else { return }
                            stage.toggle()
                            session.pushAllParams()
                        } label: {
                            Text(stage.label)
                                .font(AmpTheme.mono(9, weight: stage.isOn && stage.toggleable ? .bold : .medium))
                                .foregroundStyle(chipForeground(stage))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(chipFill(stage))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(chipStroke(stage), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .disabled(!stage.toggleable)
                        .help(stage.toggleable ? "Toggle \(stage.label)" : "Always in the path")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 34)
        }
    }

    private func chipForeground(_ stage: SignalStage) -> Color {
        if !stage.toggleable { return AmpTheme.muted }
        return stage.isOn ? AmpTheme.accent : AmpTheme.faint
    }

    private func chipFill(_ stage: SignalStage) -> Color {
        if !stage.toggleable { return AmpTheme.surfaceRaised }
        return stage.isOn ? AmpTheme.accent.opacity(0.14) : AmpTheme.inset
    }

    private func chipStroke(_ stage: SignalStage) -> Color {
        if !stage.toggleable { return AmpTheme.line }
        return stage.isOn ? AmpTheme.accent.opacity(0.5) : AmpTheme.line
    }
}

private struct SignalStage: Identifiable {
    let id: String
    let label: String
    let isOn: Bool
    var toggleable: Bool = true
    var toggle: () -> Void = {}
}

private struct PedalCard<Knobs: View>: View {
    @EnvironmentObject private var session: AmpSession
    let title: String
    let pedal: String
    @Binding var isOn: Bool
    @ViewBuilder var knobs: () -> Knobs

    var body: some View {
        StudioCard(padding: 10, emphasized: isOn) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title.uppercased())
                        .font(AmpTheme.label(11))
                        .tracking(1.5)
                        .foregroundStyle(AmpTheme.text)
                    Spacer()
                    LEDToggle(isOn: $isOn, title: isOn ? "On" : "Off") {
                        session.pushAllParams()
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        knobs()
                    }
                    .frame(minHeight: 72)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                Menu {
                    ForEach(PedalFactoryPreset.presets(for: pedal)) { preset in
                        Button(preset.name) {
                            session.applyPedalPreset(preset)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Presets")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(AmpTheme.label(10))
                    .foregroundStyle(AmpTheme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AmpTheme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(isOn ? 1 : 0.7)
    }
}
