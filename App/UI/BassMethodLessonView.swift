import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct BassMethodLessonView: View {
    @EnvironmentObject private var library: BassMethodLibrary
    @StateObject private var audio = BassMethodAudioPlayer()
    @State private var selectedBook = BassMethodBook.all[0]
    @State private var showFolderImporter = false
    @State private var currentPDFPage = BassMethodBook.all[0].startPage
    @State private var showNotes = false
    @State private var draftNote = ""

    var body: some View {
        VStack(spacing: 0) {
            lessonHeader
            if let pdfURL = library.pdfURL {
                HSplitView {
                    lessonSidebar
                        .frame(minWidth: 260, idealWidth: 290, maxWidth: 340)
                    BassMethodPDFView(url: pdfURL, pageNumber: $currentPDFPage)
                        .frame(minWidth: 620)
                }
                lessonTransport
            } else {
                connectPrompt
            }
        }
        .background(AmpTheme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 700)
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                library.connect(to: url)
            }
        }
        .alert(
            "Bass Method",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onDisappear { audio.stop() }
        .onAppear { currentPDFPage = library.page(for: selectedBook) }
        .onChange(of: selectedBook) { _, book in
            currentPDFPage = library.page(for: book)
        }
        .onChange(of: currentPDFPage) { _, page in
            library.savePage(page, for: selectedBook)
        }
    }

    private var lessonHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "book.pages.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AmpTheme.accent)
                .frame(width: 38, height: 38)
                .background(AmpTheme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("HAL LEONARD BASS METHOD")
                    .font(AmpTheme.display(17, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(AmpTheme.text)
                Text("Complete Edition · Ed Friedland · Second Edition")
                    .font(AmpTheme.caption(11))
                    .foregroundStyle(AmpTheme.muted)
            }

            Spacer()

            if let folderURL = library.folderURL {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("LOCAL LESSON")
                        .font(AmpTheme.label(9))
                        .tracking(1.4)
                        .foregroundStyle(AmpTheme.accent)
                    Text(folderURL.lastPathComponent)
                        .font(AmpTheme.caption(10))
                        .foregroundStyle(AmpTheme.faint)
                        .lineLimit(1)
                }
                Button("Change folder") { showFolderImporter = true }
                    .buttonStyle(StudioButton())
                Button("Disconnect") {
                    audio.stop()
                    library.disconnect()
                }
                .buttonStyle(StudioButton())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(AmpTheme.bg.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().fill(AmpTheme.line).frame(height: 1)
        }
    }

    private var lessonSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Course")
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(BassMethodBook.all) { book in
                Button {
                    selectedBook = book
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(book.title.uppercased())
                                .font(AmpTheme.label(11))
                                .tracking(1.1)
                            Spacer()
                            Text("\(library.completedCount(for: book.id))/\(library.tracks(for: book.id).count)")
                                .font(AmpTheme.mono(9))
                                .foregroundStyle(selectedBook == book ? AmpTheme.bg.opacity(0.65) : AmpTheme.faint)
                        }
                        Text(book.focus)
                            .font(AmpTheme.display(15, weight: .semibold))
                        Text(book.summary)
                            .font(AmpTheme.caption(10))
                            .foregroundStyle(selectedBook == book ? AmpTheme.bg.opacity(0.72) : AmpTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(selectedBook == book ? AmpTheme.bg : AmpTheme.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectedBook == book ? AmpTheme.accent : AmpTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            SectionLabel(text: "Audio exercises")
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 6)

            List {
                ForEach(library.tracks(for: selectedBook.id)) { track in
                    HStack(spacing: 8) {
                        Button {
                            audio.play(track)
                        } label: {
                        Image(systemName: audio.currentTrack == track && audio.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(audio.currentTrack == track ? AmpTheme.accent : AmpTheme.faint)
                            .frame(width: 14)
                        }
                        .buttonStyle(.plain)
                        Text(track.title)
                            .font(AmpTheme.mono(11))
                            .foregroundStyle(AmpTheme.text)
                        Spacer()
                        if !library.note(for: track).isEmpty {
                            Image(systemName: "note.text")
                                .font(.system(size: 9))
                                .foregroundStyle(AmpTheme.muted)
                        }
                        Button {
                            library.toggleCompleted(track)
                        } label: {
                            Image(systemName: library.isCompleted(track) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(library.isCompleted(track) ? AmpTheme.accent : AmpTheme.faint)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { audio.play(track) }
                    .listRowBackground(AmpTheme.surface)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Text("Uses your local copy only. The book and recordings are not copied into the app or uploaded.")
                .font(AmpTheme.caption(9))
                .foregroundStyle(AmpTheme.faint)
                .padding(12)
        }
        .background(AmpTheme.surface)
    }

    private var lessonTransport: some View {
        HStack(spacing: 14) {
            Button {
                playPrevious()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(StudioButton())
            .disabled(audio.currentTrack == nil)

            Button {
                if let current = audio.currentTrack {
                    audio.play(current)
                } else if let first = library.tracks(for: selectedBook.id).first {
                    audio.play(first)
                }
            } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(StudioButton(prominent: true))

            Button {
                playNext()
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(StudioButton())
            .disabled(audio.currentTrack == nil)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(audio.currentTrack.map { "\(selectedBook.title) · \($0.title)" } ?? "Choose an audio exercise")
                        .font(AmpTheme.caption(11))
                        .foregroundStyle(AmpTheme.text)
                    Spacer()
                    Text("\(time(audio.currentTime)) / \(time(audio.duration))")
                        .font(AmpTheme.mono(10))
                        .foregroundStyle(AmpTheme.faint)
                }
                Slider(
                    value: Binding(
                        get: { audio.currentTime },
                        set: { audio.seek(to: $0) }
                    ),
                    in: 0 ... max(audio.duration, 0.01)
                )
                .tint(AmpTheme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: audio.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("TRACK")
                        .font(AmpTheme.label(9))
                        .tracking(1.2)
                    Spacer()
                    Text("\(Int(audio.volume * 100))%")
                        .font(AmpTheme.mono(9))
                }
                .foregroundStyle(AmpTheme.muted)
                Slider(value: $audio.volume, in: 0 ... 1)
                    .tint(AmpTheme.accent)
            }
            .frame(width: 125)
            .help("Lesson track volume")

            LEDToggle(isOn: $audio.backingTrackOnly, title: "Backing only")
                .help("The source recordings place bass on the right and accompaniment on the left. Backing only plays the left channel.")

            Button {
                guard let track = audio.currentTrack else { return }
                draftNote = library.note(for: track)
                showNotes = true
            } label: {
                Image(systemName: "note.text")
            }
            .buttonStyle(StudioButton())
            .disabled(audio.currentTrack == nil)
            .popover(isPresented: $showNotes, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(audio.currentTrack?.title ?? "Exercise note")
                        .font(AmpTheme.display(14, weight: .semibold))
                    TextEditor(text: $draftNote)
                        .font(AmpTheme.caption(12))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(AmpTheme.inset)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Spacer()
                        Button("Save") {
                            if let track = audio.currentTrack { library.setNote(draftNote, for: track) }
                            showNotes = false
                        }
                        .buttonStyle(StudioButton(prominent: true))
                    }
                }
                .padding(12)
                .frame(width: 320, height: 210)
                .background(AmpTheme.surface)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AmpTheme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(AmpTheme.line).frame(height: 1)
        }
    }

    private var connectPrompt: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(AmpTheme.accent)
            VStack(spacing: 7) {
                Text("Connect your Bass Method folder")
                    .font(AmpTheme.display(22, weight: .bold))
                    .foregroundStyle(AmpTheme.text)
                Text("Select the main folder containing the Complete Edition PDF and the Book I, II, and III MP3 folders.")
                    .font(AmpTheme.caption(13))
                    .foregroundStyle(AmpTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
            }
            Button("Choose lesson folder") { showFolderImporter = true }
                .buttonStyle(StudioButton(prominent: true))
            Text("The app stores a secure bookmark so you only need to choose it once.")
                .font(AmpTheme.caption(10))
                .foregroundStyle(AmpTheme.faint)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playPrevious() {
        let tracks = library.tracks(for: selectedBook.id)
        guard let current = audio.currentTrack,
              let index = tracks.firstIndex(of: current), index > 0 else { return }
        audio.play(tracks[index - 1])
    }

    private func playNext() {
        let tracks = library.tracks(for: selectedBook.id)
        guard let current = audio.currentTrack,
              let index = tracks.firstIndex(of: current), index + 1 < tracks.count else { return }
        audio.play(tracks[index + 1])
    }

    private func time(_ value: TimeInterval) -> String {
        guard value.isFinite, value > 0 else { return "00:00" }
        return String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

private struct BassMethodPDFView: NSViewRepresentable {
    let url: URL
    @Binding var pageNumber: Int

    final class Coordinator: NSObject {
        var loadedURL: URL?
        var shownPage = -1
        var observer: NSObjectProtocol?
        var onPageChange: ((Int) -> Void)?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak view, weak coordinator = context.coordinator] _ in
            guard let view, let document = view.document, let page = view.currentPage else { return }
            let number = document.index(for: page) + 1
            coordinator?.shownPage = number
            coordinator?.onPageChange?(number)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onPageChange = { newPage in
            if pageNumber != newPage { pageNumber = newPage }
        }
        if context.coordinator.loadedURL != url {
            view.document = PDFDocument(url: url)
            context.coordinator.loadedURL = url
            context.coordinator.shownPage = -1
        }
        guard context.coordinator.shownPage != pageNumber,
              let document = view.document,
              let page = document.page(at: max(0, pageNumber - 1)) else { return }
        view.go(to: page)
        context.coordinator.shownPage = pageNumber
    }
}
