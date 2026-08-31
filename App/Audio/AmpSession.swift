import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AmpSession: ObservableObject {
    @Published var isRunning = false
    @Published var status = "Off"
    @Published var errorMessage: String?
    @Published var devices: [AudioDevice] = []
    @Published var inputDeviceID: AudioDeviceID = CoreAudioDevices.defaultInputID()
    @Published var outputDeviceID: AudioDeviceID = CoreAudioDevices.defaultOutputID()
    @Published var bufferSize: UInt32 = 128
    /// 0 means Channel 1 (Default / Left), 1 means Channel 2 (Inst 2 / Right), 2 means Sum 1+2.
    @Published var inputChannel: Int = 0
    /// 0 means follow whatever the jack / interface is already using.
    @Published var sampleRate: Double = 0
    @Published var hardwareSampleRate: Double = 48000
    @Published var hardwareBuffer: UInt32 = 256
    @Published var latencyMs: Double = 0

    @Published var inputGainDb: Double = 3
    @Published var outputGainDb: Double = 0
    @Published var gateThresholdDb: Double = -40
    @Published var bassDb: Double = 1.5
    @Published var midDb: Double = 0
    @Published var trebleDb: Double = -1.5
    @Published var midFreqIndex: Int = 1 // 0: 220Hz, 1: 450Hz, 2: 800Hz, 3: 1.6kHz, 4: 3.0kHz
    @Published var ultraLoOn = false
    @Published var ultraHiOn = false
    @Published var selectedCabinet = "bass-4x10.wav"
    @Published var gateOn = true
    @Published var namOn = true
    @Published var irOn = true
    @Published var eqOn = true
    @Published var bypass = false

    static let availableCabinets: [(id: String, name: String)] = [
        ("bass-8x10.wav", "Ampeg SVT 8x10"),
        ("bass-4x10.wav", "Darkglass 4x10"),
        ("bass-2x12.wav", "Mesa Boogie 2x12"),
        ("bass-1x15.wav", "Aguilar DB 1x15"),
    ]

    @Published var compOn = true
    @Published var compThresholdDb: Double = -24
    @Published var compRatio: Double = 4
    @Published var compMakeupDb: Double = 2

    @Published var driveOn = false
    @Published var driveAmount: Double = 0.35
    @Published var driveTone: Double = 0.5
    @Published var driveMix: Double = 0.55

    @Published var octaverOn = false
    @Published var octaverMix: Double = 0.35
    @Published var octaverTone: Double = 0.45

    @Published var envelopeOn = false
    @Published var envelopeSensitivity: Double = 0.55
    @Published var envelopeResonance: Double = 0.45
    @Published var envelopeMix: Double = 0.65

    @Published var utilityFilterOn = true
    @Published var highPassHz: Double = 32
    @Published var lowPassHz: Double = 12000

    @Published var chorusOn = false
    @Published var chorusRate: Double = 0.8
    @Published var chorusDepth: Double = 0.4
    @Published var chorusMix: Double = 0.35

    @Published var delayOn = false
    @Published var delayTimeMs: Double = 180
    @Published var delayFeedback: Double = 0.28
    @Published var delayMix: Double = 0.22

    @Published var reverbOn = false
    @Published var reverbSize: Double = 0.4
    @Published var reverbDamp: Double = 0.45
    @Published var reverbMix: Double = 0.2

    @Published var namName = "xzyqrn Clean"
    @Published var irName = "No cabinet"
    @Published var namPath: URL?
    @Published var irPath: URL?

    @Published var inputPeak: Double = 0
    @Published var outputPeak: Double = 0
    @Published var inputRmsDb: Double = -120
    @Published var noiseFloorDb: Double = -120
    @Published var audioDiagnostic = "Power on, then stop playing for a moment to measure the input."
    @Published var inputClip = false
    @Published var outputClip = false
    @Published var tunerHz: Double = 0
    @Published var tunerConfidence: Double = 0

    @Published var presets: [AmpPreset] = AmpPreset.bundled
    @Published var selectedPresetID: String = AmpPreset.bundled.first?.id ?? "practice"

    @Published var beatStyle: BeatStyle = .rock
    @Published var beatBPM: Double = 100
    @Published var beatOn = false
    @Published var beatVolume: Double = 0.5
    @Published var countInBars: Int = 1
    @Published var practiceAutoIncrease = false
    @Published var practiceIncreaseStep: Double = 5
    private var lastTempoTap: TimeInterval?

    @Published var isRecording = false
    @Published var recordElapsed: TimeInterval = 0
    @Published var recordPeak: Double = 0
    @Published var recordBassOnly = false
    @Published var takes: [RecordingTake] = []
    @Published var playingTakeID: String?

    let beatPlayer = BeatPlayer()
    let recorder = Recorder()
    private var takePlayer: AVAudioPlayer?

    private var engine = AVAudioEngine()
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?
    private var renderState: AudioRenderState?
    private var meterTimer: Timer?
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var configurationObserver: NSObjectProtocol?
    private var reconnectTask: Task<Void, Never>?
    private var currentNAMBookmark: Data?
    private var currentIRBookmark: Data?
    private var isStarting = false
    private var lastFIFOUnderflowFrames: UInt64 = 0
    private var lastFIFOOverflowFrames: UInt64 = 0
    private let processor = AmpProcessorShared()!

    static let cleanAmpName = "xzyqrn Clean"
    private static let lastNAMBookmarkKey = "xzyqrn.lastNAMBookmark"
    private static let lastIRBookmarkKey = "xzyqrn.lastIRBookmark"

    var inputLabel: String {
        devices.first(where: { $0.id == inputDeviceID })?.displayName ?? "System input"
    }

    var outputLabel: String {
        devices.first(where: { $0.id == outputDeviceID })?.displayName ?? "System output"
    }

    var jackHint: String? {
        let analogIn = devices.first(where: \.isAnalogInput)
        let analogOut = devices.first(where: \.isAnalogOutput)
        if analogIn == nil {
            if analogOut != nil {
                return "Output-only adapter detected. A stereo 3.5 mm-to-two-instrument-plug cable carries left/right playback, not an input. Use a Hi-Z USB audio interface, or a CTIA TRRS guitar interface that macOS exposes as External Microphone."
            }
            if let selected = devices.first(where: { $0.id == inputDeviceID }),
               selected.hasInput,
               !selected.isLaptopMic {
                return nil
            }
            return "No external input is detected. Connect a USB audio interface with an instrument/Hi-Z input, or a compatible CTIA TRRS guitar interface."
        }
        if let selected = devices.first(where: { $0.id == inputDeviceID }), !selected.isAnalogInput {
            return "The analog input is “\(analogIn!.name)”, not \(selected.name)."
        }
        if analogOut != nil, let selected = devices.first(where: { $0.id == outputDeviceID }), !selected.isAnalogOutput {
            return "Output is currently \(selected.name). Choose \(analogOut!.name) for headphones, or keep the Mac output if that is intentional."
        }
        return nil
    }

    init() {
        refreshDevices()
        adoptPreferredDevices()
        pushAllParams()
        takes = RecordingStore.loadAll()
        hardwareListener = CoreAudioDevices.addHardwareListener { [weak self] in
            guard let self else { return }
            self.handleHardwareChange()
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let changedEngine = notification.object as? AVAudioEngine,
                      changedEngine === self.engine,
                      self.isRunning,
                      !self.isStarting else { return }
                self.scheduleReconnect()
            }
        }
    }

    deinit {
        reconnectTask?.cancel()
        if let hardwareListener {
            CoreAudioDevices.removeHardwareListener(hardwareListener)
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func refreshDevices() {
        devices = CoreAudioDevices.list()
        if devices.first(where: { $0.id == inputDeviceID && $0.hasInput }) == nil {
            inputDeviceID = CoreAudioDevices.preferredInputID(in: devices)
        }
        if devices.first(where: { $0.id == outputDeviceID && $0.hasOutput }) == nil {
            outputDeviceID = CoreAudioDevices.preferredOutputID(in: devices)
        }
    }

    private func handleHardwareChange() {
        let previousDevices = devices
        let previousInputID = inputDeviceID
        let previousOutputID = outputDeviceID
        let hadAnalogInput = previousDevices.contains(where: \.isAnalogInput)
        let hadAnalogOutput = previousDevices.contains(where: \.isAnalogOutput)

        refreshDevices()

        // Auto-adopt a newly connected analog jack only when the user was on
        // the laptop's built-in path. Never replace an explicitly chosen USB
        // or other external interface.
        if !hadAnalogInput,
           let oldInput = previousDevices.first(where: { $0.id == previousInputID }),
           oldInput.isLaptopMic,
           let analogInput = devices.first(where: \.isAnalogInput) {
            inputDeviceID = analogInput.id
        }
        if !hadAnalogOutput,
           let oldOutput = previousDevices.first(where: { $0.id == previousOutputID }),
           oldOutput.isBuiltInSpeaker,
           let analogOutput = devices.first(where: \.isAnalogOutput) {
            outputDeviceID = analogOutput.id
        }

        guard isRunning, !isStarting else { return }
        if previousInputID != inputDeviceID
            || previousOutputID != outputDeviceID
            || !engine.isRunning {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                try Task.checkCancellation()
                guard let self, !self.isStarting else { return }
                self.isStarting = true
                self.status = "Reconnecting audio…"
                defer { self.isStarting = false }
                self.refreshDevices()
                try self.validateSelectedDevices()
                try await self.startEngine()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.stopEngineOnly()
                self.errorMessage = Self.describeAudioError(error)
                self.status = "Audio disconnected"
            }
        }
    }

    /// Start with the user's external system route, falling back to the analog
    /// combo jack and finally to built-in devices.
    private func adoptPreferredDevices() {
        inputDeviceID = CoreAudioDevices.preferredInputID(in: devices)
        outputDeviceID = CoreAudioDevices.preferredOutputID(in: devices)
        let inRate = CoreAudioDevices.currentSampleRate(device: inputDeviceID)
        if inRate > 1 {
            hardwareSampleRate = inRate
        }
        let hwBuffer = CoreAudioDevices.currentBufferFrameSize(device: outputDeviceID)
        if hwBuffer > 0 {
            bufferSize = CoreAudioDevices.clampBuffer(bufferSize, device: outputDeviceID)
        }
    }

    func requestPermissionAndBoot() async {
        guard !isStarting else { return }
        isStarting = true
        status = "Connecting…"
        defer { isStarting = false }

        // AVAudioApplication.requestRecordPermission can leave its async
        // continuation suspended on macOS after an ad-hoc development rebuild,
        // even when TCC has already granted this bundle access. Consult the
        // established capture authorization first and prompt only when needed.
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            // Development-signed macOS builds can present the prompt while
            // never calling this completion handler. Let Core Audio continue
            // opening the route; the request remains active and the engine
            // reports a normal error if access ultimately is not available.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            granted = true
        case .denied, .restricted:
            granted = false
        @unknown default:
            granted = false
        }
        if !granted {
            errorMessage = "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
            status = "No microphone access"
            return
        }
        loadBundledDefaultsIfNeeded()
        do {
            try await start()
        } catch {
            errorMessage = Self.describeAudioError(error)
            status = "Couldn't start audio"
        }
    }

    func togglePower() {
        guard !isStarting else { return }
        if isRunning {
            stop()
        } else {
            Task { await requestPermissionAndBoot() }
        }
    }

    func start() async throws {
        refreshDevices()
        try validateSelectedDevices()
        try await startEngine()
    }

    private func startEngine() async throws {
        stopEngineOnly()
        try applyHardware()

        // Core Audio publishes default-device changes asynchronously. A fresh
        // engine created after that notification avoids retaining device 0 or
        // the previous route inside its AUHAL.
        try await Task.sleep(nanoseconds: 120_000_000)
        try Task.checkCancellation()
        engine = AVAudioEngine()

        let (inputFormat, outputFormat) = try resolvedIOFormats()
        let dspRate = inputFormat.sampleRate > 1 ? inputFormat.sampleRate : outputFormat.sampleRate
        recorder.prepare(sampleRate: dspRate)
        beatPlayer.select(style: beatStyle, bpm: beatBPM)
        beatPlayer.volume = Float(beatVolume)
        beatPlayer.playing = beatOn

        let state = AudioRenderState(
            processor: processor,
            beatPlayer: beatPlayer,
            recorder: recorder,
            preRollFrames: Int(max(bufferSize * 2, 256)),
            engineSampleRate: dspRate,
            inputChannel: inputChannel
        )
        renderState = state

        let sink = AVAudioSinkNode { _, frameCount, audioBufferList in
            state.mixdown(audioBufferList, frames: Int(frameCount))
            return noErr
        }
        let source = AVAudioSourceNode(format: outputFormat) { _, _, frameCount, audioBufferList in
            state.render(audioBufferList, frames: Int(frameCount))
            return noErr
        }

        engine.attach(sink)
        engine.attach(source)
        sinkNode = sink
        sourceNode = source

        engine.connect(engine.inputNode, to: sink, format: inputFormat)
        // This rig has exactly one playback source. The AVAudioEngine main
        // mixer initializes at 44.1 kHz on some analog-jack routes and then
        // inserts 48 -> 44.1 -> 48 conversion despite 48 kHz hardware. Going
        // directly to the output node keeps the entire live path at one rate.
        engine.connect(source, to: engine.outputNode, format: outputFormat)

        AmpProcessorReset(processor, dspRate, Int32(max(bufferSize, 512)))
        if let namPath { _ = loadNAM(url: namPath) }
        if let irPath { _ = loadIR(url: irPath) }
        pushAllParams()

        engine.prepare()
        try engine.start()
        isRunning = true
        hardwareSampleRate = dspRate
        hardwareBuffer = CoreAudioDevices.currentBufferFrameSize(device: outputDeviceID)
        if hardwareBuffer == 0 {
            hardwareBuffer = CoreAudioDevices.currentBufferFrameSize(device: inputDeviceID)
        }
        if hardwareBuffer == 0 { hardwareBuffer = bufferSize }
        latencyMs = 1000.0 * Double(hardwareBuffer * 2) / max(hardwareSampleRate, 1)
        status = String(
            format: "Live · %@ · %.0f Hz · %d samples",
            devices.first(where: { $0.id == inputDeviceID })?.name ?? "Input",
            hardwareSampleRate,
            hardwareBuffer
        )
        errorMessage = nil
        startMetering()
    }

    private func resolvedIOFormats() throws -> (AVAudioFormat, AVAudioFormat) {
        _ = engine.outputNode
        _ = engine.inputNode

        let inputHardwareFormat = engine.inputNode.inputFormat(forBus: 0)
        let inputNodeFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputHardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        if inputHardwareFormat.sampleRate < 1 || inputHardwareFormat.channelCount < 1
            || inputNodeFormat.sampleRate < 1 || inputNodeFormat.channelCount < 1 {
            throw NSError(
                domain: "xzyqrn amp",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No microphone stream yet. Analog iRig shows up as External Microphone. Plug it into the Mac headphone jack, set System Settings → Sound → Input to External Microphone, then power on."]
            )
        }
        if outputHardwareFormat.sampleRate < 1 || outputHardwareFormat.channelCount < 1 {
            throw NSError(
                domain: "xzyqrn amp",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The selected output has no active audio stream. Reconnect it, then choose it again in xzyqrn amp Settings."]
            )
        }
        if abs(inputNodeFormat.sampleRate - outputHardwareFormat.sampleRate) > 1 {
            throw NSError(
                domain: "xzyqrn amp",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Input is running at \(Int(inputNodeFormat.sampleRate)) Hz but output is \(Int(outputHardwareFormat.sampleRate)) Hz. Choose Follow device or set both devices to the same sample rate."]
            )
        }
        guard let inputFormat = AVAudioFormat(
            standardFormatWithSampleRate: inputNodeFormat.sampleRate,
            channels: inputNodeFormat.channelCount
        ), let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: outputHardwareFormat.sampleRate,
            channels: outputHardwareFormat.channelCount
        ) else {
            throw NSError(
                domain: "xzyqrn amp",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Core Audio couldn't create a stable floating-point stream for this route."]
            )
        }
        return (inputFormat, outputFormat)
    }

    func stop() {
        stopEngineOnly()
        status = "Off"
    }

    func setInputChannel(_ channel: Int) {
        inputChannel = channel
        renderState?.inputChannel = channel
    }

    func applyLiveSettings() {
        guard !isStarting else { return }
        Task {
            isStarting = true
            status = "Applying audio route…"
            defer { isStarting = false }
            do {
                refreshDevices()
                try validateSelectedDevices()
                try await startEngine()
            } catch {
                errorMessage = Self.describeAudioError(error)
                status = "Couldn't restart audio"
            }
        }
    }

    func pushAllParams() {
        AmpProcessorSetInputGainDb(processor, Float(inputGainDb))
        AmpProcessorSetOutputGainDb(processor, Float(outputGainDb))
        AmpProcessorSetGateThresholdDb(processor, Float(gateThresholdDb))
        AmpProcessorSetBassDb(processor, Float(bassDb))
        AmpProcessorSetMidDb(processor, Float(midDb))
        AmpProcessorSetTrebleDb(processor, Float(trebleDb))
        AmpProcessorSetMidFreqIndex(processor, Int32(midFreqIndex))
        AmpProcessorSetUltraLoOn(processor, ultraLoOn)
        AmpProcessorSetUltraHiOn(processor, ultraHiOn)
        AmpProcessorSetGateOn(processor, gateOn)
        AmpProcessorSetNAMOn(processor, namOn)
        AmpProcessorSetIROn(processor, irOn)
        AmpProcessorSetEQOn(processor, eqOn)
        AmpProcessorSetBypass(processor, bypass)
        AmpProcessorSetCompOn(processor, compOn)
        AmpProcessorSetCompThresholdDb(processor, Float(compThresholdDb))
        AmpProcessorSetCompRatio(processor, Float(compRatio))
        AmpProcessorSetCompMakeupDb(processor, Float(compMakeupDb))
        AmpProcessorSetDriveOn(processor, driveOn)
        AmpProcessorSetDriveAmount(processor, Float(driveAmount))
        AmpProcessorSetDriveTone(processor, Float(driveTone))
        AmpProcessorSetDriveMix(processor, Float(driveMix))
        AmpProcessorSetOctaverOn(processor, octaverOn)
        AmpProcessorSetOctaverMix(processor, Float(octaverMix))
        AmpProcessorSetOctaverTone(processor, Float(octaverTone))
        AmpProcessorSetEnvelopeOn(processor, envelopeOn)
        AmpProcessorSetEnvelopeSensitivity(processor, Float(envelopeSensitivity))
        AmpProcessorSetEnvelopeResonance(processor, Float(envelopeResonance))
        AmpProcessorSetEnvelopeMix(processor, Float(envelopeMix))
        AmpProcessorSetUtilityFilterOn(processor, utilityFilterOn)
        AmpProcessorSetHighPassHz(processor, Float(highPassHz))
        AmpProcessorSetLowPassHz(processor, Float(lowPassHz))
        AmpProcessorSetChorusOn(processor, chorusOn)
        AmpProcessorSetChorusRate(processor, Float(chorusRate))
        AmpProcessorSetChorusDepth(processor, Float(chorusDepth))
        AmpProcessorSetChorusMix(processor, Float(chorusMix))
        AmpProcessorSetDelayOn(processor, delayOn)
        AmpProcessorSetDelayTimeMs(processor, Float(delayTimeMs))
        AmpProcessorSetDelayFeedback(processor, Float(delayFeedback))
        AmpProcessorSetDelayMix(processor, Float(delayMix))
        AmpProcessorSetReverbOn(processor, reverbOn)
        AmpProcessorSetReverbSize(processor, Float(reverbSize))
        AmpProcessorSetReverbDamp(processor, Float(reverbDamp))
        AmpProcessorSetReverbMix(processor, Float(reverbMix))
        beatPlayer.select(style: beatStyle, bpm: beatBPM)
        beatPlayer.volume = Float(beatVolume)
        beatPlayer.playing = beatOn && isRunning
        recorder.recordBassOnly = recordBassOnly
    }

    @discardableResult
    func loadNAM(url: URL) -> Bool {
        if Self.isBundledCleanNAM(url.lastPathComponent) {
            useCleanAmp()
            return true
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var err = [CChar](repeating: 0, count: 512)
        let ok = AmpProcessorLoadNAM(processor, url.path, &err, Int32(err.count))
        if ok {
            namPath = url
            namName = url.deletingPathExtension().lastPathComponent
            rememberExternalResource(url, kind: .nam)
            errorMessage = nil
        } else {
            let message = String(cString: err)
            errorMessage = message.isEmpty ? "Couldn't load that .nam capture." : message
        }
        return ok
    }

    @discardableResult
    func loadIR(url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: url)
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                errorMessage = "That IR file is empty."
                return false
            }
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData else { return false }
            let n = Int(buffer.frameLength)
            var mono = [Float](repeating: 0, count: n)
            let chCount = Int(buffer.format.channelCount)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<chCount { sum += channels[c][i] }
                mono[i] = sum / Float(max(chCount, 1))
            }
            let ok = AmpProcessorLoadIR(processor, mono, Int32(n), file.processingFormat.sampleRate)
            if ok {
                irPath = url
                irName = url.deletingPathExtension().lastPathComponent
                rememberExternalResource(url, kind: .ir)
                errorMessage = nil
            } else {
                errorMessage = "Couldn't load that cabinet IR."
            }
            return ok
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func unloadNAM() {
        AmpProcessorUnloadNAM(processor)
        namPath = nil
        namName = Self.cleanAmpName
        currentNAMBookmark = nil
        UserDefaults.standard.removeObject(forKey: Self.lastNAMBookmarkKey)
    }

    func useCleanAmp() {
        unloadNAM()
        namOn = true
        pushAllParams()
    }

    static func isBundledCleanNAM(_ file: String) -> Bool {
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent.lowercased()
        return name.isEmpty || name == "clean-bypass" || name == "xzyqrn-clean" || name == "xzyqrn clean"
    }

    func unloadIR() {
        AmpProcessorUnloadIR(processor)
        irPath = nil
        irName = "No cabinet"
        currentIRBookmark = nil
        UserDefaults.standard.removeObject(forKey: Self.lastIRBookmarkKey)
    }

    func clearClips() {
        AmpProcessorClearClips(processor)
        inputClip = false
        outputClip = false
    }

    func applyPreset(_ preset: AmpPreset) {
        selectedPresetID = preset.id
        inputGainDb = preset.inputGainDb
        outputGainDb = preset.outputGainDb
        gateThresholdDb = preset.gateThresholdDb
        bassDb = preset.bassDb
        midDb = preset.midDb
        trebleDb = preset.trebleDb
        gateOn = preset.gateOn
        namOn = preset.namOn
        irOn = preset.irOn
        eqOn = preset.eqOn
        compOn = preset.compOn
        compThresholdDb = preset.compThresholdDb
        compRatio = preset.compRatio
        compMakeupDb = preset.compMakeupDb
        driveOn = preset.driveOn
        driveAmount = preset.driveAmount
        driveTone = preset.driveTone
        driveMix = preset.driveMix
        octaverOn = preset.octaverOn
        octaverMix = preset.octaverMix
        octaverTone = preset.octaverTone
        envelopeOn = preset.envelopeOn
        envelopeSensitivity = preset.envelopeSensitivity
        envelopeResonance = preset.envelopeResonance
        envelopeMix = preset.envelopeMix
        utilityFilterOn = preset.utilityFilterOn
        highPassHz = preset.highPassHz
        lowPassHz = preset.lowPassHz
        chorusOn = preset.chorusOn
        chorusRate = preset.chorusRate
        chorusDepth = preset.chorusDepth
        chorusMix = preset.chorusMix
        delayOn = preset.delayOn
        delayTimeMs = preset.delayTimeMs
        delayFeedback = preset.delayFeedback
        delayMix = preset.delayMix
        reverbOn = preset.reverbOn
        reverbSize = preset.reverbSize
        reverbDamp = preset.reverbDamp
        reverbMix = preset.reverbMix
        midFreqIndex = preset.midFreqIndex
        ultraLoOn = preset.ultraLoOn
        ultraHiOn = preset.ultraHiOn
        selectedCabinet = preset.irFile.isEmpty ? "bass-4x10.wav" : preset.irFile
        pushAllParams()
        if let bookmark = preset.namBookmark,
           let url = resolveBookmark(bookmark, refreshKey: Self.lastNAMBookmarkKey) {
            _ = loadNAM(url: url)
        } else if Self.isBundledCleanNAM(preset.namFile) || preset.namFile.isEmpty {
            unloadNAM()
            pushAllParams()
        } else if let nam = bundledURL(preset.namFile, ext: "nam", sub: "Models") {
            _ = loadNAM(url: nam)
        }
        if let bookmark = preset.irBookmark,
           let url = resolveBookmark(bookmark, refreshKey: Self.lastIRBookmarkKey) {
            _ = loadIR(url: url)
        } else if let ir = bundledURL(preset.irFile, ext: "wav", sub: "IRs") {
            _ = loadIR(url: ir)
        }
    }

    func selectCabinetNamed(_ name: String) {
        selectedCabinet = name
        if let ir = bundledURL(name, ext: "wav", sub: "IRs") {
            _ = loadIR(url: ir)
        }
    }

    func savePreset(named name: String) {
        let preset = AmpPreset(
            id: UUID().uuidString,
            name: name,
            inputGainDb: inputGainDb,
            outputGainDb: outputGainDb,
            gateThresholdDb: gateThresholdDb,
            bassDb: bassDb,
            midDb: midDb,
            trebleDb: trebleDb,
            gateOn: gateOn,
            namOn: namOn,
            irOn: irOn,
            eqOn: eqOn,
            namFile: namPath?.lastPathComponent ?? "",
            irFile: irPath?.lastPathComponent ?? selectedCabinet,
            namBookmark: currentNAMBookmark,
            irBookmark: currentIRBookmark,
            compOn: compOn,
            compThresholdDb: compThresholdDb,
            compRatio: compRatio,
            compMakeupDb: compMakeupDb,
            driveOn: driveOn,
            driveAmount: driveAmount,
            driveTone: driveTone,
            driveMix: driveMix,
            octaverOn: octaverOn,
            octaverMix: octaverMix,
            octaverTone: octaverTone,
            envelopeOn: envelopeOn,
            envelopeSensitivity: envelopeSensitivity,
            envelopeResonance: envelopeResonance,
            envelopeMix: envelopeMix,
            utilityFilterOn: utilityFilterOn,
            highPassHz: highPassHz,
            lowPassHz: lowPassHz,
            chorusOn: chorusOn,
            chorusRate: chorusRate,
            chorusDepth: chorusDepth,
            chorusMix: chorusMix,
            delayOn: delayOn,
            delayTimeMs: delayTimeMs,
            delayFeedback: delayFeedback,
            delayMix: delayMix,
            reverbOn: reverbOn,
            reverbSize: reverbSize,
            reverbDamp: reverbDamp,
            reverbMix: reverbMix,
            midFreqIndex: midFreqIndex,
            ultraLoOn: ultraLoOn,
            ultraHiOn: ultraHiOn
        )
        PresetStore.save(preset)
        presets = AmpPreset.bundled + PresetStore.loadAll()
        selectedPresetID = preset.id
    }

    private func loadBundledDefaultsIfNeeded() {
        presets = AmpPreset.bundled + PresetStore.loadAll()
        if namPath == nil {
            if let bookmark = UserDefaults.standard.data(forKey: Self.lastNAMBookmarkKey),
               let url = resolveBookmark(bookmark, refreshKey: Self.lastNAMBookmarkKey),
               loadNAM(url: url) {
                // Restored the last external capture.
            } else {
                unloadNAM()
            }
        }
        if irPath == nil {
            if let bookmark = UserDefaults.standard.data(forKey: Self.lastIRBookmarkKey),
               let url = resolveBookmark(bookmark, refreshKey: Self.lastIRBookmarkKey),
               loadIR(url: url) {
                // Restored the last external cabinet.
            } else if let url = bundledURL("bass-4x10", ext: "wav", sub: "IRs") {
                _ = loadIR(url: url)
            }
        }
    }

    private enum ExternalResourceKind {
        case nam
        case ir
    }

    private func rememberExternalResource(_ url: URL, kind: ExternalResourceKind) {
        let bookmark: Data?
        if isBundledResource(url) {
            bookmark = nil
        } else {
            bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        let key: String
        switch kind {
        case .nam:
            currentNAMBookmark = bookmark
            key = Self.lastNAMBookmarkKey
        case .ir:
            currentIRBookmark = bookmark
            key = Self.lastIRBookmarkKey
        }
        if let bookmark {
            UserDefaults.standard.set(bookmark, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func resolveBookmark(_ data: Data, refreshKey: String? = nil) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            if let refreshKey { UserDefaults.standard.removeObject(forKey: refreshKey) }
            return nil
        }
        if stale,
           let refreshed = try? url.bookmarkData(
               options: .withSecurityScope,
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ), let refreshKey {
            UserDefaults.standard.set(refreshed, forKey: refreshKey)
        }
        return url
    }

    private func isBundledResource(_ url: URL) -> Bool {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(bundlePath)
    }

    private func bundledURL(_ name: String, ext: String, sub: String) -> URL? {
        let stem = name.hasSuffix(".\(ext)") ? String(name.dropLast(ext.count + 1)) : name
        return Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: sub)
            ?? Bundle.main.url(forResource: stem, withExtension: ext)
    }

    private func applyHardware() throws {
        try validateSelectedDevices()

        // AVAudioEngine exposes one AUHAL for both I/O nodes. Assigning an
        // input-only device followed by an output-only device to that same
        // unit leaves it attached to neither. Route through the system's
        // paired defaults, then instantiate a fresh engine in startEngine().
        try check(
            CoreAudioDevices.setDefaultInput(inputDeviceID),
            action: "select \(inputLabel) as input"
        )
        try check(
            CoreAudioDevices.setDefaultOutput(outputDeviceID),
            action: "select \(outputLabel) as output"
        )

        if devices.first(where: { $0.id == inputDeviceID })?.isAnalogInput == true {
            CoreAudioDevices.raiseVolumeIfNeeded(
                device: inputDeviceID,
                scope: kAudioDevicePropertyScopeInput,
                minimum: 0.75
            )
        }
        if devices.first(where: { $0.id == outputDeviceID })?.isAnalogOutput == true {
            CoreAudioDevices.raiseVolumeIfNeeded(
                device: outputDeviceID,
                scope: kAudioDevicePropertyScopeOutput,
                minimum: 0.8
            )
        }

        let alignedRate = try alignedSampleRate()
        if let alignedRate {
            CoreAudioDevices.setSampleRate(alignedRate, device: inputDeviceID)
            if outputDeviceID != inputDeviceID {
                CoreAudioDevices.setSampleRate(alignedRate, device: outputDeviceID)
            }
        }

        CoreAudioDevices.setBufferFrameSize(bufferSize, device: inputDeviceID)
        if outputDeviceID != inputDeviceID {
            CoreAudioDevices.setBufferFrameSize(bufferSize, device: outputDeviceID)
        }
    }

    private func alignedSampleRate() throws -> Double? {
        if sampleRate > 1 {
            guard CoreAudioDevices.supportsSampleRate(sampleRate, device: inputDeviceID),
                  CoreAudioDevices.supportsSampleRate(sampleRate, device: outputDeviceID) else {
                throw NSError(
                    domain: "xzyqrn amp",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Both selected devices must support \(Int(sampleRate)) Hz. Choose Follow device or another rate."]
                )
            }
            return sampleRate
        }

        let inputRate = CoreAudioDevices.currentSampleRate(device: inputDeviceID)
        let outputRate = CoreAudioDevices.currentSampleRate(device: outputDeviceID)
        if inputRate > 1, outputRate > 1, abs(inputRate - outputRate) <= 1 {
            return nil
        }
        let candidates = [outputRate, inputRate, 48_000, 44_100, 96_000].filter { $0 > 1 }
        if let common = candidates.first(where: {
            CoreAudioDevices.supportsSampleRate($0, device: inputDeviceID)
                && CoreAudioDevices.supportsSampleRate($0, device: outputDeviceID)
        }) {
            return common
        }
        throw NSError(
            domain: "xzyqrn amp",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "The selected input and output do not share a sample rate. Choose a matched pair in Audio MIDI Setup."]
        )
    }

    private func validateSelectedDevices() throws {
        guard inputDeviceID != 0,
              devices.contains(where: { $0.id == inputDeviceID && $0.hasInput }) else {
            throw NSError(
                domain: "xzyqrn amp",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "No usable input is selected. Reconnect the bass interface and choose it in xzyqrn amp Settings."]
            )
        }
        guard outputDeviceID != 0,
              devices.contains(where: { $0.id == outputDeviceID && $0.hasOutput }) else {
            throw NSError(
                domain: "xzyqrn amp",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "No usable output is selected. Reconnect your headphones and choose them in xzyqrn amp Settings."]
            )
        }
    }

    private func check(_ status: OSStatus, action: String) throws {
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Core Audio couldn't \(action) (\(status))."]
            )
        }
    }

    private static func describeAudioError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.code == -10875 || ns.code == -10863 {
            return "The headphone jack didn’t initialize. Analog iRig is not listed as “iRig” — use External Microphone in, Headphones out. Leave sample rate on Follow device. Headphones stay in the iRig."
        }
        if ns.code == -3000 {
            return "Couldn't open the audio engine. Power off and on again after the iRig is in the Mac headphone jack."
        }
        if ns.domain == NSOSStatusErrorDomain || ns.domain.contains("avfaudio") || ns.domain.contains("coreaudio") {
            return ns.localizedDescription
        }
        return ns.localizedDescription
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickMeters()
            }
        }
    }

    private func tickMeters() {
        let meters = AmpProcessorGetMeters(processor)
        inputPeak = Double(meters.inputPeak)
        outputPeak = Double(meters.outputPeak)
        inputRmsDb = Double(meters.inputRmsDb)
        noiseFloorDb = Double(meters.noiseFloorDb)
        inputClip = meters.inputClip
        outputClip = meters.outputClip
        tunerHz = Double(meters.tunerHz)
        tunerConfidence = Double(meters.tunerConfidence)
        if isRecording {
            recordElapsed = recorder.elapsed
            recordPeak = Double(recorder.peak)
        }

        if let renderState {
            let fifo = renderState.fifoStats()
            let underflowDelta = fifo.underflowFrames &- lastFIFOUnderflowFrames
            let overflowDelta = fifo.overflowFrames &- lastFIFOOverflowFrames
            if underflowDelta > UInt64(max(hardwareBuffer, 64)) {
                audioDiagnostic = "Output is starving: raise the buffer to 256 or 512 samples. This causes clicks, not cable hiss."
            } else if overflowDelta > UInt64(max(hardwareBuffer, 64)) {
                audioDiagnostic = "Input/output clocks are drifting: use one interface for both input and output, or Follow device."
            } else if meters.inputClip {
                audioDiagnostic = "The analog input is clipping. Lower the bass/interface output or input level."
            } else if noiseFloorDb > -45 {
                audioDiagnostic = "High analog noise. Check the instrument cable, bass jack, iRig plug, shielding, and Mac charger."
            } else if noiseFloorDb > -60 {
                audioDiagnostic = "Moderate analog noise. Try another cable and unplug the Mac charger as a comparison."
            } else if noiseFloorDb > -115 {
                audioDiagnostic = "Input path looks quiet. Any remaining regular clicks are more likely buffer-related."
            } else {
                audioDiagnostic = "Measuring idle input… stop playing for about one second."
            }
            if fifo.underflowFrames != lastFIFOUnderflowFrames
                || fifo.overflowFrames != lastFIFOOverflowFrames {
                NSLog(
                    "xzyqrn amp audio bridge: available=%d underflow=%llu overflow=%llu",
                    fifo.availableFrames,
                    fifo.underflowFrames,
                    fifo.overflowFrames
                )
                lastFIFOUnderflowFrames = fifo.underflowFrames
                lastFIFOOverflowFrames = fifo.overflowFrames
            }
        }
    }

    func applyPedalPreset(_ preset: PedalFactoryPreset) {
        switch preset.pedal {
        case "comp":
            compOn = true
            if let v = preset.values["compThresholdDb"] { compThresholdDb = v }
            if let v = preset.values["compRatio"] { compRatio = v }
            if let v = preset.values["compMakeupDb"] { compMakeupDb = v }
        case "drive":
            driveOn = true
            if let v = preset.values["driveAmount"] { driveAmount = v }
            if let v = preset.values["driveTone"] { driveTone = v }
            if let v = preset.values["driveMix"] { driveMix = v }
        case "octaver":
            octaverOn = true
            if let v = preset.values["octaverMix"] { octaverMix = v }
            if let v = preset.values["octaverTone"] { octaverTone = v }
        case "envelope":
            envelopeOn = true
            if let v = preset.values["envelopeSensitivity"] { envelopeSensitivity = v }
            if let v = preset.values["envelopeResonance"] { envelopeResonance = v }
            if let v = preset.values["envelopeMix"] { envelopeMix = v }
        case "filter":
            utilityFilterOn = true
            if let v = preset.values["highPassHz"] { highPassHz = v }
            if let v = preset.values["lowPassHz"] { lowPassHz = v }
        case "chorus":
            chorusOn = true
            if let v = preset.values["chorusRate"] { chorusRate = v }
            if let v = preset.values["chorusDepth"] { chorusDepth = v }
            if let v = preset.values["chorusMix"] { chorusMix = v }
        case "delay":
            delayOn = true
            if let v = preset.values["delayTimeMs"] { delayTimeMs = v }
            if let v = preset.values["delayFeedback"] { delayFeedback = v }
            if let v = preset.values["delayMix"] { delayMix = v }
        case "reverb":
            reverbOn = true
            if let v = preset.values["reverbSize"] { reverbSize = v }
            if let v = preset.values["reverbDamp"] { reverbDamp = v }
            if let v = preset.values["reverbMix"] { reverbMix = v }
        default:
            break
        }
        pushAllParams()
    }

    func setBeatStyle(_ style: BeatStyle) {
        beatStyle = style
        beatPlayer.select(style: style, bpm: beatBPM)
    }

    func setBeatBPM(_ bpm: Double) {
        beatBPM = min(max(bpm, 40), 240)
        beatPlayer.select(style: beatStyle, bpm: beatBPM)
    }

    func tapBeatTempo() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTempoTap = now }
        guard let lastTempoTap else { return }
        let interval = now - lastTempoTap
        guard interval >= 0.25, interval <= 1.5 else { return }
        setBeatBPM(60.0 / interval)
    }

    func increasePracticeTempo() {
        setBeatBPM(min(240, beatBPM + practiceIncreaseStep))
    }

    func setBeatVolume(_ value: Double) {
        beatVolume = value
        beatPlayer.volume = Float(value)
    }

    func toggleBeat() {
        beatOn.toggle()
        beatPlayer.playing = beatOn && isRunning
        if beatOn && !isRunning {
            togglePower()
        }
    }

    func toggleRecord() {
        if isRecording {
            stopRecording()
            return
        }
        guard isRunning else {
            errorMessage = "Power on before recording."
            return
        }
        do {
            let url = try RecordingStore.newURL()
            recorder.recordBassOnly = recordBassOnly
            try recorder.start(url: url)
            isRecording = true
            recordElapsed = 0
            recordPeak = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder.stop()
        isRecording = false
        recordElapsed = recorder.elapsed
        takes = RecordingStore.loadAll()
    }

    func playTake(_ take: RecordingTake) {
        stopTakePlayback()
        do {
            let accessing = take.url.startAccessingSecurityScopedResource()
            let player = try AVAudioPlayer(contentsOf: take.url)
            player.prepareToPlay()
            if player.play() {
                takePlayer = player
                playingTakeID = take.id
            }
            if accessing { take.url.stopAccessingSecurityScopedResource() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopTakePlayback() {
        takePlayer?.stop()
        takePlayer = nil
        playingTakeID = nil
    }

    func deleteTake(_ take: RecordingTake) {
        if playingTakeID == take.id { stopTakePlayback() }
        RecordingStore.delete(take)
        takes = RecordingStore.loadAll()
    }

    func revealTake(_ take: RecordingTake) {
        NSWorkspace.shared.activateFileViewerSelecting([take.url])
    }

    func revealRecordingsFolder() {
        if let dir = try? RecordingStore.directory() {
            NSWorkspace.shared.open(dir)
        }
    }

    func exportTake(_ take: RecordingTake) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = take.url.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: take.url, to: dest)
            } catch {
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func stopEngineOnly() {
        if isRecording {
            stopRecording()
        }
        stopTakePlayback()
        meterTimer?.invalidate()
        meterTimer = nil
        beatPlayer.playing = false
        if engine.isRunning { engine.stop() }
        if let sinkNode { engine.detach(sinkNode) }
        if let sourceNode { engine.detach(sourceNode) }
        self.sinkNode = nil
        self.sourceNode = nil
        self.renderState = nil
        lastFIFOUnderflowFrames = 0
        lastFIFOOverflowFrames = 0
        isRunning = false
        inputPeak = 0
        outputPeak = 0
        inputRmsDb = -120
        noiseFloorDb = -120
        audioDiagnostic = "Power on, then stop playing for a moment to measure the input."
        inputClip = false
        outputClip = false
        tunerHz = 0
        tunerConfidence = 0
    }
}
