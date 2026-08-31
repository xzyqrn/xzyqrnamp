import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private final class TakePlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}

private struct LiveMetrics {
    var inputPeak: Double = 0
    var outputPeak: Double = 0
    var inputRmsDb: Double = -120
    var inputPeakDb: Double = -120
    var noiseFloorDb: Double = -120
    var audioDiagnostic = "Power on, then stop playing for a moment to measure the input."
    var inputClip = false
    var outputClip = false
    var tunerHz: Double = 0
    var tunerConfidence: Double = 0
    var recordElapsed: TimeInterval = 0
    var recordPeak: Double = 0
    var fifoAvailable: Int = 0
    var fifoUnderflowFrames: UInt64 = 0
    var fifoOverflowFrames: UInt64 = 0
    var clockCondition = "Unknown"
}

@MainActor
final class AmpSession: ObservableObject {
    @Published var isRunning = false
    @Published var status = "Off"
    @Published var errorMessage: String?
    @Published var devices: [AudioDevice] = []
    @Published var inputDeviceID: AudioDeviceID = CoreAudioDevices.defaultInputID()
    @Published var outputDeviceID: AudioDeviceID = CoreAudioDevices.defaultOutputID()
    @Published var bufferSize: UInt32 = 128
    /// 0 Channel 1, 1 Channel 2, 2 Sum 1+2, 3 Auto (stronger channel, never sums).
    @Published var inputChannel: Int = 0
    /// 0 means follow whatever the jack / interface is already using.
    @Published var sampleRate: Double = 0
    @Published var hardwareSampleRate: Double = 48000
    @Published var hardwareBuffer: UInt32 = 256
    @Published var latencyMs: Double = 0
    @Published var latencyIsEstimated = true

    @Published var inputGainDb: Double = 0
    @Published var outputGainDb: Double = -3
    @Published var gateThresholdDb: Double = -40
    @Published var bassDb: Double = 0
    @Published var midDb: Double = 0
    @Published var trebleDb: Double = 0
    @Published var midFreqIndex: Int = 1 // 0: 220Hz, 1: 450Hz, 2: 800Hz, 3: 1.6kHz, 4: 3.0kHz
    @Published var ultraLoOn = false
    @Published var ultraHiOn = false
    @Published var selectedCabinet = "bass-4x10.wav"
    @Published var gateOn = false
    @Published var expanderOn = true
    @Published var nrOn = true
    @Published var namOn = false
    @Published var cleanAmpOn = false
    @Published var irOn = false
    @Published var eqOn = false
    @Published var bypass = false
    @Published var tunerMute = false

    static let availableCabinets: [(id: String, name: String)] = [
        ("bass-8x10.wav", "Ampeg SVT 8x10"),
        ("bass-4x10.wav", "Darkglass 4x10"),
        ("bass-2x12.wav", "Mesa Boogie 2x12"),
        ("bass-1x15.wav", "Aguilar DB 1x15"),
    ]

    @Published var compOn = false
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
    @Published var highPassHz: Double = 25
    @Published var lowPassHz: Double = 16000

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

    @Published var namName = "Passthrough"
    @Published var irName = "No cabinet"
    @Published var namPath: URL?
    @Published var irPath: URL?

    @Published private var liveMetrics = LiveMetrics()
    var inputPeak: Double { liveMetrics.inputPeak }
    var outputPeak: Double { liveMetrics.outputPeak }
    var inputRmsDb: Double { liveMetrics.inputRmsDb }
    var inputPeakDb: Double { liveMetrics.inputPeakDb }
    var noiseFloorDb: Double { liveMetrics.noiseFloorDb }
    var audioDiagnostic: String { liveMetrics.audioDiagnostic }
    var fifoAvailable: Int { liveMetrics.fifoAvailable }
    var fifoUnderflowFrames: UInt64 { liveMetrics.fifoUnderflowFrames }
    var fifoOverflowFrames: UInt64 { liveMetrics.fifoOverflowFrames }
    var clockCondition: String { liveMetrics.clockCondition }
    var inputClip: Bool { liveMetrics.inputClip }
    var outputClip: Bool { liveMetrics.outputClip }
    var tunerHz: Double { liveMetrics.tunerHz }
    var tunerConfidence: Double { liveMetrics.tunerConfidence }

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
    var recordElapsed: TimeInterval { liveMetrics.recordElapsed }
    var recordPeak: Double { liveMetrics.recordPeak }
    @Published var recordBassOnly = false
    @Published var takes: [RecordingTake] = []
    @Published var playingTakeID: String?

