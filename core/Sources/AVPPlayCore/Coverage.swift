import Foundation

/// Was die Runtime (Klepton) beim Namen kennt: die Funktionen jeder XR-Familie und die OpenXR-Erweiterungen, die in
/// ihren Quellen vorkommen. Eine Funktion, die die Runtime nicht nennt, landet beim allgemeinen Ersatz (gibt 0 oder
/// nichts zurück); genau dort fehlt Arbeit. „Genannt“ heißt nicht „vollständig umgesetzt“ – auch eine bewusste
/// Absage („kein Plattformdienst“) ist genannt. Für die erste Abdeckungskarte (`d30-fingerprint`) reicht das.
public struct RuntimeInterface: Codable, Equatable, Sendable {
    /// Woher: der Commit der Klepton-Quelle, soweit bekannt.
    public var commit: String?
    /// Pro Familie (Schlüssel: `Fingerprint.Family.rawValue`) die genannten Funktionen.
    public var functions: [String: [String]]
    public var openxrExtensions: [String]

    public init(commit: String? = nil, functions: [String: [String]], openxrExtensions: [String]) {
        self.commit = commit; self.functions = functions; self.openxrExtensions = openxrExtensions
    }

    /// Die Ordner einer Klepton-Quelle, in denen die Runtime und die visionOS-Seite liegen.
    static let folders = ["runtime", "visionos"]
    static let suffixes = [".c", ".h", ".m", ".mm", ".swift", ".S", ".py"]

    /// Liest die Namen aus einer Klepton-Quelle (dem Ordner mit `runtime/`).
    public static func scan(klepton: URL) throws -> RuntimeInterface {
        var functions: [Fingerprint.Family: Set<String>] = [:], extensions = Set<String>()
        let fm = FileManager.default
        var any = false
        for folder in folders {
            let root = klepton.appendingPathComponent(folder)
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where suffixes.contains(where: { file.lastPathComponent.hasSuffix($0) }) {
                guard let data = try? Data(contentsOf: file) else { continue }
                any = true
                add(data, to: &functions, extensions: &extensions)
            }
        }
        guard any else {
            throw UnpackError.tool(L("No Klepton sources in \(klepton.path) (expected runtime/).",
                                     "Keine Klepton-Quellen in \(klepton.path) (erwartet: runtime/)."))
        }
        return RuntimeInterface(commit: gitCommit(klepton),
                                functions: Dictionary(uniqueKeysWithValues: functions.map { ($0.key.rawValue, $0.value.sorted()) }),
                                openxrExtensions: extensions.sorted())
    }

    static func add(_ data: Data, to functions: inout [Fingerprint.Family: Set<String>], extensions: inout Set<String>) {
        NameScanner.scan(data) { token in
            if let id = NameScanner.identifier(token), let family = Fingerprint.Family.of(id) { functions[family, default: []].insert(id) }
            else if NameScanner.isExtension(token) { extensions.insert(token) }
        }
    }

    static func gitCommit(_ dir: URL) -> String? {
        guard let out = try? ApkUnpacker.run(["/usr/bin/git", "-C", dir.path, "rev-parse", "--short", "HEAD"]).text else { return nil }
        let commit = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    public func functions(_ family: Fingerprint.Family) -> Set<String> { Set(functions[family.rawValue] ?? []) }
}

/// Wie gut die Runtime ein Spiel abdeckt: was es braucht und die Runtime nicht nennt.
public struct Coverage: Codable, Equatable, Sendable {
    public struct Family: Codable, Equatable, Sendable {
        public var used: Int
        public var missing: [String]
        /// Der Teil von `missing`, den das Spiel fest einbindet – sicher gebraucht, nicht nur genannt.
        public var missingImported: [String] = []
        public var known: Int { used - missing.count }
    }

    /// Pro Familie, die das Spiel benutzt.
    public var families: [String: Family]
    public var missingExtensions: [String]
    /// Schnittstellen, die die Runtime gar nicht nachbildet (eine Familie, von der sie keine Funktion nennt).
    public var unsupportedInterfaces: [String]

