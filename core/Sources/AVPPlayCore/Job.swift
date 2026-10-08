import Foundation

public enum JobError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case alreadyFinished(String)
    case cancelled(String)
    case toolchainChanged(was: String, now: String)

    public var description: String {
        switch self {
        case .notFound(let id): return L("No job with the ID '\(id)'.", "Kein Auftrag mit der Kennung '\(id)'.")
        case .alreadyFinished(let id): return L("The job \(id) is already finished.", "Der Auftrag \(id) ist bereits abgeschlossen.")
        case .cancelled(let id):
            return L("The job \(id) was cancelled. To try again, create a new job.",
                     "Der Auftrag \(id) wurde abgebrochen. Für einen neuen Versuch einen neuen Auftrag anlegen.")
        case .toolchainChanged(let was, let now):
            return L("The toolchain has changed since the job started (\(was) → \(now)). Please create a new job.",
                     "Die Toolchain hat sich seit Auftragsbeginn geändert (\(was) → \(now)). Bitte einen neuen Auftrag anlegen.")
        }
    }
}

/// Ein Auftrag: ein Spiel von „Konto prüfen“ bis „auf dem Gerät bereit“.
///
/// Beim Anlegen wird eingefroren, was den Ablauf bestimmt – das Rezept als Kopie, die Angaben des Nutzers,
/// der Stand der Toolchain. Spätere Änderungen am Katalog berühren einen laufenden Auftrag nicht.
/// Der Auftrag wird nach jedem Schritt gespeichert; ein unterbrochener lässt sich fortsetzen.
public struct Job: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable {
        case waiting, running, failed, finished, cancelled
    }

    public var id: String
    public var recipe: Recipe
    public var request: InstallRequest
    public var steps: [InstallStep]
    public var completed: [InstallStep] = []
    public var state: State = .waiting
    /// Der Schritt, der gerade läuft oder bei dem der Auftrag stehen geblieben ist.
    public var current: InstallStep?
    public var failure: String?
    /// Die Art des letzten Fehlers; fehlt bei Aufträgen, die vor dieser Angabe gespeichert wurden.
    public var failureKind: FailureKind?
    public var toolchainCommit: String
    public var created: Date
    public var updated: Date
    public var attempts = 0

    public init(recipe: Recipe, request: InstallRequest, steps: [InstallStep] = InstallStep.allCases,
                toolchainCommit: String, now: Date = Date(), suffix: String = String(UUID().uuidString.prefix(4)).lowercased()) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        self.id = "\(recipe.id)-\(stamp.string(from: now))-\(suffix)"
        self.recipe = recipe
        self.request = request
        self.steps = steps
        self.toolchainCommit = toolchainCommit
        self.created = now
        self.updated = now
    }

    public var remaining: [InstallStep] { steps.filter { !completed.contains($0) } }
    /// Ein Auftrag, der nur die Zusatzinhalte abgleicht und nichts baut.
    public var isAddonSync: Bool { !steps.contains(.build) }

    public static func == (a: Job, b: Job) -> Bool {
        a.id == b.id && a.state == b.state && a.completed == b.completed && a.current == b.current
            && a.failure == b.failure && a.attempts == b.attempts && a.request == b.request
    }
}

/// Aufträge auf der Platte: eine Datei je Auftrag, atomar geschrieben.
public struct JobStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static var defaultDirectory: URL {
        DataLocation.base.appendingPathComponent("jobs", isDirectory: true)
    }

    func url(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    public func save(_ job: Job) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(job).write(to: url(job.id), options: .atomic)
    }

    public func load(_ id: String) throws -> Job {
        guard Recipe.isSafeName(id), let data = try? Data(contentsOf: url(id)) else { throw JobError.notFound(id) }
        let job = try JSONDecoder.iso.decode(Job.self, from: data)
        // Ein gespeicherter Auftrag wird wie ein Rezept aus fremder Hand behandelt.
        try job.recipe.validate()
        return job
    }

    /// Alle Aufträge, neueste zuerst. Unlesbare Dateien werden übergangen.
    public func all() -> [Job] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? load($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.created > $1.created }
    }
}

/// Führt einen Auftrag Schritt für Schritt aus und hält seinen Stand fest.
public struct JobRunner: Sendable {
    let store: JobStore
    public init(store: JobStore) { self.store = store }

    /// Läuft ab dem ersten unerledigten Schritt. Ein Auftrag, der als „läuft“ gespeichert ist, wurde
    /// unterbrochen (Programm beendet, Rechner aus) und wird genauso fortgesetzt wie ein fehlgeschlagener.
    /// - Parameter currentToolchain: der jetzige Stand der Toolchain; weicht er vom eingefrorenen ab, wird
    ///   nicht weitergebaut.
    @discardableResult
    public func run(_ job: Job, currentToolchain: String, log: @Sendable (String) -> Void = { _ in },
                    perform: (InstallStep, Job) async throws -> Void) async throws -> Job {
        var job = job
        switch job.state {
        case .finished: throw JobError.alreadyFinished(job.id)
        case .cancelled: throw JobError.cancelled(job.id)
        case .waiting, .running, .failed: break
        }
        guard currentToolchain == job.toolchainCommit else {
            throw JobError.toolchainChanged(was: job.toolchainCommit, now: currentToolchain)
        }
        job.attempts += 1
        job.failure = nil
        job.failureKind = nil
        for step in job.remaining {
            job.state = .running
            job.current = step
            job.updated = Date()
            try store.save(job)
            log("[\(job.steps.firstIndex(of: step)! + 1)/\(job.steps.count)] \(step.title)")
            do {
                try await perform(step, job)
            } catch {
                job.state = .failed
                // Fehlertexte können Antworten von Meta enthalten; gespeichert wird nur die bereinigte Fassung.
                job.failure = Redaction.redact("\(error)")
                job.failureKind = FailureKind.of(error)
                job.updated = Date()
                try store.save(job)
                throw error
            }
            job.completed.append(step)
            job.updated = Date()
            try store.save(job)
        }
        job.state = .finished
        job.current = nil
        job.updated = Date()
        try store.save(job)
        return job
    }

    public func cancel(_ id: String) throws -> Job {
        var job = try store.load(id)
        guard job.state != .finished else { throw JobError.alreadyFinished(id) }
        job.state = .cancelled
        job.updated = Date()
        try store.save(job)
        return job
    }
}
