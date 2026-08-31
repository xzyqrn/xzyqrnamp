import Foundation

enum AmpPaths {
    static let folderName = "xzyqrn amp"
    private static let legacyFolderName = "Amplifier"

    static func root() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func subdirectory(_ name: String) throws -> URL {
        let url = try root().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func legacyPresets() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("\(legacyFolderName)/Presets", isDirectory: true)
    }
}

struct AmpPreset: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var inputGainDb: Double
    var outputGainDb: Double
    var gateThresholdDb: Double
    var bassDb: Double
    var midDb: Double
    var trebleDb: Double
    var gateOn: Bool
    var expanderOn: Bool
    var nrOn: Bool
    var namOn: Bool
    var cleanAmpOn: Bool
    var irOn: Bool
    var eqOn: Bool
    var namFile: String
    var irFile: String
    var namBookmark: Data?
    var irBookmark: Data?

    var compOn: Bool
    var compThresholdDb: Double
    var compRatio: Double
    var compMakeupDb: Double

    var driveOn: Bool
    var driveAmount: Double
    var driveTone: Double
    var driveMix: Double

    var octaverOn: Bool
    var octaverMix: Double
    var octaverTone: Double

    var envelopeOn: Bool
    var envelopeSensitivity: Double
    var envelopeResonance: Double
    var envelopeMix: Double

    var utilityFilterOn: Bool
    var highPassHz: Double
    var lowPassHz: Double

    var chorusOn: Bool
    var chorusRate: Double
    var chorusDepth: Double
    var chorusMix: Double

    var delayOn: Bool
    var delayTimeMs: Double
    var delayFeedback: Double
    var delayMix: Double

    var reverbOn: Bool
    var reverbSize: Double
    var reverbDamp: Double
    var reverbMix: Double

    var midFreqIndex: Int
    var ultraLoOn: Bool
    var ultraHiOn: Bool

    init(
        id: String,
        name: String,
        inputGainDb: Double,
        outputGainDb: Double,
        gateThresholdDb: Double,
        bassDb: Double,
        midDb: Double,
        trebleDb: Double,
        gateOn: Bool,
        expanderOn: Bool = false,
        nrOn: Bool = false,
        namOn: Bool,
        cleanAmpOn: Bool = false,
        irOn: Bool,
        eqOn: Bool,
        namFile: String,
        irFile: String,
        namBookmark: Data? = nil,
        irBookmark: Data? = nil,
        compOn: Bool = false,
        compThresholdDb: Double = -24,
        compRatio: Double = 4,
        compMakeupDb: Double = 2,
        driveOn: Bool = false,
        driveAmount: Double = 0.35,
        driveTone: Double = 0.5,
        driveMix: Double = 0.55,
        octaverOn: Bool = false,
        octaverMix: Double = 0.35,
        octaverTone: Double = 0.45,
        envelopeOn: Bool = false,
        envelopeSensitivity: Double = 0.55,
        envelopeResonance: Double = 0.45,
        envelopeMix: Double = 0.65,
        utilityFilterOn: Bool = true,
        highPassHz: Double = 32,
        lowPassHz: Double = 12000,
        chorusOn: Bool = false,
        chorusRate: Double = 0.8,
        chorusDepth: Double = 0.4,
        chorusMix: Double = 0.35,
        delayOn: Bool = false,
        delayTimeMs: Double = 180,
        delayFeedback: Double = 0.28,
        delayMix: Double = 0.22,
        reverbOn: Bool = false,
        reverbSize: Double = 0.4,
        reverbDamp: Double = 0.45,
        reverbMix: Double = 0.2,
        midFreqIndex: Int = 1,
        ultraLoOn: Bool = false,
        ultraHiOn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.inputGainDb = inputGainDb
        self.outputGainDb = outputGainDb
        self.gateThresholdDb = gateThresholdDb
        self.bassDb = bassDb
        self.midDb = midDb
        self.trebleDb = trebleDb
        self.gateOn = gateOn
        self.expanderOn = expanderOn
        self.nrOn = nrOn
        self.namOn = namOn
        self.cleanAmpOn = cleanAmpOn
        self.irOn = irOn
        self.eqOn = eqOn
        self.namFile = namFile
        self.irFile = irFile
        self.namBookmark = namBookmark
        self.irBookmark = irBookmark
        self.compOn = compOn
        self.compThresholdDb = compThresholdDb
        self.compRatio = compRatio
        self.compMakeupDb = compMakeupDb
        self.driveOn = driveOn
        self.driveAmount = driveAmount
        self.driveTone = driveTone
        self.driveMix = driveMix
        self.octaverOn = octaverOn
        self.octaverMix = octaverMix
        self.octaverTone = octaverTone
        self.envelopeOn = envelopeOn
        self.envelopeSensitivity = envelopeSensitivity
        self.envelopeResonance = envelopeResonance
        self.envelopeMix = envelopeMix
        self.utilityFilterOn = utilityFilterOn
        self.highPassHz = highPassHz
        self.lowPassHz = lowPassHz
        self.chorusOn = chorusOn
        self.chorusRate = chorusRate
        self.chorusDepth = chorusDepth
        self.chorusMix = chorusMix
        self.delayOn = delayOn
        self.delayTimeMs = delayTimeMs
        self.delayFeedback = delayFeedback
        self.delayMix = delayMix
        self.reverbOn = reverbOn
        self.reverbSize = reverbSize
        self.reverbDamp = reverbDamp
        self.reverbMix = reverbMix
        self.midFreqIndex = midFreqIndex
        self.ultraLoOn = ultraLoOn
        self.ultraHiOn = ultraHiOn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        inputGainDb = try c.decode(Double.self, forKey: .inputGainDb)
        outputGainDb = try c.decode(Double.self, forKey: .outputGainDb)
        gateThresholdDb = try c.decode(Double.self, forKey: .gateThresholdDb)
        bassDb = try c.decode(Double.self, forKey: .bassDb)
        midDb = try c.decode(Double.self, forKey: .midDb)
        trebleDb = try c.decode(Double.self, forKey: .trebleDb)
        gateOn = try c.decode(Bool.self, forKey: .gateOn)
        namOn = try c.decode(Bool.self, forKey: .namOn)
        expanderOn = try c.decodeIfPresent(Bool.self, forKey: .expanderOn)
            ?? (id == "practice" && !gateOn)
        nrOn = try c.decodeIfPresent(Bool.self, forKey: .nrOn)
            ?? (id == "practice" && !gateOn)
        irOn = try c.decode(Bool.self, forKey: .irOn)
        eqOn = try c.decode(Bool.self, forKey: .eqOn)
        namFile = try c.decode(String.self, forKey: .namFile)
        irFile = try c.decode(String.self, forKey: .irFile)
        namBookmark = try c.decodeIfPresent(Data.self, forKey: .namBookmark)
        irBookmark = try c.decodeIfPresent(Data.self, forKey: .irBookmark)
        cleanAmpOn = try c.decodeIfPresent(Bool.self, forKey: .cleanAmpOn)
            ?? (namOn && namFile.isEmpty && namBookmark == nil)
        compOn = try c.decodeIfPresent(Bool.self, forKey: .compOn) ?? false
        compThresholdDb = try c.decodeIfPresent(Double.self, forKey: .compThresholdDb) ?? -24
        compRatio = try c.decodeIfPresent(Double.self, forKey: .compRatio) ?? 4
        compMakeupDb = try c.decodeIfPresent(Double.self, forKey: .compMakeupDb) ?? 2
        driveOn = try c.decodeIfPresent(Bool.self, forKey: .driveOn) ?? false
        driveAmount = try c.decodeIfPresent(Double.self, forKey: .driveAmount) ?? 0.35
        driveTone = try c.decodeIfPresent(Double.self, forKey: .driveTone) ?? 0.5
        driveMix = try c.decodeIfPresent(Double.self, forKey: .driveMix) ?? 0.55
        octaverOn = try c.decodeIfPresent(Bool.self, forKey: .octaverOn) ?? false
        octaverMix = try c.decodeIfPresent(Double.self, forKey: .octaverMix) ?? 0.35
        octaverTone = try c.decodeIfPresent(Double.self, forKey: .octaverTone) ?? 0.45
        envelopeOn = try c.decodeIfPresent(Bool.self, forKey: .envelopeOn) ?? false
        envelopeSensitivity = try c.decodeIfPresent(Double.self, forKey: .envelopeSensitivity) ?? 0.55
        envelopeResonance = try c.decodeIfPresent(Double.self, forKey: .envelopeResonance) ?? 0.45
        envelopeMix = try c.decodeIfPresent(Double.self, forKey: .envelopeMix) ?? 0.65
        utilityFilterOn = try c.decodeIfPresent(Bool.self, forKey: .utilityFilterOn) ?? true
        highPassHz = try c.decodeIfPresent(Double.self, forKey: .highPassHz) ?? 32
        lowPassHz = try c.decodeIfPresent(Double.self, forKey: .lowPassHz) ?? 12000
        chorusOn = try c.decodeIfPresent(Bool.self, forKey: .chorusOn) ?? false
        chorusRate = try c.decodeIfPresent(Double.self, forKey: .chorusRate) ?? 0.8
        chorusDepth = try c.decodeIfPresent(Double.self, forKey: .chorusDepth) ?? 0.4
        chorusMix = try c.decodeIfPresent(Double.self, forKey: .chorusMix) ?? 0.35
        delayOn = try c.decodeIfPresent(Bool.self, forKey: .delayOn) ?? false
        delayTimeMs = try c.decodeIfPresent(Double.self, forKey: .delayTimeMs) ?? 180
        delayFeedback = try c.decodeIfPresent(Double.self, forKey: .delayFeedback) ?? 0.28
        delayMix = try c.decodeIfPresent(Double.self, forKey: .delayMix) ?? 0.22
        reverbOn = try c.decodeIfPresent(Bool.self, forKey: .reverbOn) ?? false
        reverbSize = try c.decodeIfPresent(Double.self, forKey: .reverbSize) ?? 0.4
        reverbDamp = try c.decodeIfPresent(Double.self, forKey: .reverbDamp) ?? 0.45
        reverbMix = try c.decodeIfPresent(Double.self, forKey: .reverbMix) ?? 0.2
        midFreqIndex = try c.decodeIfPresent(Int.self, forKey: .midFreqIndex) ?? 1
        ultraLoOn = try c.decodeIfPresent(Bool.self, forKey: .ultraLoOn) ?? false
        ultraHiOn = try c.decodeIfPresent(Bool.self, forKey: .ultraHiOn) ?? false
    }

    static let bundled: [AmpPreset] = {
        if let url = Bundle.main.url(forResource: "factory-presets", withExtension: "json", subdirectory: "Presets")
            ?? Bundle.main.url(forResource: "factory-presets", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([AmpPreset].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return fallback
    }()

    private static let fallback: [AmpPreset] = [
        AmpPreset(
            id: "practice",
            name: "Practice Clean",
            inputGainDb: 0, outputGainDb: -3, gateThresholdDb: -40,
            bassDb: 0, midDb: 0, trebleDb: 0,
            gateOn: false, expanderOn: true, nrOn: true, namOn: false, cleanAmpOn: false, irOn: false, eqOn: false,
            namFile: "", irFile: "",
            compOn: false, compThresholdDb: -22, compRatio: 3.5, compMakeupDb: 0,
            utilityFilterOn: true, highPassHz: 25, lowPassHz: 16000,
            midFreqIndex: 1, ultraLoOn: false, ultraHiOn: false
        ),
        AmpPreset(
            id: "raw-di",
            name: "Raw DI",
            inputGainDb: 0, outputGainDb: 0, gateThresholdDb: -40,
            bassDb: 0, midDb: 0, trebleDb: 0,
            gateOn: false, expanderOn: false, namOn: false, cleanAmpOn: false, irOn: false, eqOn: false,
            namFile: "", irFile: "",
            utilityFilterOn: true, highPassHz: 22, lowPassHz: 16000,
            midFreqIndex: 1, ultraLoOn: false, ultraHiOn: false
        ),
        AmpPreset(
            id: "vintage-clean",
            name: "xzyqrn Vintage Clean",
            inputGainDb: 0, outputGainDb: 0, gateThresholdDb: -40,
            bassDb: 1.5, midDb: 0, trebleDb: -3,
            gateOn: true, namOn: true, cleanAmpOn: true, irOn: true, eqOn: true,
            namFile: "", irFile: "bass-4x10.wav",
            compOn: false, compThresholdDb: -22, compRatio: 3.5, compMakeupDb: 0,
            utilityFilterOn: true, highPassHz: 35, lowPassHz: 5000,
            midFreqIndex: 1, ultraLoOn: false, ultraHiOn: false
        ),
        AmpPreset(
            id: "svt",
            name: "MIG-50 Tube Stadium",
            inputGainDb: 4.5, outputGainDb: -1.5, gateThresholdDb: -40,
            bassDb: 2.5, midDb: 1.5, trebleDb: 1.0,
            gateOn: true, namOn: true, irOn: true, eqOn: true,
            namFile: "community-sovtek-mig50.nam", irFile: "bass-8x10.wav",
            compOn: true, compThresholdDb: -20, compRatio: 4.0, compMakeupDb: 2.5,
            driveOn: true, driveAmount: 0.28, driveTone: 0.45, driveMix: 0.40,
            midFreqIndex: 2, ultraLoOn: true, ultraHiOn: false
        ),
        AmpPreset(
            id: "growl",
            name: "DP-3X Bi-Amp Grind",
            inputGainDb: 6, outputGainDb: -3, gateThresholdDb: -38,
            bassDb: 1.0, midDb: 3.0, trebleDb: 2.0,
            gateOn: true, namOn: true, irOn: true, eqOn: true,
            namFile: "community-dp3x-bass-preamp.nam", irFile: "bass-2x12.wav",
            compOn: true, compThresholdDb: -18, compRatio: 5.0, compMakeupDb: 3.0,
            driveOn: true, driveAmount: 0.65, driveTone: 0.68, driveMix: 0.60,
            midFreqIndex: 3, ultraLoOn: false, ultraHiOn: false
        ),
        AmpPreset(
            id: "slap",
            name: "Modern Slap & Pop",
            inputGainDb: 3.5, outputGainDb: -1, gateThresholdDb: -38,
            bassDb: 3.5, midDb: -2.5, trebleDb: 3.0,
            gateOn: true, namOn: true, cleanAmpOn: true, irOn: true, eqOn: true,
            namFile: "", irFile: "bass-4x10.wav",
            compOn: true, compThresholdDb: -16, compRatio: 6.0, compMakeupDb: 4.0,
            chorusOn: true, chorusRate: 1.2, chorusDepth: 0.25, chorusMix: 0.20,
            midFreqIndex: 4, ultraLoOn: false, ultraHiOn: true
        ),
        AmpPreset(
            id: "fretless",
            name: "80s Fretless",
            inputGainDb: 3.0, outputGainDb: -1.5, gateThresholdDb: -42,
            bassDb: 1.0, midDb: 2.5, trebleDb: 0.5,
            gateOn: true, namOn: true, cleanAmpOn: true, irOn: true, eqOn: true,
            namFile: "", irFile: "bass-4x10.wav",
            compOn: true, compThresholdDb: -22, compRatio: 3.0, compMakeupDb: 2.0,
            chorusOn: true, chorusRate: 0.65, chorusDepth: 0.65, chorusMix: 0.45,
            reverbOn: true, reverbSize: 0.35, reverbDamp: 0.50, reverbMix: 0.25,
            midFreqIndex: 2, ultraLoOn: false, ultraHiOn: false
        ),
        AmpPreset(
            id: "motown",
            name: "Motown Thump",
            inputGainDb: 4.5, outputGainDb: -1.0, gateThresholdDb: -44,
            bassDb: 4.0, midDb: 1.0, trebleDb: -4.5,
            gateOn: true, namOn: true, cleanAmpOn: true, irOn: true, eqOn: true,
            namFile: "", irFile: "bass-1x15.wav",
            compOn: true, compThresholdDb: -24, compRatio: 4.5, compMakeupDb: 3.0,
            driveOn: true, driveAmount: 0.18, driveTone: 0.25, driveMix: 0.35,
            midFreqIndex: 0, ultraLoOn: false, ultraHiOn: false
        )
    ]
}

struct PedalFactoryPreset: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var pedal: String
    var values: [String: Double]

    static let bundled: [PedalFactoryPreset] = {
        if let url = Bundle.main.url(forResource: "pedal-factory", withExtension: "json", subdirectory: "Presets")
            ?? Bundle.main.url(forResource: "pedal-factory", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([PedalFactoryPreset].self, from: data) {
            return decoded
        }
        return fallback
    }()

    static func presets(for pedal: String) -> [PedalFactoryPreset] {
        bundled.filter { $0.pedal == pedal }
    }

    private static let fallback: [PedalFactoryPreset] = [
        PedalFactoryPreset(id: "slap-comp", name: "Slap Comp", pedal: "comp", values: [
            "compThresholdDb": -18, "compRatio": 6, "compMakeupDb": 4
        ]),
        PedalFactoryPreset(id: "warm-drive", name: "Warm Drive", pedal: "drive", values: [
            "driveAmount": 0.4, "driveTone": 0.45, "driveMix": 0.55
        ]),
        PedalFactoryPreset(id: "deep-chorus", name: "Deep Chorus", pedal: "chorus", values: [
            "chorusRate": 0.6, "chorusDepth": 0.7, "chorusMix": 0.45
        ]),
        PedalFactoryPreset(id: "slapback", name: "Slapback", pedal: "delay", values: [
            "delayTimeMs": 95, "delayFeedback": 0.08, "delayMix": 0.28
        ]),
        PedalFactoryPreset(id: "room", name: "Room", pedal: "reverb", values: [
            "reverbSize": 0.28, "reverbDamp": 0.5, "reverbMix": 0.22
        ]),
        PedalFactoryPreset(id: "hall", name: "Hall", pedal: "reverb", values: [
            "reverbSize": 0.72, "reverbDamp": 0.35, "reverbMix": 0.32
        ])
    ]
}

enum PresetStore {
    static func directory() throws -> URL {
        try AmpPaths.subdirectory("Presets")
    }

    static func save(_ preset: AmpPreset) {
        do {
            let url = try directory().appendingPathComponent("\(preset.id).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preset)
            try data.write(to: url)
        } catch {
            NSLog("Preset save failed: \(error)")
        }
    }

    static func loadAll() -> [AmpPreset] {
        var seen = Set<String>()
        var result: [AmpPreset] = []
        let dirs = [try? directory(), AmpPaths.legacyPresets()].compactMap { $0 }
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for url in files where url.pathExtension == "json" {
                guard let preset = try? JSONDecoder().decode(AmpPreset.self, from: Data(contentsOf: url)) else { continue }
                if seen.insert(preset.id).inserted {
                    result.append(preset)
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
