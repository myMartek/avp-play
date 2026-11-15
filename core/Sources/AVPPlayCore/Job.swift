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
    /// Der Platz in der Reihe: eine fortlaufende Nummer, vergeben, wenn der Auftrag sich anstellt; die kleinere
    /// kommt zuerst dran. Sie hängt an keiner Uhrzeit – „angelegt“ ist nur auf die Sekunde gespeichert, und ein
    /// Sammelauftrag legt viele Aufträge in derselben an. Nach dem Lauf bleibt sie als Platz in der Liste stehen.
    /// Fehlt bei Aufträgen, die vor dieser Angabe gespeichert wurden.
    public var queuePosition: Int?

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
    public var isAddonSync: Bool { !steps.contains(.build) && steps.contains(.stage) }
    /// Ein Auftrag, der nur lädt: nichts wird gebaut, nichts geht aufs Gerät. Er braucht weder Xcode noch eine
    /// Toolchain, ein Apple-Team oder die Vision Pro.
    public var isDownloadOnly: Bool { !steps.contains(.build) && !steps.contains(.stage) }

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

    /// Nimmt einen Auftrag aus der Liste: seine Datei und sein Verlauf verschwinden. Geladene Dateien, Gebautes und
    /// alles auf dem Gerät bleiben, wie sie sind.
    public func remove(_ id: String) {
        guard Recipe.isSafeName(id) else { return }
        try? FileManager.default.removeItem(at: url(id))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).log"))
    }

    /// Alle Aufträge in der Reihenfolge der Liste, der zuletzt angestellte zuerst. Unlesbare Dateien werden übergangen.
    ///
    /// Oben stehen die Aufträge mit einem Platz in der Reihe, der höchste zuerst – Wartende kommen also von unten
    /// nach oben dran. Darunter folgen die von früher, die noch keinen Platz kennen, der neueste zuerst. Bei
    /// gleichem Stand entscheidet die Kennung: Der Ordner nennt seine Dateien in keiner festen Reihenfolge, und die
    /// Liste soll nicht davon abhängen.
    public func all() -> [Job] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? load($0.deletingPathExtension().lastPathComponent) }
            .sorted { a, b in
                switch (a.queuePosition, b.queuePosition) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.created != b.created ? a.created > b.created : a.id > b.id
                }
            }
    }

    /// Stellt einen Auftrag hinten an und speichert ihn: Er bekommt den Platz nach allen, die schon einen haben.
    /// Wer seinen Platz hat und noch nie drankam (das Programm wurde beendet, während er wartete), behält ihn – so
    /// steht die Reihe nach einem Neustart wie vorher. Wer schon einmal lief, stellt sich neu hinten an.
    @discardableResult
    public func enqueue(_ job: Job) throws -> Job {
        var job = job
        if job.queuePosition == nil || job.state != .waiting {
            job.queuePosition = (all().compactMap(\.queuePosition).max() ?? 0) + 1
        }
        try save(job)
        return job
    }

    /// Legt fest, in welcher Reihenfolge die genannten Aufträge drankommen – der erste zuerst. Sie tauschen dazu
    /// nur untereinander die Plätze, die sie schon haben; kein anderer Auftrag rückt dabei. Unbekannte Kennungen
    /// und Aufträge ohne Platz werden übergangen.
    public func reorder(_ ids: [String]) throws {
        let jobs = ids.compactMap { try? load($0) }.filter { $0.queuePosition != nil }
        let places = jobs.compactMap(\.queuePosition).sorted()
        for (job, place) in zip(jobs, places) where job.queuePosition != place {
            var job = job
            job.queuePosition = place
            try save(job)
        }
    }

    /// Die Wartenden in der Reihenfolge, in der sie drankommen: in der Liste von unten nach oben.
    /// - Parameter listed: die Aufträge in der Reihenfolge der Liste, wie `all()` sie liefert.
    public static func runOrder(of waiting: [String], in listed: [Job]) -> [String] {
        let waiting = Set(waiting)
        return listed.reversed().map(\.id).filter(waiting.contains)
    }
}

extension Job {
    /// The state a job's toolchain is in right now, to hold against the one frozen when the job was created.
    ///
    /// A toolchain the game's recipe names (`Recipe.Toolchain.source`) and that is not on this Mac yet is in the
    /// state the recipe pins: the job fetches exactly that commit as its first act, or fails. Without this a game's
    /// first job could never start – there is no toolchain to ask before it has run. `nil`: nothing is there and
    /// nothing says what will be.
    public static func toolchainCommit(recipe: Recipe, toolchain path: String, external: ExternalToolchains = ExternalToolchains()) -> String? {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        if let there = try? Toolchain(root: root) { return there.commit() }
        guard recipe.toolchain.kind != nil, let source = recipe.toolchain.source, !path.isEmpty,
              external.directory(for: recipe)?.standardizedFileURL.path == root.path else { return nil }
        return source.shortCommit
    }

    public func currentToolchainCommit(external: ExternalToolchains = ExternalToolchains()) -> String? {
        Job.toolchainCommit(recipe: recipe, toolchain: request.toolchain, external: external)
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
        // Wer nur lädt, benutzt die Toolchain nicht; ihr Stand spielt dann keine Rolle.
        guard job.isDownloadOnly || currentToolchain == job.toolchainCommit else {
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
