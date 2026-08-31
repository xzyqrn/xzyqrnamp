import Foundation

struct PracticeLog: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var duration: TimeInterval
    var source: String
    var beatStyle: String
    var bpm: Int
    var presetName: String
    var notes: String
}

@MainActor
final class PracticeSessionStore: ObservableObject {
    @Published private(set) var activeSince: Date?
    @Published private(set) var logs: [PracticeLog] = []
    @Published var source = "Free practice"
    @Published var notes = ""

    private static let logsKey = "xzyqrn.practiceLogs.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.logsKey),
           let decoded = try? JSONDecoder().decode([PracticeLog].self, from: data) {
            logs = decoded
        }
    }

    func start() {
        activeSince = Date()
    }

    func finish(using amp: AmpSession) {
        guard let activeSince else { return }
        let preset = amp.presets.first(where: { $0.id == amp.selectedPresetID })?.name ?? "Custom rig"
        logs.insert(
            PracticeLog(
                date: activeSince,
                duration: Date().timeIntervalSince(activeSince),
                source: source,
                beatStyle: amp.beatStyle.title,
                bpm: Int(amp.beatBPM),
                presetName: preset,
                notes: notes
            ),
            at: 0
        )
        if logs.count > 100 { logs.removeLast(logs.count - 100) }
        self.activeSince = nil
        notes = ""
        persist()
    }

    func discard() {
        activeSince = nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(logs) {
            UserDefaults.standard.set(data, forKey: Self.logsKey)
        }
    }
}
