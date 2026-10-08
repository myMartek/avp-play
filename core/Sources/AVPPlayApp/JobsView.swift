import AppKit
import AVPPlayCore
import SwiftUI

/// Aufträge: was läuft, was wartet, was angehalten wurde – und bei jedem der nächste sinnvolle Schritt.
struct JobsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.jobs.isEmpty {
            ContentUnavailableView(L("No Jobs Yet", "Noch keine Aufträge"), systemImage: "list.bullet.clipboard",
                                   description: Text(L("Pick a game under “Games” and click “Install”.", "Wähle unter „Spiele“ ein Spiel und klicke auf „Installieren“.")))
                .navigationTitle(L("Jobs", "Aufträge"))
        } else {
            HSplitView {
                List(model.jobs, selection: $model.selectedJob) { job in
                    JobRow(job: job).tag(job.id)
                }
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
                Group {
                    if let job = model.jobs.first(where: { $0.id == model.selectedJob }) {
                        JobDetail(job: job)
                    } else {
                        Text(L("Select a job", "Auftrag auswählen")).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(L("Jobs", "Aufträge"))
        }
    }
}

extension AppModel {
    /// Der Stand eines Auftrags, wie die Oberfläche ihn nennt. „Läuft“ in der Datei heißt nur dann wirklich
    /// läuft, wenn dieses Programm ihn gerade ausführt – sonst wurde er unterbrochen.
    func phase(of job: Job) -> JobPhase {
        if job.id == runningJob { return .running }
        if queued.contains(job.id) { return .queued }
        switch job.state {
        case .finished: return .finished
        case .cancelled: return .cancelled
        case .failed: return .stopped
        case .running: return .interrupted
        case .waiting: return .interrupted
        }
    }
}

enum JobPhase {
    case running, queued, finished, cancelled, stopped, interrupted

    var text: String {
        switch self {
        case .running: return L("Running", "Läuft")
        case .queued: return L("Waiting", "Wartet")
        case .finished: return L("Finished", "Abgeschlossen")
        case .cancelled: return L("Cancelled", "Abgebrochen")
        case .stopped: return L("Stopped", "Angehalten")
        case .interrupted: return L("Interrupted", "Unterbrochen")
        }
    }
    var symbol: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .queued: return "clock"
        case .finished: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .stopped: return "exclamationmark.triangle.fill"
        case .interrupted: return "pause.circle"
        }
    }
    var color: Color {
        switch self {
        case .running: return .blue
        case .finished: return .green
        case .stopped: return .orange
        case .queued, .cancelled, .interrupted: return .secondary
        }
    }
    var canResume: Bool { self == .stopped || self == .interrupted }
    var canCancel: Bool { self != .finished && self != .cancelled }
}

struct JobRow: View {
    @EnvironmentObject var model: AppModel
    let job: Job

