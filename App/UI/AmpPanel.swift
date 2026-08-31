import SwiftUI

struct AmpPanel: View {
    @EnvironmentObject private var session: AmpSession
    var onLoadNAM: () -> Void
    var onLoadIR: () -> Void
    var onSavePreset: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Tuner")
                    TunerBadge(hz: session.tunerHz, confidence: session.tunerConfidence)
                    LevelPills(
                        input: session.inputPeak,
                        output: session.outputPeak,
                        inClip: session.inputClip,
                        outClip: session.outputClip
                    )
                    Button("Clear clip") { session.clearClips() }
                        .buttonStyle(StudioButton())
                        .opacity(session.inputClip || session.outputClip ? 1 : 0.45)
                }
            }
            .frame(width: 260)

            StudioCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        SectionLabel(text: "Amp")
                        Spacer()
                        LEDToggle(isOn: $session.ultraLoOn, title: "Ultra Lo") { session.pushAllParams() }
                        LEDToggle(isOn: $session.ultraHiOn, title: "Ultra Hi") { session.pushAllParams() }
                        Text("•")
                            .foregroundStyle(AmpTheme.faint)
                        LEDToggle(isOn: $session.gateOn, title: "Gate", onChange: session.pushAllParams)
                        LEDToggle(isOn: $session.eqOn, title: "EQ", onChange: session.pushAllParams)
                        LEDToggle(isOn: $session.namOn, title: "Amp", onChange: session.pushAllParams)
                        LEDToggle(isOn: $session.irOn, title: "IR", onChange: session.pushAllParams)
                    }

                    HStack(spacing: 16) {
                        AmpKnob(value: $session.inputGainDb, range: -12...24, label: "Gain", format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.bassDb, range: -12...12, label: "Bass", format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.midDb, range: -12...12, label: "Mid", format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.trebleDb, range: -12...12, label: "Treble", format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.outputGainDb, range: -24...18, label: "Master", format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.gateThresholdDb, range: -80 ... -20, label: "Gate", format: dbFormat, onChange: session.pushAllParams)
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 6) {
                        Text("MID FREQ")
                            .font(AmpTheme.label(9))
                            .tracking(1.4)
                            .foregroundStyle(AmpTheme.faint)
                            .padding(.trailing, 4)

                        let midOptions = ["220 Hz", "450 Hz", "800 Hz", "1.6 kHz", "3.0 kHz"]
                        ForEach(0..<5, id: \.self) { idx in
                            let isSel = session.midFreqIndex == idx
                            Button {
                                session.midFreqIndex = idx
                                session.pushAllParams()
                            } label: {
                                Text(midOptions[idx])
                                    .font(AmpTheme.mono(10, weight: isSel ? .bold : .medium))
                                    .foregroundStyle(isSel ? AmpTheme.accent : AmpTheme.muted)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isSel ? AmpTheme.accent.opacity(0.15) : AmpTheme.surfaceRaised)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(isSel ? AmpTheme.accent.opacity(0.5) : AmpTheme.line, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Amp / Cabinet")
                    loaderRow(
                        title: "Amp",
                        value: session.namName,
                        on: session.namOn,
                        load: onLoadNAM,
                        clear: session.namPath == nil ? nil : { session.useCleanAmp() }
                    ) {
                        session.namOn.toggle()
                        session.pushAllParams()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("CABINET")
                            .font(AmpTheme.label(9))
                            .tracking(1.5)
                            .foregroundStyle(AmpTheme.faint)
                        HStack(spacing: 8) {
                            Button(action: {
                                session.irOn.toggle()
                                session.pushAllParams()
                            }) {
                                Circle()
                                    .fill(session.irOn ? AmpTheme.accent : AmpTheme.inset)
                                    .frame(width: 8, height: 8)
                                    .shadow(color: session.irOn ? AmpTheme.accent.opacity(0.7) : .clear, radius: 4)
                            }
                            .buttonStyle(.plain)

                            Picker("", selection: $session.selectedCabinet) {
                                ForEach(AmpSession.availableCabinets, id: \.id) { cab in
                                    Text(cab.name).tag(cab.id)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: session.selectedCabinet) { _, cab in
                                session.selectCabinetNamed(cab)
                            }

                            Spacer(minLength: 0)

                            Button("Custom", action: onLoadIR)
                                .buttonStyle(StudioButton())
                        }
                    }

                    SectionLabel(text: "Preset")
                    HStack(spacing: 8) {
                        Picker("", selection: $session.selectedPresetID) {
                            ForEach(session.presets) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: session.selectedPresetID) { _, id in
                            if let preset = session.presets.first(where: { $0.id == id }) {
                                session.applyPreset(preset)
                            }
                        }
                        Button("Save") { onSavePreset() }
                            .buttonStyle(StudioButton())
                    }
                }
            }
            .frame(width: 300)
        }
    }

    private var dbFormat: (Double) -> String {
        { String(format: "%+.1f dB", $0) }
    }

    private func loaderRow(
        title: String,
        value: String,
        on: Bool,
        load: @escaping () -> Void,
        clear: (() -> Void)? = nil,
        toggle: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(AmpTheme.label(9))
                .tracking(1.5)
                .foregroundStyle(AmpTheme.faint)
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Circle()
                        .fill(on ? AmpTheme.accent : AmpTheme.inset)
                        .frame(width: 8, height: 8)
                        .shadow(color: on ? AmpTheme.accent.opacity(0.7) : .clear, radius: 4)
                }
                .buttonStyle(.plain)
                Text(value)
                    .font(AmpTheme.caption(12))
                    .foregroundStyle(AmpTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let clear {
                    Button("Clean", action: clear)
                        .buttonStyle(StudioButton())
                }
                Button("Load", action: load)
                    .buttonStyle(StudioButton())
            }
        }
    }
}
