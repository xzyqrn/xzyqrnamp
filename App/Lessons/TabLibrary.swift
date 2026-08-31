import AppKit
import Foundation

struct BassTabItem: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var artist: String
    var tuning: String
    var sourceName: String
    var sourceURL: URL?
    var localBookmark: Data?
    var notes: String
    var favorite: Bool
    var lastOpened: Date?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        tuning: String = "E A D G",
        sourceName: String,
        sourceURL: URL? = nil,
        localBookmark: Data? = nil,
        notes: String = "",
        favorite: Bool = false,
        lastOpened: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.tuning = tuning
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.localBookmark = localBookmark
        self.notes = notes
        self.favorite = favorite
        self.lastOpened = lastOpened
    }
}

enum BassTabOpenResult {
    case text(String)
    case guitarPro(Data)
}

@MainActor
final class TabLibraryStore: ObservableObject {
    @Published private(set) var items: [BassTabItem] = []
    @Published var errorMessage: String?

    private static let storageKey = "xzyqrn.bassTabLibrary.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([BassTabItem].self, from: data) {
            items = decoded
        }
    }

    var sortedItems: [BassTabItem] {
        items.sorted {
            if $0.favorite != $1.favorite { return $0.favorite && !$1.favorite }
            return ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast)
        }
    }

    func songsterrSearchURL(artist: String, song: String) -> URL? {
        var components = URLComponents(string: "https://www.songsterr.com/")
        components?.queryItems = [
            URLQueryItem(name: "inst", value: "bass"),
            URLQueryItem(name: "pattern", value: [artist, song].filter { !$0.isEmpty }.joined(separator: " ")),
        ]
        return components?.url
    }

    func webSearchURL(artist: String, song: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        let query = ([artist, song].filter { !$0.isEmpty } + ["bass tab"]).joined(separator: " ")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    func openSearch(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func saveSearch(artist: String, song: String) {
        guard !song.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = songsterrSearchURL(artist: artist, song: song) else { return }
        let item = BassTabItem(
            title: song.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceName: "Songsterr search",
            sourceURL: url
        )
        items.insert(item, at: 0)
        persist()
    }

    func addLink(title: String, artist: String, urlText: String) {
        let normalized = urlText.contains("://") ? urlText : "https://\(urlText)"
        guard let url = URL(string: normalized), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            errorMessage = "Enter a valid http or https tab URL."
            return
        }
        items.insert(
            BassTabItem(
                title: title.isEmpty ? url.host ?? "Bass tab" : title,
                artist: artist,
                sourceName: url.host ?? "Web",
                sourceURL: url
            ),
            at: 0
        )
        persist()
    }

    func importLocalFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            items.insert(
                BassTabItem(
                    title: url.deletingPathExtension().lastPathComponent,
                    artist: "Local file",
                    sourceName: url.pathExtension.uppercased(),
                    localBookmark: bookmark
                ),
                at: 0
            )
            persist()
        } catch {
            errorMessage = "That tab could not be imported: \(error.localizedDescription)"
        }
    }

    func open(_ item: BassTabItem) -> BassTabOpenResult? {
        if let url = item.sourceURL {
            NSWorkspace.shared.open(url)
            touch(item.id)
            return nil
        }
        guard let bookmark = item.localBookmark else { return nil }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            touch(item.id)
            let ext = url.pathExtension.lowercased()
            if Self.guitarProExtensions.contains(ext) {
                return .guitarPro(data)
            }
            if let text = String(data: data.prefix(4_000_000), encoding: .utf8) {
                return .text(text)
            }
            errorMessage = "This file is not readable as a supported tab."
        } catch {
            errorMessage = "The local tab is no longer available. Import it again."
        }
        return nil
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].favorite.toggle()
        persist()
    }

    func update(_ item: BassTabItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        persist()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    private func touch(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastOpened = Date()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static let guitarProExtensions: Set<String> = ["gp", "gp3", "gp4", "gp5", "gpx"]
}
