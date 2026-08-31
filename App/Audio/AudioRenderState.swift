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
    var inputChannel: Int = 0
    private let preRollFrames: Int
    private var isPrimed = false
    private var fadeInFrames = 0
    private var lastInputSample: Float = 0

    init(
        processor: UnsafeMutableRawPointer,
        beatPlayer: BeatPlayer,
        recorder: Recorder,
        capacity: Int = 32_768,
        preRollFrames: Int = 256,
        engineSampleRate: Double = 48000,
        inputChannel: Int = 0
    ) {
        self.processor = processor
        self.beatPlayer = beatPlayer
        self.recorder = recorder
        self.capacity = capacity
        self.engineSampleRate = engineSampleRate
        self.inputChannel = inputChannel
        self.preRollFrames = max(128, min(preRollFrames, capacity / 4))
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
        AmpAudioFIFODestroy(fifo)
    }

    func mixdown(_ list: UnsafePointer<AudioBufferList>, frames: Int) {
        guard frames > 0, frames <= capacity else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard !abl.isEmpty else { return }

        let bufCount = abl.count
        if bufCount > 1 {
            // Non-interleaved multichannel
            let ch0 = abl[0].mData?.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil

            switch inputChannel {
            case 1: // Channel 2 (Inst 2 / Right)
                if let src = ch1 ?? ch0 {
                    memcpy(capture, src, frames * MemoryLayout<Float>.size)
                }
            case 2: // Sum 1+2
                if let s0 = ch0, let s1 = ch1 {
                    for i in 0..<frames {
                        capture[i] = (s0[i] + s1[i]) * 0.5
                    }
                } else if let s0 = ch0 {
                    memcpy(capture, s0, frames * MemoryLayout<Float>.size)
                }
            default: // Channel 1 (Default / Left)
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
                case 1: // Channel 2 (Inst 2 / Right)
                    let offset = channels > 1 ? 1 : 0
                    for frame in 0..<frames {
                        capture[frame] = data[frame * channels + offset]
                    }
                case 2: // Sum 1+2
                    if channels > 1 {
                        for frame in 0..<frames {
                            capture[frame] = (data[frame * channels] + data[frame * channels + 1]) * 0.5
                        }
                    } else {
                        memcpy(capture, data, frames * MemoryLayout<Float>.size)
                    }
                default: // Channel 1 (Default / Left)
                    for frame in 0..<frames {
                        capture[frame] = data[frame * channels]
                    }
                }
            }
        }
        _ = AmpAudioFIFOWrite(fifo, capture, Int32(frames))
    }

    private var consecutiveStarves = 0

    func render(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(list)
        guard frames > 0 else { return }
        guard frames <= capacity else {
            for buffer in abl {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }

        // Initial prime: wait until FIFO has a small cushion
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

        // Keep independent input/output clocks centered without throwing away
        // a chunk of waveform. Consume at most a few extra (or one fewer)
        // samples and interpolate them across this block. The old bulk drain
        // made an arbitrary phase jump that was audible as a click.
        let available = Int(AmpAudioFIFOAvailable(fifo))
        let target = max(preRollFrames, frames * 2)
        let queueError = available - target
        var requestedFrames = frames
        if queueError > frames {
            requestedFrames += min(4, max(1, queueError / max(frames, 1)))
        } else if queueError < -(frames / 2), available >= frames {
            requestedFrames = max(2, frames - 1)
        }
        requestedFrames = min(requestedFrames, capacity)

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
                // This curve meets the dry signal at 0.90 with matching
                // slope and approaches 0.98 smoothly. The previous branch
                // jumped from 0.98 to about 0.75 at the threshold, carving
                // audible notches into loud notes and the amp/beat mix.
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
