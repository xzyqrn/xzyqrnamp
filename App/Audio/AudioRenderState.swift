import AVFoundation
import Darwin
import Foundation

/// Realtime-safe shared buffers between the input sink and output source.
final class AudioRenderState: @unchecked Sendable {
    let processor: UnsafeMutableRawPointer
    let capacity: Int
    let capture: UnsafeMutablePointer<Float>
    let work: UnsafeMutablePointer<Float>
    let fifo: UnsafeMutableRawPointer
    let beatPlayer: BeatPlayer
    let recorder: Recorder
    var engineSampleRate: Double = 48000
    private let inputChannelPtr: UnsafeMutablePointer<Int32>
    private let sharedClock: Bool
    private var persistentQueueError = 0
    private let preRollFrames: Int
    private var isPrimed = false
    private var fadeInFrames = 0
    private var lastInputSample: Float = 0
    private var consecutiveStarves = 0
    private var autoEnv0: Float = 0
    private var autoEnv1: Float = 0
    private var autoUseRight = false

    init(
        processor: UnsafeMutableRawPointer,
        beatPlayer: BeatPlayer,
        recorder: Recorder,
        capacity: Int = 32_768,
        preRollFrames: Int = 256,
        engineSampleRate: Double = 48000,
        inputChannel: Int = 0,
        sharedClock: Bool = false
    ) {
        self.processor = processor
        self.beatPlayer = beatPlayer
        self.recorder = recorder
        self.capacity = capacity
        self.engineSampleRate = engineSampleRate
        self.sharedClock = sharedClock
        self.preRollFrames = max(128, min(preRollFrames, capacity / 4))
        inputChannelPtr = .allocate(capacity: 1)
        inputChannelPtr.initialize(to: Int32(inputChannel))
        capture = .allocate(capacity: capacity)
        work = .allocate(capacity: capacity)
        fifo = AmpAudioFIFOCreate(Int32(capacity))!
        capture.initialize(repeating: 0, count: capacity)
        work.initialize(repeating: 0, count: capacity)
    }

    deinit {
        capture.deinitialize(count: capacity)
        work.deinitialize(count: capacity)
        capture.deallocate()
        work.deallocate()
        inputChannelPtr.deinitialize(count: 1)
        inputChannelPtr.deallocate()
        AmpAudioFIFODestroy(fifo)
    }

    var inputChannel: Int {
        get { Int(OSAtomicAdd32Barrier(0, inputChannelPtr)) }
        set {
            let value = Int32(newValue)
            while true {
                let current = inputChannelPtr.pointee
                if OSAtomicCompareAndSwap32Barrier(current, value, inputChannelPtr) {
                    return
                }
            }
        }
    }

