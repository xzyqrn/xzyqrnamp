import CoreAudio
import Foundation

/// Captures the mix playing to a hardware output, including other apps.
/// Uses a Core Audio process tap into a tap-only private aggregate.
final class SystemOutputTap: @unchecked Sendable {
    private let mixdownCapacity = 16_384
    private let mixdown: UnsafeMutablePointer<Float>
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private weak var recorder: Recorder?

    var isRunning: Bool { aggregateID != 0 && ioProcID != nil }

    init() {
        mixdown = .allocate(capacity: mixdownCapacity)
        mixdown.initialize(repeating: 0, count: mixdownCapacity)
    }

    deinit {
        stop()
        mixdown.deinitialize(count: mixdownCapacity)
        mixdown.deallocate()
    }

    func start(outputUID: String?, preferGlobalTap: Bool, expectedSampleRate: Double, recorder: Recorder) throws {
        stop()
        guard #available(macOS 14.2, *) else {
            throw SystemOutputTapError.unsupported
        }

        var hardwareUID = outputUID
        if hardwareUID == CoreAudioDevices.analogAggregateUID
            || hardwareUID == CoreAudioDevices.outputTapAggregateUID {
            hardwareUID = nil
        }

        var attempts: [String?] = preferGlobalTap
            ? [nil, hardwareUID]
            : [hardwareUID, nil]
        var seen = Set<String>()
        attempts = attempts.filter { uid in
            let key = uid ?? "*"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        var lastError: Error = SystemOutputTapError.unsupported
        for uid in attempts {
            do {
                try startOnce(
                    deviceUID: uid,
                    expectedSampleRate: expectedSampleRate,
                    recorder: recorder
                )
                return
            } catch {
                lastError = error
                NSLog("xzyqrn amp system tap attempt failed (\(uid ?? "global")): \(error)")
                stop()
            }
        }
        throw lastError
    }

    func stop() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        CoreAudioDevices.destroyOutputTapAggregate()
        if tapID != 0 {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = 0
        }
        recorder?.capturingSystemOutput = false
        recorder = nil
    }

    @available(macOS 14.2, *)
    private func startOnce(deviceUID: String?, expectedSampleRate: Double, recorder: Recorder) throws {
        CoreAudioDevices.destroyOutputTapAggregate()

        let description = makeDescription(deviceUID: deviceUID)
        var createdTap = AudioObjectID(0)
        try check(AudioHardwareCreateProcessTap(description, &createdTap), action: "create the system-audio tap")
        guard createdTap != 0 else {
            throw SystemOutputTapError.createTap(kAudioHardwareUnspecifiedError)
        }
        tapID = createdTap

        if let tapRate = tapSampleRate(tapID), abs(tapRate - expectedSampleRate) > 1 {
            throw SystemOutputTapError.sampleRate(tapRate, expectedSampleRate)
        }

        let tapUID = uid(ofTap: createdTap) ?? description.uuid.uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "xzyqrn output tap",
            kAudioAggregateDeviceUIDKey as String: CoreAudioDevices.outputTapAggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 0,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: tapUID,
                kAudioSubTapDriftCompensationKey as String: 1
            ]]
        ]

        var createdAggregate = AudioDeviceID(0)
        try check(
            AudioHardwareCreateAggregateDevice(composition as CFDictionary, &createdAggregate),
            action: "create the system-audio tap device"
        )
        guard createdAggregate != 0 else {
            throw SystemOutputTapError.createAggregate(kAudioHardwareUnspecifiedError)
        }
        aggregateID = createdAggregate

        self.recorder = recorder
        var proc: AudioDeviceIOProcID?
        let mixdown = self.mixdown
        let mixdownCapacity = self.mixdownCapacity
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&proc, createdAggregate, nil) { _, inInputData, _, _, _ in
                guard recorder.armed, !recorder.recordBassOnly else { return }
                SystemOutputTap.pushMixdown(
                    inInputData,
                    mixdown: mixdown,
                    capacity: mixdownCapacity,
                    recorder: recorder
                )
            },
            action: "attach the system-audio recorder"
        )
        guard let proc else {
            throw SystemOutputTapError.ioProc(kAudioHardwareUnspecifiedError)
        }
        ioProcID = proc
        recorder.capturingSystemOutput = true
        let startStatus = AudioDeviceStart(createdAggregate, proc)
        if startStatus != noErr {
            recorder.capturingSystemOutput = false
            throw SystemOutputTapError.start(startStatus)
        }
    }

    @available(macOS 14.2, *)
    private func makeDescription(deviceUID: String?) -> CATapDescription {
        let description: CATapDescription
        if let deviceUID {
            description = CATapDescription(__excludingProcesses: [], andDeviceUID: deviceUID, withStream: 0)
        } else {
            description = CATapDescription(__stereoGlobalTapButExcludeProcesses: [])
        }
        description.name = "xzyqrn output tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    private func tapSampleRate(_ tapID: AudioObjectID) -> Double? {
        var asbd = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr else {
            return nil
        }
        return asbd.mSampleRate
    }

    private func uid(ofTap tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(tapID, &address, 0, nil, &size) == noErr else { return nil }
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }

    private static func pushMixdown(
        _ list: UnsafePointer<AudioBufferList>,
        mixdown: UnsafeMutablePointer<Float>,
        capacity: Int,
        recorder: Recorder
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard !abl.isEmpty else { return }

        if abl.count == 1 {
            let buffer = abl[0]
            guard let data = buffer.mData else { return }
            let channels = max(1, Int(buffer.mNumberChannels))
            let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard totalFloats > 0 else { return }
            let frames = totalFloats / channels
            let src = data.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                recorder.push(src, frames: min(frames, capacity))
                return
            }
            let count = min(frames, capacity)
            let inv = 1 / Float(channels)
            for i in 0..<count {
                var sum: Float = 0
                let base = i * channels
                for c in 0..<channels {
                    sum += src[base + c]
                }
                mixdown[i] = sum * inv
            }
            recorder.push(mixdown, frames: count)
            return
        }

        let frames = min(capacity, Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size)
        guard frames > 0 else { return }
        let channels = abl.count
        let inv = 1 / Float(channels)
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels {
                if let data = abl[c].mData {
                    sum += data.assumingMemoryBound(to: Float.self)[i]
                }
            }
            mixdown[i] = sum * inv
        }
        recorder.push(mixdown, frames: frames)
    }

    private func check(_ status: OSStatus, action: String) throws {
        guard status == noErr else {
            throw SystemOutputTapError.status(status, action)
        }
    }
}

enum SystemOutputTapError: LocalizedError {
    case unsupported
    case status(OSStatus, String)
    case createTap(OSStatus)
    case createAggregate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)
    case sampleRate(Double, Double)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "System-output recording needs macOS 14.2 or later."
        case .status(let status, let action):
            return "Couldn't \(action) (\(status))."
        case .createTap(let status):
            return "Couldn't create the system-audio tap (\(status))."
        case .createAggregate(let status):
            return "Couldn't create the system-audio tap device (\(status))."
        case .ioProc(let status):
            return "Couldn't attach the system-audio recorder (\(status))."
        case .start(let status):
            return "Couldn't start system-audio capture (\(status))."
        case .sampleRate(let tap, let expected):
            return "System-audio sample rate \(Int(tap)) Hz doesn't match the amp (\(Int(expected)) Hz)."
        }
    }
}
