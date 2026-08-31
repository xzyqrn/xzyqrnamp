import SwiftUI

struct PracticeLabView: View {
    @EnvironmentObject private var amp: AmpSession
    @EnvironmentObject private var lessons: BassMethodLibrary
    @EnvironmentObject private var tabs: TabLibraryStore
    @EnvironmentObject private var practice: PracticeSessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                practiceHeader
                HStack(alignment: .top, spacing: 14) {
                    rigCard
                    grooveCard
                    tunerCard
                }
                HStack(alignment: .top, spacing: 14) {
                    sourceCard
                    coachCard
                    recordingCard
                }
                historyCard
            }
            .padding(16)
        }
        .background(AmpTheme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 720)
    }

    private var practiceHeader: some View {
        StudioCard {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PRACTICE LAB")
                        .font(AmpTheme.display(22, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(AmpTheme.text)
                    Text("Rig, groove, lesson, tuner, recording, and progress in one session")
                        .font(AmpTheme.caption(11))
                        .foregroundStyle(AmpTheme.muted)
                }
                Spacer()
                if let activeSince = practice.activeSince {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(elapsed(timeline.date.timeIntervalSince(activeSince)))
                            .font(AmpTheme.mono(22, weight: .semibold))
                            .foregroundStyle(AmpTheme.accent)
                    }
                    Button("Finish & save") { practice.finish(using: amp) }
                        .buttonStyle(StudioButton(prominent: true))
                    Button("Discard") { practice.discard() }
                        .buttonStyle(StudioButton())
                } else {
                    Button("Start session") { practice.start() }
                        .buttonStyle(StudioButton(prominent: true))
                }
            }
        }
    }

    private var rigCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Rig")
                Picker("", selection: $amp.selectedPresetID) {
                    ForEach(amp.presets) { preset in Text(preset.name).tag(preset.id) }
                }
                .labelsHidden()
                .onChange(of: amp.selectedPresetID) { _, id in
                    if let preset = amp.presets.first(where: { $0.id == id }) { amp.applyPreset(preset) }
                }
                HStack {
                    Button(amp.isRunning ? "Power off" : "Power on") { amp.togglePower() }
                        .buttonStyle(StudioButton(prominent: !amp.isRunning))
                    LEDToggle(isOn: $amp.bypass, title: amp.bypass ? "Bypass" : "Live") { amp.pushAllParams() }
                }
                HStack {
                    LevelPills(input: amp.inputPeak, output: amp.outputPeak, inClip: amp.inputClip, outClip: amp.outputClip)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var grooveCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Groove")
                Picker("", selection: $amp.beatStyle) {
                    ForEach(BeatStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .labelsHidden()
                .onChange(of: amp.beatStyle) { _, style in amp.setBeatStyle(style) }
                HStack {
                    Slider(
                        value: Binding(get: { amp.beatBPM }, set: { amp.setBeatBPM($0) }),
                        in: 40...240,
                        step: 1
                    )
                    .tint(AmpTheme.accent)
                    Text("\(Int(amp.beatBPM)) BPM")
                        .font(AmpTheme.mono(11))
                        .frame(width: 70, alignment: .trailing)
                }
                HStack {
                    Button(amp.beatOn ? "Stop beat" : "Play beat") { amp.toggleBeat() }
                        .buttonStyle(StudioButton(prominent: amp.beatOn))
                    Button("Tap") { amp.tapBeatTempo() }
                        .buttonStyle(StudioButton())
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tunerCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "Tuner")
                    Spacer(minLength: 0)
                    LEDToggle(isOn: $amp.tunerMute, title: "Mute", destructive: true) {
                        amp.pushAllParams()
                    }
                }
                TunerDisplay(hz: amp.tunerHz, confidence: amp.tunerConfidence, isRunning: amp.isRunning)
                Text(amp.isRunning ? "Listening to your live bass input" : "Power on the rig to tune")
                    .font(AmpTheme.caption(10))
                    .foregroundStyle(AmpTheme.faint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sourceCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Practice source")
                Picker("", selection: $practice.source) {
                    Text("Free practice").tag("Free practice")
                    Text("Bass Method").tag("Bass Method")
                    Text("Saved tab").tag("Saved tab")
                }
                .labelsHidden()
                HStack {
                    Button("Open lesson") { practice.source = "Bass Method"; openWindow(id: "bass-method") }
                        .buttonStyle(StudioButton())
                    Button("Open tabs") { practice.source = "Saved tab"; openWindow(id: "tabs") }
                        .buttonStyle(StudioButton())
                }
                Text("\(lessons.completedTrackIDs.count) lesson exercises completed · \(tabs.items.count) tabs saved")
                    .font(AmpTheme.caption(10))
                    .foregroundStyle(AmpTheme.muted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var coachCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Tempo coach")
                LEDToggle(isOn: $amp.practiceAutoIncrease, title: "Auto ladder")
                HStack {
                    Text("Increase")
                        .font(AmpTheme.caption(11))
                        .foregroundStyle(AmpTheme.muted)
                    Slider(value: $amp.practiceIncreaseStep, in: 1...15, step: 1)
                        .tint(AmpTheme.accent)
                    Text("+\(Int(amp.practiceIncreaseStep))")
                        .font(AmpTheme.mono(10))
                }
                Button("Round complete") {
                    if amp.practiceAutoIncrease { amp.increasePracticeTempo() }
                }
                .buttonStyle(StudioButton(prominent: amp.practiceAutoIncrease))
                Text("Use after a clean repetition to advance the tempo ladder.")
                    .font(AmpTheme.caption(9))
                    .foregroundStyle(AmpTheme.faint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Take")
                Button(amp.isRecording ? "Stop recording" : "Record practice") { amp.toggleRecord() }
                    .buttonStyle(StudioButton(prominent: amp.isRecording))
                    .disabled(!amp.isRunning && !amp.isRecording)
                LEDToggle(isOn: $amp.recordBassOnly, title: "Bass only") {
                    amp.applyRecordSource()
                }
                .help("Off records everything playing to the selected output, including other apps. On records processed bass only.")
                Text(amp.recordBassOnly
                     ? "Records processed bass only — no click, no other apps."
                     : "Records everything playing to the selected output, including other apps.")
                    .font(AmpTheme.caption(9))
                    .foregroundStyle(AmpTheme.faint)
                Text("\(amp.takes.count) saved takes")
                    .font(AmpTheme.caption(10))
                    .foregroundStyle(AmpTheme.muted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var historyCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Session notes & history")
                TextEditor(text: $practice.notes)
                    .font(AmpTheme.caption(12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 74)
                    .background(AmpTheme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if practice.logs.isEmpty {
                    Text("Finished practice sessions will appear here.")
                        .font(AmpTheme.caption(10))
                        .foregroundStyle(AmpTheme.faint)
                } else {
                    ForEach(practice.logs.prefix(6)) { log in
                        HStack {
                            Text(log.date, style: .date)
                            Text(log.source)
                            Spacer()
                            Text("\(log.beatStyle) · \(log.bpm) BPM · \(elapsed(log.duration))")
                        }
                        .font(AmpTheme.caption(10))
                        .foregroundStyle(AmpTheme.muted)
                    }
                }
            }
        }
    }

    private func elapsed(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