    var body: some View {
        let phase = model.phase(of: job)
        HStack(spacing: 10) {
            Image(systemName: phase.symbol).foregroundStyle(phase.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.recipe.title).font(.headline).lineLimit(1)
                Text(L("\(phase.text) · \(job.completed.count) of \(job.steps.count) steps", "\(phase.text) · \(job.completed.count) von \(job.steps.count) Schritten"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(job.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct JobDetail: View {
    @EnvironmentObject var model: AppModel
    let job: Job

    var body: some View {
        let phase = model.phase(of: job)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.recipe.title).font(.title2.bold())
                    Label(phase.text, systemImage: phase.symbol).foregroundStyle(phase.color)
                }
                Spacer()
                if phase.canResume {
                    Button(L("Resume", "Fortsetzen")) { model.resume(job) }.buttonStyle(.borderedProminent)
                }
                if phase.canCancel {
                    Button(L("Cancel", "Abbrechen"), role: .destructive) { model.cancel(job) }
                }
            }

            if phase == .stopped, let failure = job.failure {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L("What Went Wrong", "Woran es lag"), systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        Text(failure).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Label(advice(job.failureKind ?? .other), systemImage: "arrow.turn.down.right")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            switch job.failureKind ?? .other {
                            case .signIn, .setup:
                                Button(L("Open Setup", "Einrichtung öffnen")) { model.section = .setup }
                            case .ownFiles, .notOwned:
                                Button(L("Open Game Page", "Seite des Spiels öffnen")) {
                                    model.gamePath = [job.recipe.id]
                                    model.section = .games
                                }
                            case .build:
                                Button(L("Show Build Log", "Bauprotokoll zeigen")) { reveal(".last-build.log") }
                            case .copy:
                                Button(L("Show Copy Log", "Kopierprotokoll zeigen")) { reveal(".last-sync.log") }
                            case .device:
                                Button(L("Check Again", "Neu prüfen")) { model.refresh() }
                            case .gameRunning, .download, .other:
                                EmptyView()
                            }
                            Button(L("Report This Problem …", "Dieses Problem melden …")) {
                                model.reportJob = job
                                model.showReport = true
                            }
                        }
                        Text(L("“Resume” continues where it stopped. Whatever has been downloaded or copied is kept.", "Mit „Fortsetzen“ geht es an derselben Stelle weiter. Was schon geladen oder kopiert ist, bleibt erhalten."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            if phase == .interrupted {
                Text(L("This job was interrupted, for example because the app was quit. “Resume” continues where it stopped.", "Dieser Auftrag wurde unterbrochen, zum Beispiel weil das Programm beendet wurde. „Fortsetzen“ macht an derselben Stelle weiter."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(job.steps, id: \.self) { step in
                    HStack(spacing: 10) {
                        stepIcon(step, phase: phase).frame(width: 18)
                        Text(step.title)
                            .foregroundStyle(job.completed.contains(step) || job.current == step ? .primary : .secondary)
                    }
                }
            }

            if phase == .running, job.current == .fetch {
                // Der Stand kommt aus dem Bestand selbst (vorhandene und angefangene Dateien), alle zwei Sekunden.
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    if let progress = model.downloadProgress(job) {
                        ProgressLine(done: progress.done, total: progress.total,
                                     verb: L("downloaded", "geladen")).id("fetch-\(job.id)")
                    }
                }
            }
            if phase == .running, job.current == .stage, let progress = model.copyProgress[job.id], progress.total > 0 {
                // Das Gerät meldet nur ganze Dateien; bei wenigen großen Dateien steht der Balken dazwischen still.
                ProgressLine(done: progress.done, total: progress.total,
                             verb: L("copied to the Vision Pro", "auf die Vision Pro kopiert")).id("stage-\(job.id)")
            }

            HStack {
                Text(L("Log", "Verlauf")).font(.headline)
                Spacer()
                Button(L("Show Log File", "Verlaufsdatei zeigen")) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.logURL(job: job.id)])
                }
                .controlSize(.small)
            }
            LogView(lines: model.log(for: job.id))
        }
        .padding(20)
    }

    /// Der nächste Handgriff zu einer Fehlerart, als Satz.
    private func advice(_ kind: FailureKind) -> String {
        switch kind {
        case .gameRunning:
            return L("Quit the game on the Vision Pro, then choose “Resume”.", "Beende das Spiel auf der Vision Pro und wähle dann „Fortsetzen“.")
        case .notOwned:
            return L("The Meta account you are signed in with does not own this game. If you bought it with another account, sign in with that one under “Setup”.",
                     "Das angemeldete Meta-Konto besitzt dieses Spiel nicht. Wenn du es mit einem anderen Konto gekauft hast, melde dich unter „Einrichtung“ damit an.")
        case .signIn:
            return L("Your sign-in to Meta is missing or no longer valid. Sign in again under “Setup”, then resume.",
                     "Die Anmeldung bei Meta fehlt oder gilt nicht mehr. Melde dich unter „Einrichtung“ neu an und setze dann fort.")
        case .device:
            return L("The Vision Pro did not respond. Turn it on, put it on or unlock it, keep it on the same Wi-Fi as this Mac, then resume.",
                     "Die Vision Pro hat nicht geantwortet. Einschalten, aufsetzen oder entsperren, im selben WLAN wie dieser Mac lassen und dann fortsetzen.")
        case .build:
            return L("Building or installing failed. Most often this is signing: check the team under “Setup” and open Xcode once to confirm any pending prompts. The build log has the details.",
                     "Bauen oder Installieren ist gescheitert. Meist liegt es an der Signatur: Team unter „Einrichtung“ prüfen und Xcode einmal öffnen, um offene Rückfragen zu bestätigen. Das Bauprotokoll nennt die Einzelheiten.")
        case .copy:
            return L("Copying to the Vision Pro was interrupted – usually because the headset went to sleep. Keep it on and awake, then resume; files already copied are skipped.",
                     "Das Kopieren auf die Vision Pro wurde unterbrochen – meist, weil das Headset eingeschlafen ist. Aufbehalten und wach halten, dann fortsetzen; schon kopierte Dateien werden übersprungen.")
        case .download:
            return L("A download did not complete. Check your internet connection, then resume; it continues where it stopped.",
                     "Ein Download wurde nicht fertig. Internetverbindung prüfen und fortsetzen; es geht dort weiter, wo es aufgehört hat.")
        case .ownFiles:
            return L("Files that you provide yourself are missing. The game’s page says which, and lets you choose the folder.",
                     "Es fehlen Dateien, die du selbst bereitstellst. Die Seite des Spiels nennt sie und lässt dich den Ordner wählen.")
        case .setup:
            return L("Something in “Setup” is missing or has changed.", "In der „Einrichtung“ fehlt etwas oder hat sich geändert.")
        case .other:
            return L("Try “Resume”. If it stops at the same place again, the log below shows what happened.",
                     "Versuche „Fortsetzen“. Hält es an derselben Stelle wieder an, zeigt der Verlauf unten, was passiert ist.")
        }
    }

    private func reveal(_ name: String) {
        let file = model.paths.store.directory(for: job.recipe).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    @ViewBuilder
    private func stepIcon(_ step: InstallStep, phase: JobPhase) -> some View {
        if job.completed.contains(step) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if job.current == step, phase == .running {
            ProgressView().controlSize(.small)
        } else if job.current == step, phase == .stopped {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

/// Ein Balken mit Stand in Gigabyte und, sobald es etwas zu rechnen gibt, der geschätzten Restzeit.
/// Die Schätzung beginnt bei dem Stand, den die Zeile beim ersten Erscheinen sieht – was vorher schon da war
/// (ein fortgesetzter Download), zählt nicht als Tempo.
struct ProgressLine: View {
    let done: Int64
    let total: Int64
    let verb: String
    @State private var start: (date: Date, done: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(min(done, total)), total: Double(max(total, 1)))
            Text("\(Installer.gigabytes(done)) \(L("of", "von")) \(Installer.gigabytes(total)) \(verb)\(remaining.map { " · " + $0 } ?? "")")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .onAppear { if start == nil { start = (Date(), done) } }
    }

    private var remaining: String? {
        guard let start, done > start.done, done < total else { return nil }
        let elapsed = Date().timeIntervalSince(start.date)
        guard elapsed >= 10 else { return nil }
        let seconds = Double(total - done) / (Double(done - start.done) / elapsed)
        return ProgressLine.remainingText(seconds: seconds)
    }

    /// „noch etwa 12 Minuten“ – grob, denn genauer ist die Schätzung nicht.
    static func remainingText(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 90 { return L("about a minute left", "noch etwa eine Minute") }
        if seconds < 3600 * 1.5 {
            let m = Int((seconds / 60).rounded())
            return L("about \(m) minutes left", "noch etwa \(m) Minuten")
        }
        let h = (seconds / 3600 * 2).rounded() / 2
        let text = h == h.rounded() ? String(Int(h)) : String(format: "%.1f", h)
        return L("about \(text) hours left", "noch etwa \(text.replacingOccurrences(of: ".", with: ",")) Stunden")
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(lines.isEmpty ? L("Nothing yet.", "Noch nichts.") : lines.suffix(800).joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("end")
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