    func mixdown(_ list: UnsafePointer<AudioBufferList>, frames: Int) {
        guard frames > 0, frames <= capacity else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard !abl.isEmpty else { return }

        let bufCount = abl.count
        if bufCount > 1 {
            let ch0 = abl[0].mData?.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil

            switch inputChannel {
            case 1:
                if let src = ch1 ?? ch0 {
                    memcpy(capture, src, frames * MemoryLayout<Float>.size)
                }
            case 2:
                if let s0 = ch0, let s1 = ch1 {
                    for i in 0..<frames {
                        capture[i] = (s0[i] + s1[i]) * 0.5
                    }
                } else if let s0 = ch0 {
                    memcpy(capture, s0, frames * MemoryLayout<Float>.size)
                }
            case 3:
                if let s0 = ch0, let s1 = ch1 {
                    copyAutoChannel(left: s0, right: s1, frames: frames)
                } else if let s0 = ch0 {
                    memcpy(capture, s0, frames * MemoryLayout<Float>.size)
                }
            default:
                if let src = ch0 {
                    memcpy(capture, src, frames * MemoryLayout<Float>.size)
                }
            }
        } else if let buffer = abl.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
            let channels = Int(max(1, buffer.mNumberChannels))
            if channels == 1 {
                memcpy(capture, data, frames * MemoryLayout<Float>.size)
            } else {
                switch inputChannel {
                case 1:
                    let offset = channels > 1 ? 1 : 0
                    for frame in 0..<frames {
                        capture[frame] = data[frame * channels + offset]
                    }
                case 2:
                    if channels > 1 {
                        for frame in 0..<frames {
                            capture[frame] = (data[frame * channels] + data[frame * channels + 1]) * 0.5
                        }
                    } else {
                        memcpy(capture, data, frames * MemoryLayout<Float>.size)
                    }
                case 3:
                    if channels > 1 {
                        copyAutoInterleaved(data, channels: channels, frames: frames)
                    } else {
                        memcpy(capture, data, frames * MemoryLayout<Float>.size)
                    }
                default:
                    for frame in 0..<frames {
                        capture[frame] = data[frame * channels]
                    }
                }
            }
        }
        _ = AmpAudioFIFOWrite(fifo, capture, Int32(frames))
    }

    func render(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(list)
        guard frames > 0 else { return }
        guard frames <= capacity else {
            for buffer in abl {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }

        if !isPrimed {
            let required = min(capacity / 4, max(preRollFrames, frames * 2))
            guard Int(AmpAudioFIFOAvailable(fifo)) >= required else {
                for buffer in abl {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return
            }
            isPrimed = true
            fadeInFrames = min(64, frames)
            consecutiveStarves = 0
        }

        let available = Int(AmpAudioFIFOAvailable(fifo))
        let target = max(preRollFrames, frames * 2)
        var requestedFrames = Int(AmpAudioFIFORequestFrames(Int32(available), Int32(frames), Int32(target), sharedClock))
        if !sharedClock {
            let error = available - target
            let deadzone = max(32, frames / 4)
            if abs(error) > deadzone {
                persistentQueueError += 1
            } else {
                persistentQueueError = 0
            }
            if persistentQueueError < 48 {
                requestedFrames = frames
            }
        }
        requestedFrames = min(max(requestedFrames, 1), capacity)

        let received = Int(AmpAudioFIFORead(fifo, work, Int32(requestedFrames)))
        if received >= max(2, frames / 2) {
            interpolateInput(sourceFrames: received, destinationFrames: frames)
            consecutiveStarves = 0
        } else {
            if received > 0 {
                memcpy(capture, work, received * MemoryLayout<Float>.size)
            }
            let missing = frames - received
            let rampStart = received > 0 ? capture[received - 1] : lastInputSample
            for i in 0..<missing {
                let remaining = Float(missing - i - 1) / Float(max(missing, 1))
                capture[received + i] = rampStart * remaining
            }
            consecutiveStarves += 1
            if consecutiveStarves > 4 {
                isPrimed = false
            }
        }

        if fadeInFrames > 0 {
            let count = min(fadeInFrames, frames)
            for i in 0..<count {
                capture[i] *= Float(i + 1) / Float(count)
            }
            fadeInFrames -= count
        }
        lastInputSample = capture[frames - 1]
        AmpProcessorProcess(processor, capture, work, Int32(frames))

        if recorder.armed && recorder.recordBassOnly {
            recorder.push(work, frames: frames)
        }

        beatPlayer.mix(into: work, frames: frames, engineRate: engineSampleRate)

        for i in 0..<frames {
            let sample = work[i]
            let magnitude = abs(sample)
            if magnitude > 0.90 {
                let limited = 0.90 + 0.08 * tanhf((magnitude - 0.90) / 0.08)
                work[i] = copysignf(limited, sample)
            }
        }

        if recorder.armed && !recorder.recordBassOnly {
            recorder.push(work, frames: frames)
        }

        copyToOutputs(abl, frames: frames)
    }

    func fifoStats() -> AmpAudioFIFOStats {
        AmpAudioFIFOGetStats(fifo)
    }

    private func copyAutoChannel(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let src = pickAutoSource(left: left, right: right, frames: frames)
        memcpy(capture, src, frames * MemoryLayout<Float>.size)
    }

    private func copyAutoInterleaved(_ data: UnsafePointer<Float>, channels: Int, frames: Int) {
        var e0: Float = 0
        var e1: Float = 0
        for frame in 0..<frames {
            e0 += abs(data[frame * channels])
            e1 += abs(data[frame * channels + 1])
        }
        updateAutoPick(e0: e0 / Float(frames), e1: e1 / Float(frames))
        let offset = autoUseRight ? 1 : 0
        for frame in 0..<frames {
            capture[frame] = data[frame * channels + offset]
        }
    }

    private func pickAutoSource(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> UnsafePointer<Float> {
        var e0: Float = 0
        var e1: Float = 0
        for i in 0..<frames {
            e0 += abs(left[i])
            e1 += abs(right[i])
        }
        updateAutoPick(e0: e0 / Float(frames), e1: e1 / Float(frames))
        return autoUseRight ? right : left
    }

    private func updateAutoPick(e0: Float, e1: Float) {
        autoEnv0 += 0.04 * (e0 - autoEnv0)
        autoEnv1 += 0.04 * (e1 - autoEnv1)
        if autoEnv1 > autoEnv0 * 2.2 {
            autoUseRight = true
        } else if autoEnv0 > autoEnv1 * 2.2 {
            autoUseRight = false
        }
    }

    private func interpolateInput(sourceFrames: Int, destinationFrames: Int) {
        guard sourceFrames > 0, destinationFrames > 0 else { return }
        if sourceFrames == destinationFrames {
            memcpy(capture, work, destinationFrames * MemoryLayout<Float>.size)
            return
        }
        if destinationFrames == 1 || sourceFrames == 1 {
            capture[0] = work[0]
            return
        }

        let step = Float(sourceFrames - 1) / Float(destinationFrames - 1)
        for i in 0..<destinationFrames {
            let position = Float(i) * step
            let lower = min(Int(position), sourceFrames - 1)
            let upper = min(lower + 1, sourceFrames - 1)
            let fraction = position - Float(lower)
            capture[i] = work[lower] + (work[upper] - work[lower]) * fraction
        }
    }

    private func copyToOutputs(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        for buffer in abl {
            guard let dest = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(max(1, buffer.mNumberChannels))
            if channels == 1 {
                memcpy(dest, work, frames * MemoryLayout<Float>.size)
            } else {
                for i in 0..<frames {
                    let sample = work[i]
                    for c in 0..<channels {
                        dest[i * channels + c] = sample
                    }
                }
            }
        }
    }
}
