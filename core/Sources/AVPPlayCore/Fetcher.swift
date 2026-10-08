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
    }

    let client: MetaClient
    let store: ContentStore
    let gate: RequestGate

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
            summary.downloaded += 1
            summary.bytes += size - offset
            log(L("downloaded: \(file.name) (\(size) bytes\(outcome.resumed ? ", resumed" : "")\(file.sha256 == nil ? ", checksum newly recorded" : ", checksum matches"))",
                  "geladen: \(file.name) (\(size) Bytes\(outcome.resumed ? ", fortgesetzt" : "")\(file.sha256 == nil ? ", Prüfsumme neu erfasst" : ", Prüfsumme stimmt"))"))
        }
        return summary
    }
}
