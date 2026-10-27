import Foundation

/// Der Teil eines Fingerabdrucks, der zum Vergleich mit anderen Spielen reicht: Merkmale, fest eingebundene
/// Funktionen, erfragte Erweiterungen. Klein genug, um die geprüften Spiele mit dem Programm auszuliefern.
public struct ReferenceFingerprint: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// `engine:unity`, `unity:2021`, `gfx:vulkan`, `xr:openxr`, `mw:FMOD`, …
    public var features: [String]
    /// Pro Familie (`Fingerprint.Family.rawValue`) die fest eingebundenen Funktionen.
    public var imported: [String: [String]]
    public var extensions: [String]

    public init(id: String, title: String, fingerprint fp: Fingerprint) {
        self.id = id
        self.title = title
        features = ReferenceFingerprint.features(of: fp)
        imported = fp.imported
        extensions = fp.openxrExtensions.filter(NameScanner.isQuestExtension)
    }

    static func features(of fp: Fingerprint) -> [String] {
        var out = ["engine:\(fp.engine.rawValue)"]
        if let version = fp.engineVersion, let major = version.split(separator: ".").first {
            out.append("\(fp.engine.rawValue):\(major)")
        }
        if let scripting = fp.scripting { out.append("scripting:\(scripting)") }
        if fp.graphics.vulkan { out.append("gfx:vulkan") }
        if fp.graphics.gles { out.append("gfx:gles") }
        out += fp.interfaces.map { "xr:\($0.rawValue)" }
        out += fp.middleware.map { "mw:\($0)" }
        return out.sorted()
    }

    /// Alles, was beim Vergleich zählt, als eine Menge.
    var signature: Set<String> {
        Set(features).union(imported.flatMap { family, names in names.map { "\(family):\($0)" } })
            .union(extensions.map { "ext:\($0)" })
    }
}

/// Die Prognose für ein ungetestetes Spiel: welchen geprüften Spielen es am meisten ähnelt, und was es braucht,
/// das die Runtime nicht kennt UND das kein geprüftes Spiel braucht. Nur Letzteres ist ein echtes Warnzeichen –
/// Lücken, die auch geprüfte Spiele haben, stören diese offenbar nicht (`moonshot-Status.md`, `d30-fingerprint`).
public struct Prognosis: Codable, Equatable, Sendable {
    public enum Outlook: String, Codable, Sendable {
        /// Ähnelt einem geprüften Spiel stark und braucht nichts Ungewöhnliches.
        case likely
        /// Ähnelt geprüften Spielen, braucht aber Einzelnes, das die Runtime nicht kennt.
        case possible
        /// Braucht vieles, das weder die Runtime noch ein geprüftes Spiel kennt, oder etwas, das gar nicht geht.
        case unlikely
    }