    public static func of(_ fp: Fingerprint, runtime: RuntimeInterface) -> Coverage {
        var families: [String: Family] = [:], unsupported: [String] = []
        for family in Fingerprint.Family.allCases {
            let used = fp.functions(family)
            let offered = runtime.functions(family)
            if fp.interfaces.contains(family), offered.isEmpty { unsupported.append(family.rawValue) }
            guard !used.isEmpty else { continue }
            families[family.rawValue] = Family(used: used.count, missing: used.filter { !offered.contains($0) },
                                               missingImported: fp.imported(family).filter { !offered.contains($0) })
        }
        let known = Set(runtime.openxrExtensions)
        return Coverage(families: families,
                        missingExtensions: fp.openxrExtensions.filter { !known.contains($0) && NameScanner.isQuestExtension($0) },
                        unsupportedInterfaces: unsupported)
    }

    public var missingCount: Int { families.values.reduce(0) { $0 + $1.missing.count } + missingExtensions.count }
}

/// Die Abdeckungskarte über viele Spiele: pro Spiel, was fehlt, und pro fehlendem Namen, wie viele Spiele er
/// betrifft – der Unlock-Wert (`s2-unlock`).
public struct CoverageMatrix: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var name: String
        public var fingerprint: Fingerprint
        public var coverage: Coverage
    }

    public struct Gap: Codable, Equatable, Sendable {
        /// `platform`, `ovrplugin`, `vrapi`, `openxr` oder `extension`.
        public var kind: String
        public var name: String
        public var games: [String]
        /// Wie viele davon den Namen fest einbinden.
        public var importedBy: Int = 0
    }

    public var runtime: RuntimeInterface
    public var rows: [Row]

    public init(runtime: RuntimeInterface, games: [(name: String, fingerprint: Fingerprint)]) {
        self.runtime = runtime
        rows = games.map { Row(name: $0.name, fingerprint: $0.fingerprint, coverage: .of($0.fingerprint, runtime: runtime)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Die fehlenden Namen, die meisten betroffenen Spiele zuerst.
    public var gaps: [Gap] {
        var games: [String: Set<String>] = [:], imports: [String: Int] = [:]
        for row in rows {
            for (family, f) in row.coverage.families {
                for name in f.missing { games["\(family) \(name)", default: []].insert(row.name) }
                for name in f.missingImported { imports["\(family) \(name)", default: 0] += 1 }
            }
            for name in row.coverage.missingExtensions { games["extension \(name)", default: []].insert(row.name) }
        }
        return games.map { key, value in
            let parts = key.split(separator: " ", maxSplits: 1)
            return Gap(kind: String(parts[0]), name: String(parts[1]), games: value.sorted(), importedBy: imports[key] ?? 0)
        }
        // Fest eingebunden zählt vor bloß genannt; Erweiterungen zählen wie eingebunden (das Spiel fragt nach ihnen).
        .sorted { a, b in
            let wa = a.kind == "extension" ? a.games.count : a.importedBy, wb = b.kind == "extension" ? b.games.count : b.importedBy
            if wa != wb { return wa > wb }
            if a.games.count != b.games.count { return a.games.count > b.games.count }
            return (a.kind, a.name) < (b.kind, b.name)
        }
    }

    /// Der Bereich einer Plattform-Funktion: `ovr_LeaderboardEntryArray_GetSize` → `Leaderboard`,
    /// `ovr_Message_GetCloudStorageData` → `CloudStorage`.
    public static func platformArea(_ name: String) -> String {
        var parts = name.dropFirst("ovr_".count).split(separator: "_").map(String.init)
        guard var area = parts.first else { return name }
        if area == "Message", parts.count > 1, parts[1].hasPrefix("Get") { area = String(parts[1].dropFirst(3)); parts = [area] }
        let suffixes = ["Array", "Entry", "Definition", "Progress", "Update", "Options", "Metadata", "Data", "Details", "Result", "s"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where area.hasSuffix(suffix) && area.count > suffix.count + 2 {
                area.removeLast(suffix.count); changed = true
            }
        }
        return area
    }

    public struct Area: Codable, Equatable, Sendable {
        public var name: String
        /// Fehlende, fest eingebundene Funktionen dieses Bereichs über alle Spiele.
        public var functions: Int
        public var games: [String]
    }

    /// Die Bereiche des Plattform-SDKs, deren fest eingebundene Funktionen der Runtime fehlen, nach betroffenen Spielen.
    public var platformAreas: [Area] {
        var functions: [String: Set<String>] = [:], games: [String: Set<String>] = [:]
        for row in rows {
            for name in row.coverage.families[Fingerprint.Family.platform.rawValue]?.missingImported ?? [] {
                let area = CoverageMatrix.platformArea(name)
                functions[area, default: []].insert(name)
                games[area, default: []].insert(row.name)
            }
        }
        return games.map { Area(name: $0.key, functions: functions[$0.key]?.count ?? 0, games: $0.value.sorted()) }
            .sorted { $0.games.count != $1.games.count ? $0.games.count > $1.games.count : $0.name < $1.name }
    }

    /// Die Karte als Markdown: Übersicht pro Spiel, dann die Lücken nach Unlock-Wert.
    public func markdown(gapLimit: Int = 60) -> String {
        var lines = ["# Abdeckungskarte", "",
                     "Runtime: Klepton \(runtime.commit ?? "?") · Spiele: \(rows.count)", "",
                     "Spalten „fehlt“: nicht von der Runtime genannt, davon fest eingebunden in Klammern.", "",
                     "| Spiel | Engine | Grafik | Schnittstellen | genutzt | fehlt | fehlende Erweiterungen |",
                     "|---|---|---|---|---|---|---|"]
        for row in rows {
            let fp = row.fingerprint
            let engine = [fp.engine.rawValue, fp.engineVersion, fp.scripting].compactMap { $0 }.joined(separator: " ")
            let graphics = [fp.graphics.vulkan ? "Vulkan" : nil, fp.graphics.gles ? "GLES" : nil].compactMap { $0 }.joined(separator: "+")
            let interfaces = fp.interfaces.map(\.rawValue).joined(separator: ", ")
                + (row.coverage.unsupportedInterfaces.isEmpty ? "" : " (nicht nachgebildet: \(row.coverage.unsupportedInterfaces.joined(separator: ", ")))")
            let used = row.coverage.families.values.reduce(0) { $0 + $1.used }
            let missing = row.coverage.families.values.reduce(0) { $0 + $1.missing.count }
            let hard = row.coverage.families.values.reduce(0) { $0 + $1.missingImported.count }
            lines.append("| \(row.name) | \(engine) | \(graphics.isEmpty ? "–" : graphics) | \(interfaces.isEmpty ? "–" : interfaces) | \(used) | \(missing) (\(hard)) | \(row.coverage.missingExtensions.joined(separator: ", ")) |")
        }
        lines += ["", "## Plattform-SDK: fehlende Bereiche", "",
                  "Bereiche, deren fest eingebundene Funktionen die Runtime nicht nennt (der Aufruf landet beim allgemeinen Ersatz).", "",
                  "| Bereich | Funktionen | Spiele | betroffen |", "|---|---|---|---|"]
        for area in platformAreas {
            lines.append("| \(area.name) | \(area.functions) | \(area.games.count) | \(area.games.prefix(6).joined(separator: ", "))\(area.games.count > 6 ? ", …" : "") |")
        }
        lines += ["", "## Lücken nach Unlock-Wert", "",
                  "Sortiert nach der Zahl der Spiele, die den Namen fest einbinden (Erweiterungen: die danach fragen), dann nach allen, die ihn nennen.", "",
                  "| Art | Name | eingebunden | genannt | betroffen |", "|---|---|---|---|---|"]
        for gap in gaps.prefix(gapLimit) {
            let hard = gap.kind == "extension" ? gap.games.count : gap.importedBy
            lines.append("| \(gap.kind) | `\(gap.name)` | \(hard) | \(gap.games.count) | \(gap.games.prefix(6).joined(separator: ", "))\(gap.games.count > 6 ? ", …" : "") |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
