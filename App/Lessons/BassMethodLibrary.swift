import AVFoundation
import Foundation

struct BassMethodBook: Identifiable, Hashable {
    let id: Int
    let title: String
    let focus: String
    let summary: String
    /// One-based page number in the scanned PDF.
    let startPage: Int

    static let all: [BassMethodBook] = [
        BassMethodBook(
            id: 1,
            title: "Book 1",
            focus: "Fundamentals",
            summary: "Setup, tuning, posture, note reading, open strings, rhythm, and early position work.",
            startPage: 8
        ),
        BassMethodBook(
            id: 2,
            title: "Book 2",
            focus: "Fretboard & harmony",
            summary: "Movable shapes, tablature, scales, key signatures, blues language, and syncopation.",
            startPage: 54
        ),
        BassMethodBook(
            id: 3,
            title: "Book 3",
            focus: "Groove & technique",
            summary: "Chromatic movement, sixteenth notes, chord tones, pentatonics, articulation, and slap bass.",
            startPage: 100
        ),
    ]
}

struct BassMethodTrack: Identifiable, Hashable {
    let bookID: Int
    let number: Int
    let url: URL

    var id: String { url.path }
    var progressID: String { "book-\(bookID)-track-\(number)" }
    var title: String { "Track \(number)" }
}

@MainActor
final class BassMethodLibrary: ObservableObject {
    @Published private(set) var folderURL: URL?
    @Published private(set) var pdfURL: URL?
    @Published private(set) var tracksByBook: [Int: [BassMethodTrack]] = [:]
    @Published var errorMessage: String?
    @Published private(set) var completedTrackIDs: Set<String> = []
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var savedPages: [Int: Int] = [:]

    private static let bookmarkKey = "xzyqrn.bassMethodFolderBookmark"
    private static let completedKey = "xzyqrn.bassMethodCompletedTracks"
    private static let notesKey = "xzyqrn.bassMethodNotes"
    private static let pagesKey = "xzyqrn.bassMethodSavedPages"
    private var securityScopedURL: URL?

    var isConnected: Bool { pdfURL != nil }

    init() {
        completedTrackIDs = Set(UserDefaults.standard.stringArray(forKey: Self.completedKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.notesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            notes = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.pagesKey),
           let decoded = try? JSONDecoder().decode([Int: Int].self, from: data) {
            savedPages = decoded
        }
        restoreBookmark()
    }

    func tracks(for bookID: Int) -> [BassMethodTrack] {
        tracksByBook[bookID] ?? []
    }

    func isCompleted(_ track: BassMethodTrack) -> Bool {
        completedTrackIDs.contains(track.progressID)
    }

    func toggleCompleted(_ track: BassMethodTrack) {
        if completedTrackIDs.contains(track.progressID) {
            completedTrackIDs.remove(track.progressID)
        } else {
            completedTrackIDs.insert(track.progressID)
        }
        UserDefaults.standard.set(Array(completedTrackIDs).sorted(), forKey: Self.completedKey)
    }

    func completedCount(for bookID: Int) -> Int {
        tracks(for: bookID).filter(isCompleted).count
    }

    func note(for track: BassMethodTrack) -> String {
        notes[track.progressID] ?? ""
    }

    func setNote(_ text: String, for track: BassMethodTrack) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { notes.removeValue(forKey: track.progressID) }
        else { notes[track.progressID] = text }
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: Self.notesKey)
        }
    }

    func page(for book: BassMethodBook) -> Int {
        savedPages[book.id] ?? book.startPage
    }

    func savePage(_ page: Int, for book: BassMethodBook) {
        savedPages[book.id] = page
        if let data = try? JSONEncoder().encode(savedPages) {
            UserDefaults.standard.set(data, forKey: Self.pagesKey)
        }
    }

    func connect(to url: URL) {
        releaseCurrentFolder()

        let accessed = url.startAccessingSecurityScopedResource()
        guard accessed else {
            errorMessage = "macOS did not grant access to that folder. Select the Bass Method folder again."
            return
        }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            securityScopedURL = url
            scan(url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            errorMessage = "The lesson folder could not be remembered: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        releaseCurrentFolder()
        folderURL = nil
        pdfURL = nil
        tracksByBook = [:]
        errorMessage = nil
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw LessonLibraryError.accessDenied
            }
            securityScopedURL = url
            if stale {
                let refreshed = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
            }
            scan(url)
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            errorMessage = "Reconnect the Bass Method folder to restore this lesson."
        }
    }

    private func scan(_ root: URL) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            errorMessage = "The selected folder could not be read."
            return
        }

        var foundPDF: URL?
        var foundTracks: [Int: [BassMethodTrack]] = [:]

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "pdf", foundPDF == nil {
                foundPDF = fileURL
                continue
            }
            guard ext == "mp3", let bookID = Self.bookID(for: fileURL),
                  let number = Self.trailingNumber(in: fileURL.deletingPathExtension().lastPathComponent) else {
                continue
            }
            foundTracks[bookID, default: []].append(
                BassMethodTrack(bookID: bookID, number: number, url: fileURL)
            )
        }

        for bookID in foundTracks.keys {
            foundTracks[bookID]?.sort { lhs, rhs in
                if lhs.number == rhs.number { return lhs.url.lastPathComponent < rhs.url.lastPathComponent }
                return lhs.number < rhs.number
            }
        }

        guard let foundPDF else {
            errorMessage = "No PDF was found. Select the main “Ed Friedland - Bass Method (Hal Leonard)” folder."
            folderURL = nil
            pdfURL = nil
            tracksByBook = [:]
            return
        }

        folderURL = root
        pdfURL = foundPDF
        tracksByBook = foundTracks
        errorMessage = nil
    }

    private func releaseCurrentFolder() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    private static func bookID(for url: URL) -> Int? {
        let path = url.path.lowercased()
        if path.contains("book iii") { return 3 }
        if path.contains("book ii") { return 2 }
        if path.contains("book i") { return 1 }
        return nil
    }

    private static func trailingNumber(in name: String) -> Int? {
        let digits = name.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits))
    }
}

private enum LessonLibraryError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        "The saved lesson folder is no longer accessible."
    }
}

@MainActor
final class BassMethodAudioPlayer: ObservableObject {
    @Published private(set) var currentTrack: BassMethodTrack?
    @Published private(set) var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var volume: Double = 0.8 {
        didSet {
            volume = min(max(volume, 0), 1)
            player?.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }
    @Published var backingTrackOnly = false {
        didSet { player?.pan = backingTrackOnly ? -1 : 0 }
    }

    private static let volumeKey = "xzyqrn.bassMethodTrackVolume"
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init() {
        if UserDefaults.standard.object(forKey: Self.volumeKey) != nil {
            volume = min(max(UserDefaults.standard.double(forKey: Self.volumeKey), 0), 1)
        }
    }

    func play(_ track: BassMethodTrack) {
        if currentTrack == track, let player {
            if player.isPlaying {
                pause()
            } else {
                player.play()
                isPlaying = true
                startTimer()
            }
            return
        }

        do {
            stop()
            let next = try AVAudioPlayer(contentsOf: track.url)
            next.pan = backingTrackOnly ? -1 : 0
            next.volume = Float(volume)
            next.prepareToPlay()
            next.play()
            player = next
            currentTrack = track
            duration = next.duration
            currentTime = 0
            isPlaying = true
            startTimer()
        } catch {
            stop()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying, player.currentTime >= player.duration - 0.05 {
                    self.isPlaying = false
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
