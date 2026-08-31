import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var session: AmpSession

    private var inputs: [AudioDevice] { session.devices.filter(\.hasInput) }
    private var outputs: [AudioDevice] { session.devices.filter(\.hasOutput) }

    var body: some View {
        Form {
            Section("Audio") {
                Picker("Input", selection: $session.inputDeviceID) {
                    ForEach(inputs) { device in
                        Text(device.displayName).tag(device.id)
                    }
                }
                Picker("Input channel", selection: $session.inputChannel) {
                    Text("Channel 1 (Left / Default)").tag(0)
                    Text("Channel 2 (Right / Inst 2)").tag(1)
                    Text("Sum 1+2 (Mono mix)").tag(2)
                }
                .onChange(of: session.inputChannel) { _, ch in
                    session.setInputChannel(ch)
                }
                Picker("Output", selection: $session.outputDeviceID) {
                    ForEach(outputs) { device in
                        Text(device.displayName).tag(device.id)
                    }
                }
                Picker("Buffer", selection: $session.bufferSize) {
                    Text("64").tag(UInt32(64))
                    Text("128").tag(UInt32(128))
                    Text("256").tag(UInt32(256))
                    Text("512").tag(UInt32(512))
                    Text("1024").tag(UInt32(1024))
                }
                Picker("Sample rate", selection: $session.sampleRate) {
                    Text("Follow device").tag(0.0)
                    Text("44.1 kHz").tag(44100.0)
                    Text("48 kHz").tag(48000.0)
                    Text("96 kHz").tag(96000.0)
                }
                Button("Apply to hardware") {
                    session.applyLiveSettings()
                }
                Text(String(format: "Measured path: %.0f Hz, %d samples, about %.1f ms.", session.hardwareSampleRate, session.hardwareBuffer, session.latencyMs))
                    .foregroundStyle(AmpTheme.muted)
                    .font(AmpTheme.caption(12))
            }

            Section("External instrument input") {
                Text("A normal stereo splitter is output-only. Bass input requires a USB audio interface with an Instrument/Hi-Z socket, or a compatible CTIA TRRS guitar interface. A working analog input appears as External Microphone; its headphone side appears separately as External Headphones. Leave sample rate on Follow device.")
                    .font(AmpTheme.caption(12))
                    .foregroundStyle(AmpTheme.muted)
                if let hint = session.jackHint {
                    Text(hint)
                        .font(AmpTheme.caption(12))
                        .foregroundStyle(AmpTheme.warn)
                }
            }

            Section("Input diagnostics") {
                LabeledContent("Current input") {
                    Text(String(format: "%.1f dBFS RMS", session.inputRmsDb))
                        .font(AmpTheme.mono(12))
                }
                LabeledContent("Idle noise floor") {
                    Text(String(format: "%.1f dBFS", session.noiseFloorDb))
                        .font(AmpTheme.mono(12))
                }
                Text(session.audioDiagnostic)
                    .font(AmpTheme.caption(12))
                    .foregroundStyle(session.noiseFloorDb > -45 ? AmpTheme.warn : AmpTheme.muted)
                Text("For a useful reading, leave the bass connected and stop playing for one second. Move one plug at a time: crackling that follows movement is a physical cable or jack fault.")
                    .font(AmpTheme.caption(11))
                    .foregroundStyle(AmpTheme.faint)
            }

            Section("Amp") {
                Text("The default amp is xzyqrn Clean: your bass through a quiet preamp and the cabinet, with no NAM hiss. Load a .nam from tone3000.com only if you want a captured amp instead. Amp-only captures usually want the cabinet IR left on.")
                    .font(AmpTheme.caption(12))
                    .foregroundStyle(AmpTheme.muted)
            }

            Section("Recordings") {
                Text("Takes land in Application Support / xzyqrn amp / Recordings. The bundle ID stays com.herojay.Amplifier so microphone permission survives this rename.")
                    .font(AmpTheme.caption(12))
                    .foregroundStyle(AmpTheme.muted)
                Button("Open recordings folder") {
                    session.revealRecordingsFolder()
                }
            }
        }
        .formStyle(.grouped)
        .preferredColorScheme(.dark)
        .onAppear { session.refreshDevices() }
    }
}
