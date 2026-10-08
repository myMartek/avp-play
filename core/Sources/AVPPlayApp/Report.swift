import AppKit
import AVPPlayCore
import SwiftUI

/// Was jemand braucht, um bei einem Problem zu helfen – und nichts, was auf die Person zeigt.
extension AppModel {
    /// Der Bericht, auf Englisch (er geht an das Projekt). Enthalten: Versionen, der Stand der Einrichtung, der
    /// letzte angehaltene oder gewählte Auftrag mit dem Ende seines Verlaufs. Nicht enthalten: Name und Kennung
    /// des Geräts, Team-ID, Benutzername, Pfade im Benutzerordner, Zugangsdaten.
    func problemReport(for job: Job? = nil) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines: [String] = []
        lines.append("AVP Play \(appVersion) (\(canSelfUpdate ? "release build" : "local build"))")
        lines.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), language \(language.rawValue)")
        lines.append("Xcode: \(xcodeProblem.map { "PROBLEM – \($0)" } ?? xcodeText ?? "not checked")")
        lines.append("Vision Pro: \(device.map { "reachable, visionOS \($0.osVersion), developer mode \($0.developerMode ? "on" : "off")" } ?? "not reachable")")
        lines.append("Apple team: \(teamValid ? (team?.free == true ? "free team" : "set") : "not set")")
        let accountText: String
        switch account {
        case .signedIn: accountText = "signed in"
        case .signedOut: accountText = "signed out"
        case .checking, .unknown: accountText = "not checked"
        case .problem(let why): accountText = "PROBLEM – \(why)"
        }
        lines.append("Meta account: \(accountText); sign-in tool \(toolPresent ? "set up" : "not set up")")
        lines.append("Toolchain: \(toolchainText ?? "not installed")")
        lines.append("Games on the device: " + games.map { g -> String in
            let state: String
            switch g.status.onDevice {
            case .current: state = "current"
            case .olderToolchain: state = "older toolchain"
            case .unstamped: state = "older build"
            case .notInstalled: state = "not installed"
            case .unknown: state = "unknown"
            }
            return "\(g.id) \(state)"
        }.joined(separator: ", "))

        let subject = job ?? jobs.first { phase(of: $0) == .stopped } ?? jobs.first { $0.id == selectedJob }
        if let j = subject {
            lines.append("")
            lines.append("Job: \(j.recipe.id) \(j.recipe.versionName), \(phase(of: j)), step \(j.current?.rawValue ?? "-"), "
                         + "\(j.completed.count)/\(j.steps.count) done, attempts \(j.attempts)")
            if let failure = j.failure { lines.append("Failure (\(j.failureKind?.rawValue ?? "unclassified")): \(failure)") }
            let log = self.log(for: j.id).suffix(40)
            if !log.isEmpty {
                lines.append("Last log lines:")
                lines.append(contentsOf: log)
            }
        }
        var hide = [teamId]
        if let name = device?.name { hide.append(name) }
        if let udid = device?.udid { hide.append(udid) }
        return Redaction.anonymize(lines.joined(separator: "\n"), alsoHide: hide.filter { !$0.isEmpty })
    }
}

/// Zeigt den Bericht, bevor er irgendwohin geht: Der Nutzer sieht, was er weitergibt, und kopiert es selbst.
struct ReportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: Job?
    @State private var copied = false

    static let issues = URL(string: "https://github.com/myMartek/avp-play/issues/new")!

    var body: some View {
        let report = model.problemReport(for: job)
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Report a Problem", "Ein Problem melden")).font(.title2.bold())
            Text(L("This is what helps to find the cause. It contains no names, account details, device identifiers or paths from your home folder – please look it over anyway. Nothing is sent by the app: you copy the text and paste it into the report yourself.",
                   "Das hilft, die Ursache zu finden. Es enthält keine Namen, Kontodaten, Gerätekennungen oder Pfade aus deinem Benutzerordner – sieh es trotzdem durch. Die App sendet nichts: Du kopierst den Text und fügst ihn selbst in die Meldung ein."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(report)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 280)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if copied { Label(L("Copied", "Kopiert"), systemImage: "checkmark").foregroundStyle(.green) }
                Spacer()
                Button(L("Close", "Schließen")) { dismiss() }
                Button(L("Copy", "Kopieren")) { copy(report) }
                Button(L("Copy and Open GitHub", "Kopieren und GitHub öffnen")) {
                    copy(report)
                    NSWorkspace.shared.open(ReportSheet.issues)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}