    let beatPlayer = BeatPlayer()
    let recorder = Recorder()
    private let outputTap = SystemOutputTap()
    private var takePlayer: AVAudioPlayer?
    private var takePlaybackDelegate: TakePlaybackDelegate?

    private var engine = AVAudioEngine()
    private var sinkNode: AVAudioSinkNode?
    private var sourceNode: AVAudioSourceNode?
    private var renderState: AudioRenderState?
    private var analogAggregateID: AudioDeviceID = 0
    private var analogDuplexRoute = false
    private var lastFIFOUnderflowFrames: UInt64 = 0
    private var lastFIFOOverflowFrames: UInt64 = 0
    private var meterTimer: Timer?
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var configurationObserver: NSObjectProtocol?
    private var reconnectTask: Task<Void, Never>?
    private var currentNAMBookmark: Data?
    private var currentIRBookmark: Data?
    private var isStarting = false
    private let processor = AmpProcessorShared()!

    static let cleanAmpName = "xzyqrn Vintage Clean"
    static let passthroughAmpName = "Passthrough"
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
        if devices.first(where: { $0.id == inputDeviceID })?.isAnalogInput == true {
            // Never default analog to Sum 1+2: the unused jack channel is
            // usually open-ADC hiss, and mixing it in makes static that
            // does not go away when you play or mute.
            inputChannel = 3
            if bufferSize < 256 {
                bufferSize = CoreAudioDevices.clampBuffer(256, device: outputDeviceID)
            }
        }
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
        var lastError: Error?
        // Analog mic + headphones can share a private aggregate. If that
        // device will not open (sandbox, voice isolation, etc.), fall back
        // to the split sink/source path that actually starts on this jack.
        for useAnalogAggregate in [true, false] {
            do {
                try await startEngineOnce(useAnalogAggregate: useAnalogAggregate)
                return
            } catch {
                lastError = error
                stopEngineOnly()
            }
        }
        throw lastError ?? NSError(
            domain: "xzyqrn amp",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't start audio on this analog route."]
        )
    }

    private func startEngineOnce(useAnalogAggregate: Bool) async throws {
        stopEngineOnly()
        try applyHardware(useAnalogAggregate: useAnalogAggregate)

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
            preRollFrames: fifoPreRollFrames,
            engineSampleRate: dspRate,
            inputChannel: inputChannel,
            sharedClock: analogDuplexRoute || inputDeviceID == outputDeviceID
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
        engine.connect(source, to: engine.outputNode, format: outputFormat)

        AmpProcessorReset(processor, dspRate, Int32(max(Int(bufferSize), 4096)))
        if let namPath { _ = loadNAM(url: namPath) }
        if let irPath { _ = loadIR(url: irPath) }
        pushAllParams()

        engine.prepare()
        try engine.start()
        isRunning = true
        hardwareSampleRate = dspRate
        let routeDevice = analogAggregateID != 0 ? analogAggregateID : outputDeviceID
        hardwareBuffer = CoreAudioDevices.currentBufferFrameSize(device: routeDevice)
        if hardwareBuffer == 0 {
            hardwareBuffer = CoreAudioDevices.currentBufferFrameSize(device: inputDeviceID)
        }
        if hardwareBuffer == 0 { hardwareBuffer = bufferSize }
        updateEstimatedLatency()
        let routeName = analogDuplexRoute
            ? "analog duplex"
            : (devices.first(where: { $0.id == inputDeviceID })?.name ?? "Input")
        status = String(
            format: "Live · %@ · %.0f Hz · %d samples",
            routeName,
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
            let wasRunning = isRunning
            isStarting = true
            status = "Applying audio route…"
            defer { isStarting = false }
            do {
                refreshDevices()
                try validateSelectedDevices()
                if wasRunning {
                    try await startEngine()
                } else {
                    try applyHardware()
                    hardwareSampleRate = CoreAudioDevices.currentSampleRate(device: outputDeviceID)
                    if hardwareSampleRate < 1 {
                        hardwareSampleRate = CoreAudioDevices.currentSampleRate(device: inputDeviceID)
                    }
                    hardwareBuffer = CoreAudioDevices.currentBufferFrameSize(device: outputDeviceID)
                    if hardwareBuffer == 0 {
                        hardwareBuffer = CoreAudioDevices.currentBufferFrameSize(device: inputDeviceID)
                    }
                    if hardwareBuffer == 0 { hardwareBuffer = bufferSize }
                    updateEstimatedLatency()
                    status = "Off"
                    errorMessage = nil
                }
            } catch {
                errorMessage = Self.describeAudioError(error)
                status = wasRunning ? "Couldn't restart audio" : "Couldn't apply audio route"
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
        AmpProcessorSetExpanderOn(processor, expanderOn)
        AmpProcessorSetNROn(processor, nrOn)
        AmpProcessorSetNAMOn(processor, namOn)
        AmpProcessorSetCleanAmpOn(processor, cleanAmpOn)
        AmpProcessorSetIROn(processor, irOn)
        AmpProcessorSetEQOn(processor, eqOn)
        AmpProcessorSetBypass(processor, bypass)
        AmpProcessorSetTunerMute(processor, tunerMute)
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
            cleanAmpOn = false
            namOn = true
            namPath = url
            namName = url.deletingPathExtension().lastPathComponent
            rememberExternalResource(url, kind: .nam)
            errorMessage = nil
            pushAllParams()
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
        namName = cleanAmpOn ? Self.cleanAmpName : Self.passthroughAmpName
        currentNAMBookmark = nil
        UserDefaults.standard.removeObject(forKey: Self.lastNAMBookmarkKey)
    }

    func clearNAMToPassthrough() {
        cleanAmpOn = false
        namOn = false
        unloadNAM()
        pushAllParams()
    }

    func useCleanAmp() {
        unloadNAM()
        cleanAmpOn = true
        namOn = true
        namName = Self.cleanAmpName
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
        var next = liveMetrics
        next.inputClip = false
        next.outputClip = false
        liveMetrics = next
    }

    func applyPreset(_ preset: AmpPreset) {
        var resourceErrors: [String] = []
        selectedPresetID = preset.id
        // Selecting a preset means the user wants to hear that processing
        // chain. Leaving global bypass engaged made every preset appear inert.
        bypass = false
        inputGainDb = preset.inputGainDb
        outputGainDb = preset.outputGainDb
        gateThresholdDb = preset.gateThresholdDb
        bassDb = preset.bassDb
        midDb = preset.midDb
        trebleDb = preset.trebleDb
        gateOn = preset.gateOn
        expanderOn = preset.expanderOn
        nrOn = preset.nrOn
        namOn = preset.namOn
        cleanAmpOn = preset.cleanAmpOn
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
        if !preset.irFile.isEmpty {
            selectedCabinet = preset.irFile
        }
        pushAllParams()
        if let bookmark = preset.namBookmark {
            if let url = resolveBookmark(bookmark, refreshKey: Self.lastNAMBookmarkKey) {
                if !loadNAM(url: url) {
                    resourceErrors.append("Capture “\(preset.namFile)” could not be loaded: \(errorMessage ?? "unknown error")")
                    unloadNAM()
                }
            } else {
                unloadNAM()
                resourceErrors.append("Capture “\(preset.namFile)” is no longer available. Reconnect it and save the preset again.")
            }
        } else if Self.isBundledCleanNAM(preset.namFile) || preset.namFile.isEmpty {
            if preset.cleanAmpOn {
                useCleanAmp()
            } else {
                cleanAmpOn = false
                unloadNAM()
                pushAllParams()
            }
        } else if let nam = bundledURL(preset.namFile, ext: "nam", sub: "Models") {
            if !loadNAM(url: nam) {
                resourceErrors.append("Capture “\(preset.namFile)” could not be loaded: \(errorMessage ?? "unknown error")")
                unloadNAM()
            }
        } else {
            unloadNAM()
            resourceErrors.append("Capture “\(preset.namFile)” is missing from the app.")
        }
        if let bookmark = preset.irBookmark {
            if let url = resolveBookmark(bookmark, refreshKey: Self.lastIRBookmarkKey) {
                if !loadIR(url: url) {
                    resourceErrors.append("Cabinet “\(preset.irFile)” could not be loaded: \(errorMessage ?? "unknown error")")
                    unloadIR()
                }
            } else {
                unloadIR()
                resourceErrors.append("Cabinet “\(preset.irFile)” is no longer available. Reconnect it and save the preset again.")
            }
        } else if preset.irFile.isEmpty {
            unloadIR()
        } else if let ir = bundledURL(preset.irFile, ext: "wav", sub: "IRs") {
            if !loadIR(url: ir) {
                resourceErrors.append("Cabinet “\(preset.irFile)” could not be loaded: \(errorMessage ?? "unknown error")")
                unloadIR()
            }
        } else {
            unloadIR()
            resourceErrors.append("Cabinet “\(preset.irFile)” is missing from the app.")
        }
        if !resourceErrors.isEmpty {
            errorMessage = resourceErrors.joined(separator: "\n")
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
            expanderOn: expanderOn,
            nrOn: nrOn,
            namOn: namOn,
            cleanAmpOn: cleanAmpOn,
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
        unloadNAM()
        unloadIR()
        if let practice = presets.first(where: { $0.id == "practice" }) {
            applyPreset(practice)
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

    private func applyHardware(useAnalogAggregate: Bool = true) throws {
        try validateSelectedDevices()
        analogDuplexRoute = false
        analogAggregateID = 0
        CoreAudioDevices.destroyAnalogAggregate()

        let alignedRate = try alignedSampleRate()
        if let alignedRate {
            CoreAudioDevices.setSampleRate(alignedRate, device: inputDeviceID)
            if outputDeviceID != inputDeviceID {
                CoreAudioDevices.setSampleRate(alignedRate, device: outputDeviceID)
            }
        }

        var routeInput = inputDeviceID
        var routeOutput = outputDeviceID
        if useAnalogAggregate,
           let input = devices.first(where: { $0.id == inputDeviceID }),
           let output = devices.first(where: { $0.id == outputDeviceID }),
           input.id != output.id,
           input.isAnalogInput,
           output.isAnalogOutput,
           let aggregate = CoreAudioDevices.createAnalogAggregate(inputUID: input.uid, outputUID: output.uid) {
            analogAggregateID = aggregate
            analogDuplexRoute = true
            routeInput = aggregate
            routeOutput = aggregate
        }

        // One AUHAL cannot hold an input-only device and a different
        // output-only device. Analog mic + headphones become one private
        // aggregate first, then both defaults point at that duplex device.
        try check(
            CoreAudioDevices.setDefaultInput(routeInput),
            action: "select \(inputLabel) as input"
        )
        try check(
            CoreAudioDevices.setDefaultOutput(routeOutput),
            action: "select \(outputLabel) as output"
        )

        CoreAudioDevices.setBufferFrameSize(bufferSize, device: routeInput)
        if routeOutput != routeInput {
            CoreAudioDevices.setBufferFrameSize(bufferSize, device: routeOutput)
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

    private var fifoPreRollFrames: Int {
        Int(max(bufferSize * 2, 256))
    }

    private func updateEstimatedLatency() {
        let preRoll = Double(fifoPreRollFrames)
        latencyMs = 1000.0 * (Double(hardwareBuffer) * 2.0 + preRoll) / max(hardwareSampleRate, 1)
        latencyIsEstimated = true
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
            return "Couldn't open the audio engine. Unplug and replug the iRig, then power on. If this keeps happening, leave Input on External Microphone and Output on External Headphones."
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
        var next = liveMetrics
        next.inputPeak = Double(meters.inputPeak)
        next.outputPeak = Double(meters.outputPeak)
        next.inputRmsDb = Double(meters.inputRmsDb)
        next.inputPeakDb = Double(meters.inputPeakDb)
        next.noiseFloorDb = Double(meters.noiseFloorDb)
        next.inputClip = meters.inputClip
        next.outputClip = meters.outputClip
        next.tunerHz = Double(meters.tunerHz)
        next.tunerConfidence = Double(meters.tunerConfidence)
        if isRecording {
            next.recordElapsed = recorder.elapsed
            next.recordPeak = Double(recorder.peak)
        }

        if analogDuplexRoute {
            next.clockCondition = "Analog duplex · one clock"
        } else if inputDeviceID == outputDeviceID {
            next.clockCondition = "Shared device"
        } else {
            next.clockCondition = "Separate devices"
        }
        if let renderState {
            let fifo = renderState.fifoStats()
            next.fifoAvailable = Int(fifo.availableFrames)
            next.fifoUnderflowFrames = fifo.underflowFrames
            next.fifoOverflowFrames = fifo.overflowFrames
            let underflowDelta = fifo.underflowFrames &- lastFIFOUnderflowFrames
            let overflowDelta = fifo.overflowFrames &- lastFIFOOverflowFrames
            if underflowDelta > UInt64(max(hardwareBuffer, 64)) {
                next.audioDiagnostic = "Output is starving: raise the buffer to 256 or 512 samples. This causes clicks, not cable hiss."
            } else if overflowDelta > UInt64(max(hardwareBuffer, 64)) {
                next.audioDiagnostic = "Input and output clocks are drifting. Use the same interface for both."
            } else if meters.inputClip {
                next.audioDiagnostic = "The analog input is clipping. Lower the bass/interface output or input level."
            } else if next.tunerConfidence > 0.2, next.tunerHz > 47, next.tunerHz < 53 {
                next.audioDiagnostic = String(format: "Idle input is 50 Hz mains hum (tuner %.1f Hz), not a bass note. Unplug the charger to compare. Practice Clean notches 50/60 Hz so this does not hold the path open.", next.tunerHz)
            } else if next.tunerConfidence > 0.2, next.tunerHz > 57, next.tunerHz < 63 {
                next.audioDiagnostic = String(format: "Idle input is 60 Hz mains hum (tuner %.1f Hz), not a bass note. Unplug the charger to compare. Practice Clean notches 50/60 Hz so this does not hold the path open.", next.tunerHz)
            } else if next.noiseFloorDb > -50 {
                next.audioDiagnostic = "Hardware path likely noisy. Check bass, cable, iRig, grounding, charger, and input gain."
            } else if next.noiseFloorDb > -60 {
                next.audioDiagnostic = "Usable but noisy analog floor. Try another cable and unplug the Mac charger as a comparison."
            } else if next.noiseFloorDb > -70 {
                next.audioDiagnostic = "Good analog noise floor. Remaining hiss is more likely hardware than the Practice Clean path."
            } else if next.noiseFloorDb > -115 {
                next.audioDiagnostic = "Excellent analog noise floor."
            } else {
                next.audioDiagnostic = "Measuring idle input… stop playing for about one second."
            }
            lastFIFOUnderflowFrames = fifo.underflowFrames
            lastFIFOOverflowFrames = fifo.overflowFrames
        }
        liveMetrics = next
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
            errorMessage = nil
            var next = liveMetrics
            next.recordElapsed = 0
            next.recordPeak = 0
            liveMetrics = next
            beginSystemOutputCaptureIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyRecordSource() {
        recorder.recordBassOnly = recordBassOnly
        guard isRecording else { return }
        if recordBassOnly {
            outputTap.stop()
        } else {
            beginSystemOutputCaptureIfNeeded()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        outputTap.stop()
        recorder.stop()
        isRecording = false
        var next = liveMetrics
        next.recordElapsed = recorder.elapsed
        liveMetrics = next
        takes = RecordingStore.loadAll()
    }

    private func beginSystemOutputCaptureIfNeeded() {
        guard isRecording, !recordBassOnly else {
            outputTap.stop()
            return
        }
        if outputTap.isRunning { return }
        do {
            try outputTap.start(
                outputUID: CoreAudioDevices.uid(of: outputDeviceID),
                preferGlobalTap: analogDuplexRoute,
                expectedSampleRate: recorder.sampleRate,
                recorder: recorder
            )
        } catch {
            NSLog("xzyqrn amp system tap failed: \(error.localizedDescription)")
            errorMessage = "Recording this amp only. To capture other apps, allow System Audio Recording in System Settings → Privacy & Security."
        }
    }

    func playTake(_ take: RecordingTake) {
        stopTakePlayback()
        do {
            let accessing = take.url.startAccessingSecurityScopedResource()
            defer { if accessing { take.url.stopAccessingSecurityScopedResource() } }
            let player = try AVAudioPlayer(contentsOf: take.url)
            let delegate = TakePlaybackDelegate()
            delegate.onFinish = { [weak self, weak player] in
                Task { @MainActor in
                    guard let self, self.takePlayer === player else { return }
                    self.stopTakePlayback()
                }
            }
            player.delegate = delegate
            player.prepareToPlay()
            if player.play() {
                takePlayer = player
                takePlaybackDelegate = delegate
                playingTakeID = take.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopTakePlayback() {
        takePlayer?.stop()
        takePlayer = nil
        takePlaybackDelegate = nil
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
        outputTap.stop()
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
        analogDuplexRoute = false
        analogAggregateID = 0
        CoreAudioDevices.destroyAnalogAggregate()
        _ = CoreAudioDevices.setDefaultInput(inputDeviceID)
        _ = CoreAudioDevices.setDefaultOutput(outputDeviceID)
        isRunning = false
        liveMetrics = LiveMetrics()
    }
}
