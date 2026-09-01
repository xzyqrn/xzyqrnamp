import SwiftUI

struct AmpPanel: View {
    @EnvironmentObject private var session: AmpSession
    var onLoadNAM: () -> Void
    var onLoadIR: () -> Void
    var onSavePreset: () -> Void

    var body: some View {
        EqualHeightHStack(spacing: 12, equalWidths: true) {
            tunerCard
            ampCard
            cabCard
        }
    }

    private var tunerCard: some View {
        StudioCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Tuner")
                    Spacer(minLength: 0)
                    LEDToggle(isOn: $session.tunerMute, title: "Mute", destructive: true) {
                        session.pushAllParams()
                    }
                    .help(session.tunerMute
                          ? "Unmute the amp output"
                          : "Mute the amp while you tune. The beat keeps playing.")
                }
                TunerDisplay(
                    hz: session.tunerHz,
                    confidence: session.tunerConfidence,
                    isRunning: session.isRunning
                )
                Spacer(minLength: 8)
                LevelPills(
                    input: session.inputPeak,
                    output: session.outputPeak,
                    inClip: session.inputClip,
                    outClip: session.outputClip,
                    compact: true,
                    onClearClip: { session.clearClips() }
                )
            }
        }
    }

    private var ampCard: some View {
        StudioCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel(text: "Amp")
                    Spacer(minLength: 8)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            LEDToggle(isOn: $session.nrOn, title: "NR", onChange: session.pushAllParams)
                            LEDToggle(isOn: $session.gateOn, title: "Gate", onChange: session.pushAllParams)
                            LEDToggle(isOn: $session.eqOn, title: "EQ", onChange: session.pushAllParams)
                            LEDToggle(isOn: $session.namOn, title: "Amp", onChange: session.pushAllParams)
                            LEDToggle(isOn: $session.irOn, title: "IR", onChange: session.pushAllParams)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(minHeight: 28)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        AmpKnob(value: $session.inputGainDb, range: -12...24, label: "Gain", size: 46, format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.bassDb, range: -12...12, label: "Bass", size: 46, format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.midDb, range: -12...12, label: "Mid", size: 46, format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.trebleDb, range: -12...12, label: "Treble", size: 46, format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.outputGainDb, range: -24...18, label: "Master", size: 46, format: dbFormat, onChange: session.pushAllParams)
                        AmpKnob(value: $session.gateThresholdDb, range: -80 ... -20, label: "Gate", size: 46, format: dbFormat, onChange: session.pushAllParams)
                    }
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        LEDToggle(isOn: $session.ultraLoOn, title: "Lo") { session.pushAllParams() }
                            .help("Ultra Lo")
                        LEDToggle(isOn: $session.ultraHiOn, title: "Hi") { session.pushAllParams() }
                            .help("Ultra Hi")
                        Rectangle()
                            .fill(AmpTheme.line)
                            .frame(width: 1, height: 16)
                        Text("MID")
                            .font(AmpTheme.label(9))
                            .tracking(1.4)
                            .foregroundStyle(AmpTheme.faint)
                        ForEach(Array(midOptions.enumerated()), id: \.offset) { idx, title in
                            let isSel = session.midFreqIndex == idx
                            Button {
                                session.midFreqIndex = idx
                                session.pushAllParams()
                            } label: {
                                Text(title)
                                    .font(AmpTheme.mono(10, weight: isSel ? .bold : .medium))
                                    .foregroundStyle(isSel ? AmpTheme.accent : AmpTheme.muted)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(isSel ? AmpTheme.accent.opacity(0.15) : AmpTheme.surfaceRaised)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(isSel ? AmpTheme.accent.opacity(0.5) : AmpTheme.line, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(minHeight: 28)
            }
        }
    }

    private var cabCard: some View {
        StudioCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Amp / Cabinet")
                Spacer(minLength: 12)
                rigRow(
                    title: "Amp",
                    value: session.namName,
                    on: session.namOn,
                    loadTitle: "Load",
                    load: onLoadNAM,
                    clear: session.namPath == nil ? nil : { session.clearNAMToPassthrough() }
                ) {
                    session.namOn.toggle()
                    session.pushAllParams()
                }
                Spacer(minLength: 12)
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
                        .help(session.irOn ? "Bypass cabinet" : "Enable cabinet")

                        Picker("", selection: $session.selectedCabinet) {
                            ForEach(AmpSession.availableCabinets, id: \.id) { cab in
                                Text(cab.name).tag(cab.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: session.selectedCabinet) { _, cab in
                            session.selectCabinetNamed(cab)
                        }

                        Button("Custom", action: onLoadIR)
                            .buttonStyle(StudioButton())
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text("PRESET")
                        .font(AmpTheme.label(9))
                        .tracking(1.5)
                        .foregroundStyle(AmpTheme.faint)
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
        }
    }

    private var midOptions: [String] {
        ["220", "450", "800", "1.6k", "3.0k"]
    }

    private var dbFormat: (Double) -> String {
        { String(format: "%+.1f dB", $0) }
    }

    private func rigRow(
        title: String,
        value: String,
        on: Bool,
        loadTitle: String,
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let clear {
                    Button("Clear", action: clear)
                        .buttonStyle(StudioButton())
                }
                Button(loadTitle, action: load)
                    .buttonStyle(StudioButton())
            }
        }
    }
}
