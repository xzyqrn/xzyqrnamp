import AppKit
import AVFoundation
import AVKit
import SwiftUI

struct RecordModePicker: View {
    @Binding var selection: RecordMode
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            modeTab(.audio, title: "Audio", icon: "waveform")
            modeTab(.video, title: "Video", icon: "video")
        }
        .background(AmpTheme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(AmpTheme.line, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .help("Audio writes a WAV take. Video adds the camera and keeps the same bass / mix recording.")
    }

    private func modeTab(_ mode: RecordMode, title: String, icon: String) -> some View {
        Button {
            selection = mode
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title.uppercased())
                    .font(AmpTheme.label(9))
                    .tracking(1.0)
            }
            .foregroundStyle(selection == mode ? AmpTheme.bg : AmpTheme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selection == mode ? AmpTheme.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(2)
    }
}

struct DraggableCameraPreviewHost: View {
    @EnvironmentObject private var session: AmpSession
    var placementID: String
    var bottomReserve: CGFloat

    var body: some View {
        if session.recordMode == .video {
            DraggableCameraPreview(
                session: session.cameraCaptureSession,
                isRecording: session.isRecording,
                cameraName: session.cameraPreviewOn ? session.selectedCameraName : "Starting camera…",
                placementID: placementID
            )
            .padding(.trailing, 16)
            .padding(.bottom, bottomReserve)
        }
    }
}

struct DraggableCameraPreview: View {
    let session: AVCaptureSession
    var isRecording: Bool
    var cameraName: String
    var placementID: String

    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        CameraPreviewCard(
            session: session,
            isRecording: isRecording,
            cameraName: cameraName,
            isDragging: isDragging
        )
        .offset(offset)
        .highPriorityGesture(dragGesture)
        .onHover { hovering in
            guard !isDragging else { return }
            if hovering {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help("Drag to move the camera preview")
        .onAppear(perform: restore)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDragging {
                    dragStart = offset
                    isDragging = true
                    NSCursor.closedHand.set()
                }
                offset = CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                isDragging = false
                NSCursor.openHand.set()
                persist()
            }
    }

    private var defaultsKey: String { "xzyqrn.cameraPreviewOffset.\(placementID)" }

    private func restore() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey + ".w") != nil else { return }
        offset = CGSize(
            width: defaults.double(forKey: defaultsKey + ".w"),
            height: defaults.double(forKey: defaultsKey + ".h")
        )
        dragStart = offset
    }

    private func persist() {
        UserDefaults.standard.set(Double(offset.width), forKey: defaultsKey + ".w")
        UserDefaults.standard.set(Double(offset.height), forKey: defaultsKey + ".h")
    }
}

struct CameraPreviewCard: View {
    let session: AVCaptureSession
    var isRecording: Bool
    var cameraName: String
    var isDragging: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AmpTheme.faint)
                Circle()
                    .fill(isRecording ? AmpTheme.danger : AmpTheme.ok)
                    .frame(width: 6, height: 6)
                    .shadow(color: (isRecording ? AmpTheme.danger : AmpTheme.ok).opacity(0.85), radius: 4)
                Text(isRecording ? "REC" : "CAM")
                    .font(AmpTheme.label(8))
                    .tracking(1.2)
                    .foregroundStyle(AmpTheme.text)
                Text(cameraName)
                    .font(AmpTheme.caption(9))
                    .foregroundStyle(AmpTheme.faint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(AmpTheme.surfaceRaised)

            CameraPreviewView(session: session)
                .frame(width: 220, height: 124)
                .background(AmpTheme.inset)
        }
        .frame(width: 220)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isDragging ? AmpTheme.accent.opacity(0.7) : AmpTheme.lineStrong, lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(isDragging ? 0.55 : 0.38), radius: isDragging ? 18 : 12, y: 6)
        .scaleEffect(isDragging ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }
}

final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    override var wantsDefaultClipping: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class VideoTakePanelController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    var onClose: (() -> Void)?

    func show(take: RecordingTake) {
        close()
        let player = AVPlayer(url: take.url)
        self.player = player

        let playerView = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = take.name
        window.contentView = playerView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 280)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onClose?()
            }
        }
        player.play()
    }

    func close() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        window = nil
        onClose?()
    }
}
