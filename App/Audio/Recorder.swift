import AVFoundation
import CoreMedia
import Darwin
import Foundation

enum RecordMode: String, CaseIterable, Identifiable {
    case audio
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: return "Audio"
        case .video: return "Video"
        }
    }

    var fileExtension: String {
        switch self {
        case .audio: return "wav"
        case .video: return "mov"
        }
    }
}

protocol RecordedAudioSink: AnyObject {
    func appendRecordedAudio(_ samples: [Float], count: Int)
}

struct RecordingTake: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let date: Date
    let duration: TimeInterval

    var isVideo: Bool {
        ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }
}

/// Audio-thread capture into a lock-free FIFO; a background queue drains to WAV.
final class Recorder: @unchecked Sendable {
    private let fifo: UnsafeMutableRawPointer
    private let state: UnsafeMutableRawPointer
    private let queue = DispatchQueue(label: "com.herojay.Amplifier.recorder", qos: .userInitiated)
    private var file: AVAudioFile?
    private let sinkLock = NSLock()
    private weak var audioSink: RecordedAudioSink?

    var videoSink: RecordedAudioSink? {
        get {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            return audioSink
        }
        set {
            sinkLock.lock()
            audioSink = newValue
            sinkLock.unlock()
        }
    }

    var armed: Bool { AmpRecorderStateGet(state).armed }
    var recordBassOnly: Bool {
        get { AmpRecorderStateGet(state).recordBassOnly }
        set { AmpRecorderStateSetBassOnly(state, newValue) }
    }
    var capturingSystemOutput: Bool {
        get { AmpRecorderStateGet(state).capturingSystemOutput }
        set { AmpRecorderStateSetCapturingSystemOutput(state, newValue) }
    }
    var recordedFrames: Int64 { AmpRecorderStateGet(state).recordedFrames }
    var peak: Float { AmpRecorderStateGet(state).peak }
    var sampleRate: Double = 48000

    init() {
        fifo = AmpAudioFIFOCreate(48_000 * 12)!
        state = AmpRecorderStateCreate()!
    }

    deinit {
        AmpAudioFIFODestroy(fifo)
        AmpRecorderStateDestroy(state)
    }

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate > 1 ? sampleRate : 48000
    }

    func start(url: URL) throws {
        guard sampleRate > 1 else {
            throw NSError(
                domain: "xzyqrn amp",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Recorder has no sample rate yet. Power on first."]
            )
        }
        AmpAudioFIFOClear(fifo)
        AmpRecorderStateReset(state)
        try queue.sync {
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            file = try AVAudioFile(forWriting: url, settings: settings)
            AmpRecorderStateSetWriting(state, true)
        }
        AmpRecorderStateSetArmed(state, true)
        queue.async { [weak self] in
            self?.drainLoop()
        }
    }

    func push(_ samples: UnsafePointer<Float>, frames: Int) {
        guard armed, frames > 0 else { return }
        let written = Int(AmpAudioFIFOWrite(fifo, samples, Int32(frames)))
        guard written > 0 else { return }
        var localPeak: Float = 0
        for i in 0..<written {
            let a = fabsf(samples[i])
            if a > localPeak { localPeak = a }
        }
        AmpRecorderStateAddFrames(state, Int32(written), localPeak)
    }

    func stop() {
        AmpRecorderStateSetArmed(state, false)
        AmpRecorderStateSetWriting(state, false)
        queue.sync { [weak self] in
            self?.drainRemaining()
            self?.file = nil
        }
    }

    var elapsed: TimeInterval {
        guard sampleRate > 1 else { return 0 }
        return Double(recordedFrames) / sampleRate
    }

    private func drainLoop() {
        var scratch = [Float](repeating: 0, count: 4096)
        while AmpRecorderStateGet(state).writing {
            let n = Int(AmpAudioFIFORead(fifo, &scratch, 4096))
            if n > 0 {
                write(scratch, count: n)
            } else {
                usleep(4000)
            }
        }
    }

    private func drainRemaining() {
        var scratch = [Float](repeating: 0, count: 4096)
        while true {
            let n = Int(AmpAudioFIFORead(fifo, &scratch, 4096))
            if n <= 0 { break }
            write(scratch, count: n)
        }
    }

    private func write(_ samples: [Float], count: Int) {
        guard let file else { return }
        let fmt = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)),
              let dest = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            memcpy(dest, base, count * MemoryLayout<Float>.size)
        }
        do {
            try file.write(from: buffer)
        } catch {
            NSLog("xzyqrn amp recorder write failed: \(error)")
        }
        videoSink?.appendRecordedAudio(samples, count: count)
    }
}

enum RecordingStore {
    static func directory() throws -> URL {
        try AmpPaths.subdirectory("Recordings")
    }

    static func newURL(mode: RecordMode = .audio) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = "Take \(formatter.string(from: Date())).\(mode.fileExtension)"
        return try directory().appendingPathComponent(name)
    }

    static func temporaryAudioURL(matching takeURL: URL) -> URL {
        let name = takeURL.deletingPathExtension().lastPathComponent + ".wav"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    static func loadAll() -> [RecordingTake] {
        do {
            let dir = try directory()
            let files = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            return files.compactMap { url -> RecordingTake? in
                let ext = url.pathExtension.lowercased()
                guard ["wav", "mov", "mp4", "m4v"].contains(ext) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let date = values?.contentModificationDate ?? Date()
                let duration: TimeInterval
                if ext == "wav" {
                    duration = (try? AVAudioFile(forReading: url)).map {
                        Double($0.length) / max($0.processingFormat.sampleRate, 1)
                    } ?? 0
                } else {
                    let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
                    duration = seconds.isFinite ? seconds : 0
                }
                return RecordingTake(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    date: date,
                    duration: duration
                )
            }
            .sorted { $0.date > $1.date }
        } catch {
            return []
        }
    }

    static func delete(_ take: RecordingTake) {
        try? FileManager.default.removeItem(at: take.url)
    }
}