    public struct Neighbour: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// Ähnlichkeit zwischen 0 und 1 (Jaccard über Merkmale, eingebundene Funktionen und Erweiterungen).
        public var similarity: Double
    }

    public var outlook: Outlook
    public var neighbours: [Neighbour]
    /// Fest eingebundene Funktionen von OVRPlugin, OpenXR und VrApi, die weder die Runtime nennt noch ein geprüftes
    /// Spiel einbindet, als `familie:name`. Sie entscheiden über die Aussicht.
    public var unusualFunctions: [String]
    /// Bereiche des Plattform-SDKs (`Leaderboard`, `Voip`, …) mit solchen Funktionen. Sie entscheiden nicht über die
    /// Aussicht: ein unbekannter Plattform-Aufruf landet beim allgemeinen Ersatz und lässt höchstens die
    /// Online-Funktion ausfallen (BattleGlide bindet 409 davon ein und ist geprüft).
    public var missingPlatformAreas: [String] = []
    /// Erfragte Quest-Erweiterungen, die weder die Runtime nennt noch ein geprüftes Spiel erfragt.
    public var unusualExtensions: [String]
    /// Was sicher nicht geht (kein 64-Bit-Code, eine Schnittstelle, die die Runtime gar nicht nachbildet und kein
    /// geprüftes Spiel nutzt).
    public var blockers: [String]

    /// Ab so vielen ungewöhnlichen Namen gilt ein Spiel als unwahrscheinlich.
    static let unlikelyAt = 12
    /// Ab dieser Ähnlichkeit zum nächsten geprüften Spiel kann ein Spiel ohne Ungewöhnliches „wahrscheinlich“ sein.
    static let likelyFrom = 0.5

    public static func make(_ fp: Fingerprint, runtime: RuntimeInterface, references: [ReferenceFingerprint], limit: Int = 3) -> Prognosis {
        let mine = ReferenceFingerprint(id: "", title: "", fingerprint: fp)
        let signature = mine.signature
        var all: [Neighbour] = []
        for ref in references {
            let other = ref.signature
            let union = signature.union(other).count
            let shared = signature.intersection(other).count
            let similarity: Double = union == 0 ? 0 : Double(shared) / Double(union)
            all.append(Neighbour(id: ref.id, title: ref.title, similarity: similarity))
        }
        all.sort { a, b in
            if a.similarity != b.similarity { return a.similarity > b.similarity }
            return a.title < b.title
        }
        let neighbours = all.prefix(limit)

        var seen: [String: Set<String>] = [:]
        for ref in references { for (family, names) in ref.imported { seen[family, default: []].formUnion(names) } }
        let seenExtensions = Set(references.flatMap(\.extensions))
        var unusual: [String] = [], areas = Set<String>()
        for family in Fingerprint.Family.allCases {
            let offered = runtime.functions(family)
            for name in fp.imported(family) where !offered.contains(name) && !(seen[family.rawValue]?.contains(name) ?? false) {
                if family == .platform { areas.insert(CoverageMatrix.platformArea(name)) }
                else { unusual.append("\(family.rawValue):\(name)") }
            }
        }
        let known = Set(runtime.openxrExtensions)
        let unusualExtensions = mine.extensions.filter { !known.contains($0) && !seenExtensions.contains($0) }

        var blockers: [String] = []
        if ApkUnpacker.lacksArm64(Set(fp.architectures)) {
            blockers.append(L("only 32-bit code (\(fp.architectures.joined(separator: ", ")))", "nur 32-Bit-Code (\(fp.architectures.joined(separator: ", ")))"))
        }
        for family in fp.interfaces where runtime.functions(family).isEmpty && !references.contains(where: { $0.features.contains("xr:\(family.rawValue)") }) {
            blockers.append(L("calls \(family.rawValue) directly, which the runtime does not provide",
                              "ruft \(family.rawValue) direkt auf, das die Runtime nicht nachbildet"))
        }

        let count = unusual.count + unusualExtensions.count
        let outlook: Outlook
        if !blockers.isEmpty || count >= unlikelyAt { outlook = .unlikely }
        else if count == 0, (neighbours.first?.similarity ?? 0) >= likelyFrom { outlook = .likely }
        else { outlook = .possible }
        return Prognosis(outlook: outlook, neighbours: Array(neighbours), unusualFunctions: unusual,
                         missingPlatformAreas: areas.sorted(), unusualExtensions: unusualExtensions, blockers: blockers)
    }

    /// Ein Satz für die Seite eines Spiels, mit einem Nachsatz zu fehlenden Plattform-Bereichen.
    public var summary: String {
        guard !missingPlatformAreas.isEmpty, blockers.isEmpty else { return outlookSentence }
        let areas = missingPlatformAreas.prefix(4).joined(separator: ", ") + (missingPlatformAreas.count > 4 ? ", …" : "")
        return outlookSentence + " " + L("Online features may be missing (\(areas)).", "Online-Funktionen können fehlen (\(areas)).")
    }

    var outlookSentence: String {
        let closest = neighbours.first.map { "\($0.title) (\(Int(($0.similarity * 100).rounded())) %)" }
        let unusualCount = unusualFunctions.count + unusualExtensions.count
        switch outlook {
        case .likely:
            return L("Built much like \(closest ?? "a verified game") and needs nothing the verified games don't – good chances.",
                     "Ähnlich gebaut wie \(closest ?? "ein geprüftes Spiel") und braucht nichts, was die geprüften Spiele nicht brauchen – gute Aussichten.")
        case .possible:
            return unusualCount == 0
                ? L("Needs nothing unusual, but no verified game is built quite like it.",
                    "Braucht nichts Ungewöhnliches, aber kein geprüftes Spiel ist ganz ähnlich gebaut.")
                : L("Closest verified game: \(closest ?? "–"). Needs \(unusualCount) thing(s) the runtime does not know yet.",
                    "Nächstes geprüftes Spiel: \(closest ?? "–"). Braucht \(unusualCount) Sache(n), die die Runtime noch nicht kennt.")
        case .unlikely:
            return blockers.isEmpty
                ? L("Needs \(unusualCount) things neither the runtime nor any verified game knows – unlikely to run without work.",
                    "Braucht \(unusualCount) Dinge, die weder die Runtime noch ein geprüftes Spiel kennt – ohne Arbeit eher nicht lauffähig.")
                : L("Will not run: \(blockers.joined(separator: "; ")).", "Läuft nicht: \(blockers.joined(separator: "; ")).")
        }
    }
}
