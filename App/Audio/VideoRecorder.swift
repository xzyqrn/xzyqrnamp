import AVFoundation
import CoreMedia
import Foundation

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

enum VideoCaptureResult {
    case success
    case noVideoFrames
    case failed(String)
}

/// Camera capture plus realtime mux of the amp's recorded audio into a .mov.
final class VideoRecorder: NSObject, RecordedAudioSink, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let captureSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.herojay.Amplifier.camera.session")
    private let writerQueue = DispatchQueue(label: "com.herojay.Amplifier.camera.writer")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var currentDeviceID: String?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioFormat: CMAudioFormatDescription?
    private var isWriting = false
    private var sessionStarted = false
    private var audioFrames: Int64 = 0
    private var videoFrameCount = 0
    private var firstVideoPTS: CMTime?
    private var sampleRate: Double = 48000
    private var videoSize = CGSize(width: 1280, height: 720)

    static func cameras() -> [CameraInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    func ensureRunning(deviceID: String?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureSession(deviceID: deviceID)
                    if !self.captureSession.isRunning {
                        self.captureSession.startRunning()
                    }
                    if let device = self.deviceInput?.device {
                        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                        self.videoSize = CGSize(
                            width: CGFloat(max(2, Int(dims.width) & ~1)),
                            height: CGFloat(max(2, Int(dims.height) & ~1))
                        )
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    func startWriting(to url: URL, sampleRate: Double) throws {
        try writerQueue.sync {
            try self.makeWriter(url: url, sampleRate: sampleRate)
            self.isWriting = true
            self.sessionStarted = false
            self.audioFrames = 0
            self.videoFrameCount = 0
            self.firstVideoPTS = nil
        }
    }

    func finishWriting() async -> VideoCaptureResult {
        await withCheckedContinuation { cont in
            writerQueue.async {
                self.isWriting = false
                let frames = self.videoFrameCount
                let started = self.sessionStarted
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                guard let writer = self.writer else {
                    self.clearWriter()
                    cont.resume(returning: .failed("Video recording did not start."))
                    return
                }
                self.clearWriter()
                if writer.status == .failed {
                    cont.resume(returning: .failed(writer.error?.localizedDescription ?? "Couldn't finish the video take."))
                    return
                }
                if !started || frames == 0 {
                    writer.cancelWriting()
                    cont.resume(returning: .noVideoFrames)
                    return
                }
                writer.finishWriting {
                    if writer.status != .completed {
                        let message = writer.error?.localizedDescription ?? "Couldn't finish the video take."
                        cont.resume(returning: .failed(message))
                    } else {
                        cont.resume(returning: .success)
                    }
                }
            }
        }
    }

    func abortWriting() {
        writerQueue.sync {
            self.isWriting = false
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.writer?.cancelWriting()
            self.clearWriter()
        }
    }

    func appendRecordedAudio(_ samples: [Float], count: Int) {
        guard count > 0 else { return }
        let copy = Array(samples.prefix(count))
        writerQueue.async { [weak self] in
            self?.writeAudio(copy)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        writeVideo(sampleBuffer)
    }

    private func configureSession(deviceID: String?) throws {
        let cameras = Self.cameras()
        guard !cameras.isEmpty else {
            throw Self.error(31, "No camera is available.")
        }
        let chosenID = (deviceID?.isEmpty == false ? deviceID : nil)
            ?? cameras.first?.id
        guard let chosenID,
              let device = AVCaptureDevice(uniqueID: chosenID) ?? AVCaptureDevice.default(for: .video) else {
            throw Self.error(31, "No camera is available.")
        }

        if captureSession.isRunning, currentDeviceID == device.uniqueID, deviceInput != nil {
            return
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        if let deviceInput {
            captureSession.removeInput(deviceInput)
            self.deviceInput = nil
        }
        if captureSession.outputs.contains(videoOutput) {
            captureSession.removeOutput(videoOutput)
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw Self.error(32, "Couldn't open \(device.localizedName).")
        }
        captureSession.addInput(input)
        deviceInput = input
        currentDeviceID = device.uniqueID

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: writerQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            throw Self.error(32, "Couldn't start the camera capture output.")
        }
        captureSession.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = true
            }
        }

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        videoSize = CGSize(
            width: CGFloat(max(2, Int(dims.width) & ~1)),
            height: CGFloat(max(2, Int(dims.height) & ~1))
        )
    }

    private func makeWriter(url: URL, sampleRate: Double) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_500_000, width * height * 4),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw Self.error(33, "Couldn't create the video take.")
        }
        writer.add(videoInput)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else {
            throw Self.error(33, "Couldn't create the video audio track.")
        }

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.audioOutputSettings(sampleRate: sampleRate),
            sourceFormatHint: format
        )
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw Self.error(33, "Couldn't create the video audio track.")
        }
        writer.add(audioInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.startWriting() else {
            throw writer.error ?? Self.error(33, "Couldn't start the video take.")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.audioFormat = format
        self.sampleRate = sampleRate > 1 ? sampleRate : 48000
    }

    private func ensureSessionStarted() {
        guard !sessionStarted, let writer, writer.status == .writing else { return }
        writer.startSession(atSourceTime: .zero)
        sessionStarted = true
    }

    private func writeVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting,
              let writer, writer.status == .writing,
              let videoInput, videoInput.isReadyForMoreMediaData,
              let adaptor,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstVideoPTS == nil {
            firstVideoPTS = pts
        }
        guard let firstVideoPTS else { return }
        let relative = CMTimeSubtract(pts, firstVideoPTS)
        ensureSessionStarted()
        if adaptor.append(pixelBuffer, withPresentationTime: relative) {
            videoFrameCount += 1
        }
    }

    private func writeAudio(_ samples: [Float]) {
        guard isWriting,
              let writer, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData,
              let audioFormat else { return }
        let count = samples.count
        guard count > 0 else { return }
        let rate = Int32(max(1, sampleRate.rounded()))
        let pts = CMTime(value: audioFrames, timescale: rate)
        audioFrames += Int64(count)

        var sampleBuffer: CMSampleBuffer?
        let status = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            var block: CMBlockBuffer?
            var err = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: raw.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: raw.count,
                flags: 0,
                blockBufferOut: &block
            )
            guard err == noErr, let block else { return err }
            err = CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: raw.count
            )
            guard err == noErr else { return err }
            return CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: audioFormat,
                sampleCount: count,
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            )
        }
        guard status == noErr, let sampleBuffer else { return }
        ensureSessionStarted()
        _ = audioInput.append(sampleBuffer)
    }

    private func clearWriter() {
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        audioFormat = nil
        sessionStarted = false
        firstVideoPTS = nil
    }

    private static func audioOutputSettings(sampleRate: Double) -> [String: Any] {
        if sampleRate == 44100 || sampleRate == 48000 {
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 256_000
            ]
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "xzyqrn amp", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
