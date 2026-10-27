import AppKit
import AVPPlayCore
import ServiceManagement
import SwiftUI

extension AppModel {
    /// Der Zustand für das Fenster der Menüleiste.
    func menuBarStatus(remote: RemoteServer) -> MenuBarStatus {
        let running = runningJob.flatMap { id in jobs.first { $0.id == id } }
        let progress = runningJob.flatMap { copyProgress[$0] }
        let job = running.map { MenuBarStatus.RunningJob(title: $0.recipe.title, step: progress?.step ?? $0.current,
                                                           done: progress?.done, total: progress?.total) }
        let remoteState: MenuBarStatus.Remote =
            !remote.enabled ? .off
            : remote.problem.map { .problem($0) }
            ?? (remote.connected.isEmpty ? .waiting : .connected(remote.connected.count))
        let renewal = (usesFreeTeam || renewInBackground)
            ? MenuBarStatus.Renewal(inBackground: renewInBackground, intervalHours: renewIntervalHours,
                                    lastRun: renewalReport?.ran, nextExpiry: MenuBarStatus.nextExpiry(in: renewalReport))
            : nil
        return MenuBarStatus(job: job, waiting: queued.count,
                             failed: jobs.filter { phase(of: $0) == .stopped }.count,
                             deviceName: device?.name, remote: remoteState, renewal: renewal)
    }
}

/// Das Symbol in der Menüleiste: die Brille, beim Arbeiten mit dem Fortschritt daneben.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var remote: RemoteServer

    var body: some View {
        let status = model.menuBarStatus(remote: remote)
        HStack(spacing: 4) {
            Image(systemName: status.needsAttention ? "exclamationmark.triangle" : "visionpro")
            if let percent = status.percent { Text("\(percent) %").monospacedDigit() }
        }
    }
}

/// Das Fenster unter dem Symbol: Auftrag, Gerät, Fernsteuerung, Erneuerung und die wichtigsten Knöpfe.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var remote: RemoteServer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.menuBarStatus(remote: remote)
        VStack(alignment: .leading, spacing: 10) {
            Text("AVP Play").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(status.jobLine).font(.callout.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 8)
                    if status.job != nil || status.failed > 0 || status.waiting > 0 {
                        Button(L("Jobs", "Aufträge")) { showMain(section: .jobs) }.buttonStyle(.link).font(.caption)
                    }
                }
                if let detail = status.jobDetail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if status.job != nil {
                    if let f = status.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
            Divider()
            Label(status.deviceLine, systemImage: "visionpro").font(.callout)
            Label(status.remoteLine, systemImage: "dot.radiowaves.left.and.right").font(.callout)
            if let line = status.renewalLine() {
                Label(line, systemImage: "signature").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button(L("Open AVP Play", "AVP Play öffnen")) { showMain() }.keyboardShortcut(.defaultAction)
                Button(L("Check Again", "Neu prüfen")) { model.refresh() }.disabled(model.refreshing)
                Spacer()
                Button(L("Quit", "Beenden")) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
        // Der Hintergrunddienst schreibt seinen Bericht in eine Datei; beim Aufklappen den neuesten lesen.
        .onAppear { model.renewalReport = RenewalReport.load() }
    }

    private func showMain(section: AppSection? = nil) {
        // Das Fenster der Menüleiste ginge sonst nicht von selbst zu und läge über dem Hauptfenster.
        let panel = NSApp.keyWindow.flatMap { AppDelegate.isMain($0) ? nil : $0 }
        if let section { model.section = section }
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        panel?.close()
    }
}

/// „Bei der Anmeldung öffnen“ über `SMAppService`. Geht nur aus einem Programmpaket, nicht mit `swift run`.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static func set(_ on: Bool) throws { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
}

/// Der Abschnitt „Menüleiste“ in den Einstellungen.
struct MenuBarSettings: View {
    @AppStorage(MenuBarPreferences.showKey) private var menuBarShow = true
    @AppStorage(MenuBarPreferences.keepRunningKey) private var menuBarKeepRunning = false
    @State private var loginOn = LoginItem.isOn
    @State private var loginApproval = LoginItem.needsApproval
    @State private var loginProblem: String?

    var body: some View {
        Section(L("Menu Bar", "Menüleiste")) {
            Toggle(L("Show AVP Play in the menu bar", "AVP Play in der Menüleiste zeigen"), isOn: $menuBarShow)
            Toggle(L("Keep running in the menu bar when the window is closed", "In der Menüleiste weiterlaufen, wenn das Fenster geschlossen ist"),
                   isOn: $menuBarKeepRunning)
                .disabled(!menuBarShow)
            Text(L("With the window closed, jobs keep going, AVP Play Remote can still reach this Mac, and the Dock icon goes away until you open the window again from the menu bar. Without this, closing the window quits AVP Play, as before. Background renewal of signatures works either way. With this and “Open at login” on, AVP Play starts in the menu bar only, without its window.",
                   "Bei geschlossenem Fenster laufen Aufträge weiter, AVP Play Remote erreicht diesen Mac weiterhin, und das Symbol im Dock verschwindet, bis du das Fenster aus der Menüleiste wieder öffnest. Ohne das beendet das Schließen des Fensters AVP Play, wie bisher. Die Erneuerung der Signaturen im Hintergrund läuft so oder so. Ist zusätzlich „Bei der Anmeldung öffnen“ an, startet AVP Play bei der Anmeldung nur in der Menüleiste, ohne Fenster."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L("Open at login", "Bei der Anmeldung öffnen"), isOn: Binding(get: { loginOn }, set: { on in
                do {
                    try LoginItem.set(on)
                    loginProblem = nil
                } catch {
                    loginProblem = L("macOS refused: \(error.localizedDescription)", "macOS hat abgelehnt: \(error.localizedDescription)")
                }
                loginOn = LoginItem.isOn
                loginApproval = LoginItem.needsApproval
            }))
            if loginApproval {
                HStack {
                    Text(L("macOS asks you to allow this in System Settings › General › Login Items.",
                           "macOS möchte, dass du das in Systemeinstellungen › Allgemein › Anmeldeobjekte erlaubst."))
                        .font(.callout).foregroundStyle(.orange)
                    Button(L("Open System Settings", "Systemeinstellungen öffnen")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let loginProblem { Text(loginProblem).font(.callout).foregroundStyle(.orange) }
        }
        .onAppear {
            loginOn = LoginItem.isOn
            loginApproval = LoginItem.needsApproval
        }
    }
}
