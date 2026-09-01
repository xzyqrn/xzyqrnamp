import SwiftUI

struct TransportBar: View {
    @EnvironmentObject private var session: AmpSession
    @State private var showTakes = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            singleRow
            wrappedRows
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 76)
        .background(AmpTheme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(AmpTheme.line).frame(height: 1)
        }
    }

    private var singleRow: some View {
        HStack(alignment: .center, spacing: 16) {
            beatSection.fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            sectionDivider
            recordSection.fixedSize(horizontal: true, vertical: false)
            sectionDivider
            Spacer(minLength: 8)
            extrasSection.fixedSize(horizontal: true, vertical: false)
        }
    }

    private var wrappedRows: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                beatSection
                Spacer(minLength: 8)
                extrasSection
            }
            HStack {
                Spacer(minLength: 0)
                recordSection
                Spacer(minLength: 0)
            }
        }
    }

    private var beatSection: some View {
        HStack(spacing: 12) {
            Button(action: session.toggleBeat) {
                Image(systemName: session.beatOn ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(session.beatOn ? AmpTheme.bg : AmpTheme.text)
                    .frame(width: 32, height: 32)
                    .background(session.beatOn ? AmpTheme.accent : AmpTheme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(session.beatOn ? "Stop beat" : "Play beat")

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Beat")
                Menu {
                    ForEach(BeatStyle.allCases) { style in
                        Button(style.title) { session.setBeatStyle(style) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(session.beatStyle.title)
                        Image(systemName: "chevron.down")
                    }
                    .font(AmpTheme.label(10))
                    .foregroundStyle(AmpTheme.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AmpTheme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Tempo")
                HStack(spacing: 7) {
                    Slider(
                        value: Binding(
                            get: { session.beatBPM },
                            set: { session.setBeatBPM($0) }
                        ),
                        in: 40...240,
                        step: 1
                    )
                    .tint(AmpTheme.accent)
                    .frame(width: 110)
                    Text("\(Int(session.beatBPM))")
                        .font(AmpTheme.mono(11, weight: .semibold))
                        .foregroundStyle(AmpTheme.text)
                        .frame(width: 28, alignment: .trailing)
                    Button("TAP") {
                        session.tapBeatTempo()
                    }
                    .buttonStyle(StudioButton())
                }
            }

            AmpKnob(
                value: $session.beatVolume,
                range: 0...1,
                label: "Vol",
                size: 36,
                format: { String(format: "%.0f%%", $0 * 100) },
                onChange: { session.setBeatVolume(session.beatVolume) }
            )
        }
    }

    private var recordSection: some View {
        HStack(spacing: 12) {
            Button(action: session.toggleRecord) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: session.isRecording ? 2 : 8, style: .continuous)
                        .fill(AmpTheme.danger)
                        .frame(width: session.isRecording ? 10 : 12, height: session.isRecording ? 10 : 12)
                    Text(session.isFinishingRecording ? "WAIT" : (session.isRecording ? "STOP" : "REC"))
                        .font(AmpTheme.label(11))
                        .tracking(1.4)
                }
                .foregroundStyle(AmpTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(session.isRecording ? AmpTheme.danger.opacity(0.22) : AmpTheme.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(session.isRecording ? AmpTheme.danger : AmpTheme.line, lineWidth: 1)
                        .allowsHitTesting(false)
                )
            }
            .buttonStyle(.plain)
            .disabled((!session.isRunning && !session.isRecording) || session.isFinishingRecording)
            .opacity(session.isRunning || session.isRecording || session.isFinishingRecording ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 6) {
                Text(session.isFinishingRecording ? "Finishing" : elapsed)
                    .font(AmpTheme.mono(16, weight: .semibold))
                    .foregroundStyle(session.isRecording ? AmpTheme.danger : AmpTheme.text)
                VUMeter(level: session.isRecording ? session.recordPeak : 0, clip: session.recordPeak > 0.95, label: "REC")
                    .frame(width: 140)
            }

            RecordModePicker(
                selection: Binding(
                    get: { session.recordMode },
                    set: { session.setRecordMode($0) }
                ),
                enabled: !session.isRecording && !session.isFinishingRecording
            )
        }
    }

    private var extrasSection: some View {
        HStack(spacing: 12) {
            LEDToggle(isOn: $session.recordBassOnly, title: "Bass only") {
                session.applyRecordSource()
            }
            .help("Off records everything playing to the selected output, including other apps. On records processed bass only. Applies to both audio and video takes.")

            Button {
                session.takes = RecordingStore.loadAll()
                showTakes.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                    Text("Takes")
                    Text("\(session.takes.count)")
                        .font(AmpTheme.mono(10))
                        .foregroundStyle(AmpTheme.faint)
                }
            }
            .buttonStyle(StudioButton())
            .popover(isPresented: $showTakes, arrowEdge: .top) {
                TakesList()
                    .environmentObject(session)
                    .frame(width: 380, height: 280)
            }
        }
    }

    private var elapsed: String {
        let t = session.recordElapsed
        let m = Int(t) / 60
        let s = Int(t) % 60
        let cs = Int((t - floor(t)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(AmpTheme.line)
            .frame(width: 1, height: 48)
    }
}

private struct TakesList: View {
    @EnvironmentObject private var session: AmpSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Takes")
                    .font(AmpTheme.display(14))
                    .foregroundStyle(AmpTheme.text)
                Spacer()
                Button("Folder") { session.revealRecordingsFolder() }
                    .buttonStyle(StudioButton())
            }
            if session.takes.isEmpty {
                Text("No recordings yet. Power on and hit REC.")
                    .font(AmpTheme.caption(12))
                    .foregroundStyle(AmpTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(session.takes) { take in
                        HStack {
                            Image(systemName: take.isVideo ? "video.fill" : "waveform")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(take.isVideo ? AmpTheme.accent : AmpTheme.muted)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(take.name)
                                    .font(AmpTheme.caption(12))
                                    .foregroundStyle(AmpTheme.text)
                                    .lineLimit(1)
                                Text(take.isVideo
                                     ? String(format: "Video · %.1f s", take.duration)
                                     : String(format: "%.1f s", take.duration))
                                    .font(AmpTheme.mono(10))
                                    .foregroundStyle(AmpTheme.faint)
                            }
                            Spacer()
                            Button {
                                if session.playingTakeID == take.id {
                                    session.stopTakePlayback()
                                } else {
                                    session.playTake(take)
                                }
                            } label: {
                                Image(systemName: session.playingTakeID == take.id ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.plain)
                            Button { session.revealTake(take) } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                            Button { session.exportTake(take) } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.plain)
                            Button { session.deleteTake(take) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AmpTheme.danger)
                        }
                        .listRowBackground(AmpTheme.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(12)
        .background(AmpTheme.bg)
        .preferredColorScheme(.dark)
    }
}
