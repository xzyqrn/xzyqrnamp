import SwiftUI
import UniformTypeIdentifiers

struct TabLibraryView: View {
    @EnvironmentObject private var store: TabLibraryStore
    @State private var artist = ""
    @State private var song = ""
    @State private var linkText = ""
    @State private var selectedID: UUID?
    @State private var localContent: BassTabOpenResult?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HSplitView {
                libraryList
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                detail
                    .frame(minWidth: 620)
            }
        }
        .background(AmpTheme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 680)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [
                .plainText,
                .xml,
                UTType(filenameExtension: "musicxml") ?? .xml,
                UTType(filenameExtension: "gp") ?? .data,
                UTType(filenameExtension: "gp3") ?? .data,
                UTType(filenameExtension: "gp4") ?? .data,
                UTType(filenameExtension: "gp5") ?? .data,
                UTType(filenameExtension: "gpx") ?? .data,
            ],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first { store.importLocalFile(url) }
        }
        .alert(
            "Bass Tabs",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) { Button("OK", role: .cancel) { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "") }
        .onChange(of: selectedID) { _, _ in localContent = nil }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BASS TAB LIBRARY")
                        .font(AmpTheme.display(18, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(AmpTheme.text)
                    Text("Discover licensed tabs on the web or practice from your own files")
                        .font(AmpTheme.caption(11))
                        .foregroundStyle(AmpTheme.muted)
                }
                Spacer()
                Button("Import tab") { showImporter = true }
                    .buttonStyle(StudioButton())
            }

            HStack(spacing: 8) {
                TextField("Artist", text: $artist)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(AmpTheme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 210)
                TextField("Song", text: $song)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(AmpTheme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(minWidth: 240)
                Button("Search Songsterr") {
                    if let url = store.songsterrSearchURL(artist: artist, song: song) { store.openSearch(url) }
                }
                .buttonStyle(StudioButton(prominent: true))
                Button("Search web") {
                    if let url = store.webSearchURL(artist: artist, song: song) { store.openSearch(url) }
                }
                .buttonStyle(StudioButton())
                Button("Save search") { store.saveSearch(artist: artist, song: song) }
                    .buttonStyle(StudioButton())
            }
        }
        .padding(16)
        .background(AmpTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(AmpTheme.line).frame(height: 1) }
    }

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Saved tabs")
                .padding(.horizontal, 12)
                .padding(.top, 12)
            if store.items.isEmpty {
                Text("Save a web search, paste a tab link, or import a local tab file.")
                    .font(AmpTheme.caption(11))
                    .foregroundStyle(AmpTheme.muted)
                    .padding(12)
                Spacer()
            } else {
                List(store.sortedItems, selection: $selectedID) { item in
                    HStack(spacing: 8) {
                        Button { store.toggleFavorite(item.id) } label: {
                            Image(systemName: item.favorite ? "star.fill" : "star")
                                .foregroundStyle(item.favorite ? AmpTheme.warn : AmpTheme.faint)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(AmpTheme.caption(12))
                                .foregroundStyle(AmpTheme.text)
                                .lineLimit(1)
                            Text([item.artist, item.sourceName].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(AmpTheme.caption(9))
                                .foregroundStyle(AmpTheme.faint)
                        }
                        Spacer()
                    }
                    .tag(item.id)
                    .listRowBackground(AmpTheme.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            VStack(spacing: 7) {
                SectionLabel(text: "Add a direct link")
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("https://…", text: $linkText)
                    .textFieldStyle(.plain)
                    .padding(7)
                    .background(AmpTheme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Button("Save link") {
                    store.addLink(title: song, artist: artist, urlText: linkText)
                    linkText = ""
                }
                .buttonStyle(StudioButton())
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(12)
        }
        .background(AmpTheme.surface)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let item = store.items.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(AmpTheme.display(24, weight: .bold))
                            .foregroundStyle(AmpTheme.text)
                        Text(item.artist.isEmpty ? item.sourceName : "\(item.artist) · \(item.sourceName)")
                            .font(AmpTheme.caption(12))
                            .foregroundStyle(AmpTheme.muted)
                    }
                    Spacer()
                    Button(item.sourceURL == nil ? "Read file" : "Open tab") {
                        localContent = store.open(item)
                    }
                    .buttonStyle(StudioButton(prominent: true))
                    Button(role: .destructive) { store.delete(item.id); selectedID = nil } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(StudioButton())
                }

                HStack {
                    InfoPill(label: "Tuning", value: item.tuning)
                    InfoPill(label: "Source", value: item.sourceName)
                    InfoPill(label: "Type", value: item.sourceURL == nil ? "Local" : "Web")
                }

                if case .guitarPro(let data) = localContent {
                    GuitarProTabView(data: data)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if case .text(let text) = localContent {
                    ScrollView([.vertical, .horizontal]) {
                        Text(text)
                            .font(AmpTheme.mono(12))
                            .foregroundStyle(AmpTheme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .background(AmpTheme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    StudioCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Practice setup")
                                .font(AmpTheme.display(15, weight: .semibold))
                            Text("Open the provider’s licensed tab, choose the bass track, then keep this library beside the amp or Practice Lab. Saved links retain your song, tuning, and practice notes without copying the provider’s content.")
                                .font(AmpTheme.caption(12))
                                .foregroundStyle(AmpTheme.muted)
                        }
                    }
                    Spacer()
                }
            }
            .padding(18)
            .background(AmpTheme.bg)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(AmpTheme.accent)
                Text("Select a saved tab")
                    .font(AmpTheme.display(18, weight: .semibold))
                    .foregroundStyle(AmpTheme.text)
                Text("Web tabs open with their licensed provider. Local text, MusicXML, and Guitar Pro files can be read here.")
                    .font(AmpTheme.caption(11))
                    .foregroundStyle(AmpTheme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AmpTheme.bg)
        }
    }
}

private struct InfoPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: label)
            Text(value)
                .font(AmpTheme.caption(11))
                .foregroundStyle(AmpTheme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AmpTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
