import Foundation

public enum FetchError: Error, CustomStringConvertible, Equatable {
    case sizeMismatch(name: String, expected: Int64, actual: Int64)
    case checksumMismatch(name: String)

    public var description: String {
        switch self {
        case .sizeMismatch(let n, let e, let a):
            return L("\(n): size is \(a) bytes instead of \(e) – discarded.", "\(n): Größe \(a) Bytes statt \(e) – verworfen.")
        case .checksumMismatch(let n): return L("\(n): checksum doesn't match – discarded.", "\(n): Prüfsumme stimmt nicht – verworfen.")
        }
    }
}

/// Führt einen Abrufplan aus: eine Datei nach der anderen, mit Bremse, Prüfung und Abbruch beim ersten Fehler.
public struct Fetcher: Sendable {
    public struct Learned: Sendable, Equatable {
        public let name: String
        public let size: Int64
        public let sha256: String
    }
    public struct Summary: Sendable, Equatable {
        public var kept = 0
        public var downloaded = 0
        public var bytes: Int64 = 0
        /// Prüfsummen von Dateien, für die das Rezept noch keine kannte.
        public var learned: [Learned] = []
        /// Dateien, die der Nutzer selbst bereitstellen muss.
        public var needsUser: [String] = []
        /// Zusatzdateien, die Meta diesem Konto nicht ausliefert (nicht gekaufter Zusatzinhalt); übersprungen.
        public var withheld: [String] = []
    }

    /// Darf eine Ablehnung dieser Datei als „gehört nicht zu den Käufen“ gelten? Nur für die weiteren Dateien
    /// eines ungeprüften Entwurfs: Metas Dateiliste nennt dort auch kostenpflichtige Zusatzinhalte, ohne sie zu
    /// kennzeichnen. Das APK, die Haupt-Datendatei und alles, wofür ein Rezept eine Prüfsumme kennt, gehören
    /// zum Spiel selbst – wird so etwas verweigert, stimmt etwas anderes nicht, und der Lauf endet wie bisher.
    public static func mayBeWithheld(_ file: RecipeFile) -> Bool {
        file.source == nil && file.role == "content-bundle" && file.sha256 == nil
    }

    let client: MetaClient
    let store: ContentStore
    let gate: RequestGate
    /// Wird nach jeder fertig geladenen und geprüften Datei aufgerufen. Wirft er, endet der Lauf dort: was noch
    /// aussteht, wird nicht mehr angefragt.
    public var afterFile: (@Sendable (RecipeFile, URL) throws -> Void)?

    public init(client: MetaClient, store: ContentStore, gate: RequestGate = RequestGate()) {
        self.client = client
        self.store = store
        self.gate = gate
    }

    public func run(_ plan: [PlannedFetch], recipe: Recipe, log: @Sendable (String) -> Void) async throws -> Summary {
        var summary = Summary()
        try FileManager.default.createDirectory(at: store.directory(for: recipe), withIntermediateDirectories: true)
        for item in plan {
            let file = item.file
            let final = store.url(for: file, in: recipe)
            let partial = store.partialURL(for: file, in: recipe)
            var offset: Int64 = 0
            switch item.action {
            case .keep:
                summary.kept += 1
                continue
            case .needsUser:
                summary.needsUser.append(file.name)
                continue
            case .download:
                try? FileManager.default.removeItem(at: partial)
            case .resume(let from):
                offset = from
            }

            try await gate.waitForTurn()
            let outcome: MetaClient.DownloadOutcome
            do {
                if file.source?.kind == .url, let raw = file.source?.url, let url = URL(string: raw) {
                    // Freier Download: ohne Token, an keinen Meta-Host gebunden.
                    outcome = try await PublicDownload.fetch(url, to: partial, resumeFrom: offset)
                } else {
                    outcome = try await client.download(id: file.id, to: partial, resumeFrom: offset)
                }
            } catch MetaError.denied(status: 404) where Fetcher.mayBeWithheld(file) {
                // Kein unerwarteter Ausgang, sondern Metas Antwort auf einen Zusatzinhalt, der nicht gekauft ist.
                // Die Datei wird vermerkt und nie wieder angefragt; die übrigen kommen jede genau einmal dran.
                await gate.requestFinished()
                try? FileManager.default.removeItem(at: partial)
                try store.noteWithheld(file, in: recipe)
                summary.withheld.append(file.name)
                log(L("not delivered by Meta for this account (HTTP 404): \(file.name) – most likely add-on content that isn't purchased. Skipped and remembered; it won't be requested again.",
                      "von Meta für dieses Konto nicht ausgeliefert (HTTP 404): \(file.name) – sehr wahrscheinlich ein Zusatzinhalt, der nicht gekauft ist. Übersprungen und vermerkt; die Datei wird nicht wieder angefragt."))
                continue
            } catch {
                await gate.requestFinished()
                throw error            // erster unerwarteter Ausgang: nichts weiter anfragen
            }
            await gate.requestFinished()

            let size = ContentStore.fileSize(partial) ?? 0
            if let expected = file.size ?? outcome.totalSize, expected != size {
                try? FileManager.default.removeItem(at: partial)
                throw FetchError.sizeMismatch(name: file.name, expected: expected, actual: size)
            }
            let digest = try Hashing.sha256(of: partial)
            if let expected = file.sha256 {
                guard expected.lowercased() == digest else {
                    try? FileManager.default.removeItem(at: partial)
                    throw FetchError.checksumMismatch(name: file.name)
                }
            } else {
                summary.learned.append(.init(name: file.name, size: size, sha256: digest))
            }
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            try afterFile?(file, final)
            summary.downloaded += 1
            summary.bytes += size - offset
            log(L("downloaded: \(file.name) (\(size) bytes\(outcome.resumed ? ", resumed" : "")\(file.sha256 == nil ? ", checksum newly recorded" : ", checksum matches"))",
                  "geladen: \(file.name) (\(size) Bytes\(outcome.resumed ? ", fortgesetzt" : "")\(file.sha256 == nil ? ", Prüfsumme neu erfasst" : ", Prüfsumme stimmt"))"))
        }
        return summary
    }
}
