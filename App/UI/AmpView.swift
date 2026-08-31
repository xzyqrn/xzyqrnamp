import SwiftUI
import UniformTypeIdentifiers

struct AmpView: View {
    @EnvironmentObject private var session: AmpSession
    @State private var showImporter = false
    @State private var importerKind: ImporterKind = .nam
    @State private var showSave = false
    @State private var newPresetName = "My rig"

    enum ImporterKind { case nam, ir }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            VStack(spacing: 14) {
                AmpPanel(
                    onLoadNAM: {
                        importerKind = .nam
                        showImporter = true
                    },
                    onLoadIR: {
                        importerKind = .ir
                        showImporter = true
                    },
                    onSavePreset: { showSave = true }
                )
                EffectsRail()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Spacer(minLength: 0)
            TransportBar()
        }
        .background(AmpTheme.bg)
        .preferredColorScheme(.dark)
        .padding(.top, 22)
        .frame(minWidth: 1080, minHeight: 720)
        .modifier(AmpDialogs(
            showImporter: $showImporter,
            importerKind: importerKind,
            showSave: $showSave,
            newPresetName: $newPresetName
        ))
        .onAppear { session.refreshDevices() }
    }
}

private struct AmpDialogs: ViewModifier {
    @EnvironmentObject var session: AmpSession
    @Binding var showImporter: Bool
    var importerKind: AmpView.ImporterKind
    @Binding var showSave: Bool
    @Binding var newPresetName: String

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importerKind == .nam
                    ? [UTType(filenameExtension: "nam") ?? .json]
                    : [.wav, .audio],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if importerKind == .nam {
                        _ = session.loadNAM(url: url)
                    } else {
                        _ = session.loadIR(url: url)
                    }
                }
            }
            .alert("Save this rig", isPresented: $showSave) {
                TextField("Name", text: $newPresetName)
                Button("Save") { session.savePreset(named: newPresetName) }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Audio",
                isPresented: Binding(
                    get: { session.errorMessage != nil },
                    set: { if !$0 { session.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
    }
}
