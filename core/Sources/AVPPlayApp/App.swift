import AppKit
import AVPPlayCore
import SwiftUI

@main
struct AVPPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppDelegate.model

    var body: some Scene {
        Window("AVP Play", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 760)
        .environment(\.locale, L10n.locale)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(L("Check Again", "Neu prüfen")) { model.refresh() }.keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environmentObject(model).id(model.language)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auch ohne Programmpaket (beim Entwickeln mit `swift run`) als normales Programm mit Fenster auftreten.
        NSApp.setActivationPolicy(.regular)
        // Beim Fotografieren der Ansichten nicht nach vorn drängen: wer gerade am Rechner arbeitet, soll weder
        // ein Fenster vor die Nase bekommen noch versehentlich hineinklicken.
        if Snapshot.directory == nil { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppDelegate.model.runningJob != nil, Snapshot.directory == nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("A job is still running.", "Es läuft noch ein Auftrag.")
        alert.informativeText = L("If you quit now, it will be interrupted. You can resume it under “Jobs” the next time you open the app; files already downloaded are kept.", "Wenn du jetzt beendest, wird er unterbrochen. Beim nächsten Start lässt er sich unter „Aufträge“ fortsetzen; schon geladene Dateien bleiben erhalten.")
        alert.addButton(withTitle: L("Keep Running", "Weiterlaufen lassen"))
        alert.addButton(withTitle: L("Quit", "Beenden"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.section }, set: { model.section = $0 ?? .games })) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { DeviceChip().padding(12) }
        } detail: {
            Group {
                switch model.section {
                case .games: GamesView()
                case .jobs: JobsView()
                case .setup: SetupView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = model.notice { NoticeBar(text: notice) }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.refresh() } label: {
                        if model.refreshing { ProgressView().controlSize(.small) }
                        else { Label(L("Check Again", "Neu prüfen"), systemImage: "arrow.clockwise") }
                    }
                    .help(L("Check the device, the library and the setup again", "Gerät, Bestand und Einrichtung neu prüfen"))
                }
            }
        }
        // Die Texte werden beim Zeichnen gewählt; mit der Sprache als Kennung entsteht die Ansicht neu.
        .id(model.language)
        .task {
            model.installBundledToolchainIfNewer()
            model.refresh()
            model.checkAccount()
            await Snapshot.runIfRequested(model: model) { openSettings() }
        }
    }

    /// Wie viele Punkte der Einrichtung noch offen sind bzw. wie viele Aufträge Aufmerksamkeit brauchen.
    private func badge(for section: AppSection) -> Int {
        switch section {
        case .games: return 0
        case .jobs: return model.jobs.filter { model.phase(of: $0) == .stopped || model.phase(of: $0) == .running }.count
        case .setup:
            return [model.xcodeProblem != nil, model.device == nil, !model.teamValid,
                    model.account == .signedOut, model.toolchainText == nil].filter { $0 }.count
        }
    }
}

struct DeviceChip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "visionpro")
                .foregroundStyle(model.device == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.device?.name ?? L("No Vision Pro", "Keine Vision Pro")).font(.callout.weight(.medium)).lineLimit(1)
                Text(model.device == nil ? L("not reachable", "nicht erreichbar") : L("connected", "verbunden")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct NoticeBar: View {
    @EnvironmentObject var model: AppModel
    let text: String

    var body: some View {
        HStack {
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("OK") { model.notice = nil }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

/// `--snapshot <Ordner>`: jede Ansicht einmal zeigen, als Bild ablegen und beenden. Damit lässt sich die
/// Oberfläche prüfen, ohne dass jemand klickt.
@MainActor
enum Snapshot {
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func runIfRequested(model: AppModel, openSettings: () -> Void) async {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        hideWindows()
        await pause(1)
        while model.refreshing || model.account == .checking { await pause(0.3) }
        await pause(1)
        // die Besitzabfragen laufen mit Abstand; höchstens eine Minute darauf warten
        var waited = 0.0
        while model.checkingOwnership, waited < 60 { await pause(0.5); waited += 0.5 }
        capture("1-spiele", dir)
        for id in ["doom3quest", "walkabout"] where model.games.contains(where: { $0.id == id }) {
            model.gamePath = [id]
            await pause(1.2)
            capture("2-spiel-\(id)", dir)
        }
        model.gamePath = []
        // `--install <Kennung>`: den Auftrag wirklich über die Oberfläche auslösen und bis zum Ende zeigen.
        if let i = CommandLine.arguments.firstIndex(of: "--install"), i + 1 < CommandLine.arguments.count,
           let game = model.games.first(where: { $0.id == CommandLine.arguments[i + 1] }) {
            if let why = model.blocker(for: game) { model.notice = why } else { model.install(game) }
            await pause(8)
            capture("3-auftrag-laeuft", dir)
            while model.runningJob != nil { await pause(1) }
            await pause(1.5)
        }
        model.section = .jobs
        await pause(1.2)
        capture("3-auftraege", dir)
        model.section = .setup
        await pause(1.2)
        capture("4-einrichtung", dir)
        openSettings()
        await pause(0.2)
        hideWindows()
        await pause(1.3)
        let settings = NSApp.keyWindow
        capture("5-einstellungen", dir, window: settings)
        // `--switch-language`: die Sprache im laufenden Programm wechseln, beide Fenster zeigen, zurückstellen.
        if CommandLine.arguments.contains("--switch-language") {
            let before = model.languageChoice
            model.languageChoice = model.language == .de ? .en : .de
            await pause(1)
            while model.refreshing { await pause(0.3) }
            await pause(1)
            capture("6-gewechselt-einstellungen", dir, window: settings)
            capture("6-gewechselt-einrichtung", dir)
            model.languageChoice = before
            await pause(0.5)
        }
        NSApp.terminate(nil)
    }

    /// Macht alle Fenster unsichtbar und unklickbar; gezeichnet werden sie trotzdem.
    static func hideWindows() {
        for window in NSApp.windows {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }

    static func capture(_ name: String, _ dir: URL, window chosen: NSWindow? = nil) {
        hideWindows()
        guard let window = chosen ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.identifier?.rawValue.contains("main") == true })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
