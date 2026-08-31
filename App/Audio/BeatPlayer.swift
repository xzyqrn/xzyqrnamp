import AVFoundation
import Foundation

enum BeatStyle: Int, CaseIterable, Identifiable {
    case rock = 0
    case funk = 1
    case hiphop = 2
    case latin = 3
    case blues = 4
    case soul = 5
    case reggae = 6
    case disco = 7
    case metal = 8
    case jazz = 9
    case pop = 10
    case electronic = 11

    var id: String { fileStem }

    var title: String {
        switch self {
        case .rock: return "Rock"
        case .funk: return "Funk"
        case .hiphop: return "Hip-Hop"
        case .latin: return "Latin"
        case .blues: return "Blues"
        case .soul: return "Soul"
        case .reggae: return "Reggae"
        case .disco: return "Disco"
        case .metal: return "Metal"
        case .jazz: return "Jazz"
        case .pop: return "Pop"
        case .electronic: return "Electronic"
        }
    }

    var fileStem: String {
        switch self {
        case .rock: return "rock"
        case .funk: return "funk"
        case .hiphop: return "hiphop"
        case .latin: return "latin"
        case .blues: return "blues"
        case .soul: return "soul"
        case .reggae: return "reggae"
        case .disco: return "disco"
        case .metal: return "metal"
        case .jazz: return "jazz"
        case .pop: return "pop"
        case .electronic: return "electronic"
        }
    }
}

/// Zero-allocation, sample-accurate loop player for real-time audio threads.
final class BeatPlayer: @unchecked Sendable {
    struct Loop {
        let samples: [Float]
        let sampleRate: Double
    }

    // One 100 BPM source per style. Playback rate supplies continuous tempo
    // without allocations or lookups on the real-time render thread.
    private let loops: [Loop?]
    private var playhead: Double = 0
    private var lastStyleIndex: Int = -1

    var playing = false
    var volume: Float = 0.5
    var style = BeatStyle.rock
    var bpm: Double = 100

    init() {
        var loaded: [Loop?] = Array(repeating: nil, count: BeatStyle.allCases.count)
        for style in BeatStyle.allCases {
            loaded[style.rawValue] = Self.load(named: "\(style.fileStem)-100")
        }
        loops = loaded
    }

    var hasLoops: Bool {
        loops.contains { $0 != nil }
    }

    func select(style: BeatStyle, bpm: Double) {
        self.style = style
        self.bpm = min(max(bpm, 40), 240)
    }

    func mix(into output: UnsafeMutablePointer<Float>, frames: Int, engineRate: Double) {
        guard playing, frames > 0, engineRate > 1 else { return }
        let sIdx = style.rawValue
        guard sIdx >= 0, sIdx < loops.count,
              let loop = loops[sIdx], loop.samples.count > 1, loop.sampleRate > 1 else { return }

        if sIdx != lastStyleIndex {
            playhead = 0
            lastStyleIndex = sIdx
        }

        let n = loop.samples.count
        let step = loop.sampleRate / engineRate * min(max(bpm, 40), 240) / 100.0
        let vol = volume
        var pos = playhead
        let span = Double(n)

        loop.samples.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            for i in 0..<frames {
                while pos >= span { pos -= span }
                if pos < 0 { pos = 0 }
                let i0 = Int(pos) % n
                let i1 = (i0 + 1) % n
                let frac = Float(pos - Double(Int(pos)))
                let sample = ptr[i0] + (ptr[i1] - ptr[i0]) * frac
                output[i] += sample * vol
                pos += step
            }
        }
        playhead = pos
    }

    private static func load(named name: String) -> Loop? {
        let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Beats")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
        guard let url else { return nil }
        do {
            let file = try AVAudioFile(forReading: url)
            let frames = AVAudioFrameCount(file.length)
            guard frames > 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                return nil
            }
            try file.read(into: buffer)
            guard let channels = buffer.floatChannelData else { return nil }
            let n = Int(buffer.frameLength)
            let chCount = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: n)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<chCount { sum += channels[c][i] }
                mono[i] = sum / Float(max(chCount, 1))
            }
            return Loop(samples: mono, sampleRate: file.processingFormat.sampleRate)
        } catch {
            NSLog("xzyqrn amp beat load failed for \(name): \(error)")
            return nil
        }
    }
}
