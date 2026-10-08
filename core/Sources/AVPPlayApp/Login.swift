import Foundation
import AVPPlayCore
import SwiftUI

/// Eine Anmeldung bei Meta über Metas eigenes Werkzeug.
///
/// Die Oberfläche ist nur das Terminal dazu: Was das Werkzeug fragt, wird gezeigt; was der Nutzer antwortet,
/// geht unverändert an das Werkzeug und wird hier weder gespeichert noch protokolliert. Der Token, den das
/// Werkzeug am Ende ausgibt, erscheint nie – `MetaLogin` hält ihn zurück, und er geht direkt in den Schlüsselbund.
@MainActor
final class LoginSession: ObservableObject {
    enum Outcome: Equatable { case success, failure(String) }

    @Published var transcript = ""
    @Published var outcome: Outcome?
    @Published var running = false
    private var toTool: FileHandle?

    /// Fragt das Werkzeug gerade nach etwas Geheimem? Dann wird verdeckt getippt.
    var wantsSecret: Bool {
        let last = transcript.split(separator: "\n").last.map { $0.lowercased() } ?? ""
        return last.contains("password") || last.contains("passwort")
    }

    func start(tool: URL) {
        guard !running else { return }
        do { try MetaTool(url: tool).verify() } catch {
            outcome = .failure("\(error)")
            return
        }
        transcript = ""
        outcome = nil
        running = true
        let input = Pipe(), output = Pipe()
        toTool = input.fileHandleForWriting
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = LoginSession.plain(String(decoding: data, as: UTF8.self))
            Task { @MainActor in self.transcript += text }
        }
        let inFD = input.fileHandleForReading.fileDescriptor
        let outFD = output.fileHandleForWriting.fileDescriptor
        Thread.detachNewThread {
            let result: Outcome
            do {
                let token = try MetaLogin.run(tool: tool, input: inFD, output: outFD)
                try TokenStore().write(token: token)
                result = .success
            } catch {
                result = .failure(Redaction.redact("\(error)"))
            }
            // Erst hier schließen: die Deskriptoren müssen leben, solange das Werkzeug läuft.
            try? output.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            Task { @MainActor in
                output.fileHandleForReading.readabilityHandler = nil
                self.toTool = nil
                self.running = false
                self.outcome = result
            }
        }
    }

    /// Die Antwort und die Eingabetaste, so wie ein Terminal sie schickt (Wagenrücklauf, nicht Zeilenvorschub):
    /// Bei verdeckter Eingabe liest das Werkzeug roh und wartet genau darauf.
    func send(_ answer: String) {
        try? toTool?.write(contentsOf: Data((answer + "\r").utf8))
    }

    /// Strg-C an das Werkzeug: Es hängt an einem eigenen Terminal und beendet sich daraufhin selbst.
    func abort() {
        try? toTool?.write(contentsOf: Data([0x03]))
    }

    /// Steuerzeichen eines Terminals entfernen; übrig bleibt der lesbare Text.
    nonisolated static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .filter { $0 == "\n" || $0 == "\t" || !($0.unicodeScalars.first.map { $0.value < 0x20 } ?? false) }
    }
}

struct LoginSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = LoginSession()
    @State private var answer = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Sign In to Meta", "Bei Meta anmelden")).font(.title2.bold())
            Text(L("Sign-in runs through Meta’s own tool. What you type here goes only to that tool; the only thing stored is the access key Meta returns – in this Mac’s keychain.", "Die Anmeldung läuft über Metas eigenes Werkzeug. Was du hier eintippst, geht nur an dieses Werkzeug; gespeichert wird allein der Zugangsschlüssel, den Meta zurückgibt – im Schlüsselbund dieses Macs."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.transcript.isEmpty ? L("Starting the tool …", "Das Werkzeug wird gestartet …") : session.transcript)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .id("end")
                }
                .frame(minHeight: 150, maxHeight: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: session.transcript) { proxy.scrollTo("end", anchor: .bottom) }
            }

            switch session.outcome {
            case .success:
                Label(L("Signed in. The access key is in the keychain.", "Angemeldet. Der Zugangsschlüssel liegt im Schlüsselbund."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                HStack {
                    Group {
                        if session.wantsSecret {
                            SecureField(L("Answer (hidden as you type)", "Antwort (wird verdeckt)"), text: $answer)
                        } else {
                            TextField(L("Answer", "Antwort"), text: $answer)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                    Button(L("Send", "Senden"), action: submit).keyboardShortcut(.defaultAction)
                }
                .disabled(!session.running)
            }

            HStack {
                Spacer()
                if session.outcome == nil {
                    Button(L("Cancel", "Abbrechen"), role: .cancel) {
                        session.abort()
                        dismiss()
                    }
                } else {
                    if session.outcome != .success {
                        Button(L("Try Again", "Noch einmal")) { session.start(tool: Probe.metaToolURL) }
                    }
                    Button(L("Close", "Schließen")) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            session.start(tool: Probe.metaToolURL)
            focused = true
        }
        .onChange(of: session.outcome) {
            if session.outcome == .success { model.checkAccount() }
        }
    }

    private func submit() {
        session.send(answer)
        answer = ""
        focused = true
    }
}
