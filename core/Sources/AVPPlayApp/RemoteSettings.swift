import AVPPlayCore
import SwiftUI

/// Die Seite „Fernbedienung“ in der Seitenleiste.
struct RemoteControlView: View {
    var body: some View {
        Form {
            RemoteControlSection()
            CompanionSection()
        }
            .formStyle(.grouped)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .navigationTitle(L("Remote Control", "Fernbedienung"))
    }
}

/// Fernbedienung: einschalten, der Code zum Koppeln, die gekoppelten Vision Pros.
struct RemoteControlSection: View {
    @EnvironmentObject var remote: RemoteServer
    @State private var addresses: [String] = []

    var body: some View {
        Section(L("Remote control from Apple Vision Pro", "Fernbedienung von der Apple Vision Pro")) {
            Toggle(L("Let AVP Play Remote on the Vision Pro control this Mac", "AVP Play Remote auf der Vision Pro diesen Mac steuern lassen"),
                   isOn: Binding(get: { remote.enabled }, set: { remote.setEnabled($0) }))
            Text(L("With the app “AVP Play Remote” on the Vision Pro you can see your games and jobs and install, update or download games while you wear the headset – this Mac does the work as usual. The Mac shows itself in the local network; a Vision Pro has to be paired once with the code below and finds the Mac by itself after that. Everything between the two is encrypted with the key from the pairing. While a remote is connected, macOS does not put AVP Play to sleep; the Mac itself may still go to sleep.",
                   "Mit der App „AVP Play Remote“ auf der Vision Pro siehst du deine Spiele und Aufträge und kannst Spiele installieren, aktualisieren oder laden, während du das Headset trägst – die Arbeit macht wie immer dieser Mac. Der Mac zeigt sich dazu im lokalen Netz; eine Vision Pro wird einmal mit dem Code unten gekoppelt und findet den Mac danach von selbst. Alles zwischen beiden ist mit dem Schlüssel aus der Kopplung verschlüsselt. Solange eine Fernbedienung verbunden ist, schickt macOS AVP Play nicht in den Ruhezustand; der Mac selbst darf weiterhin schlafen."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if remote.enabled {
                if let problem = remote.problem {
                    Text(problem).font(.callout).foregroundStyle(.orange)
                }
                LabeledContent(L("Pairing code", "Code zum Koppeln")) {
                    HStack(spacing: 12) {
                        if let until = remote.pairingPausedUntil, until > Date() {
                            Text(L("Paused after several wrong codes – try again in a minute.", "Nach mehreren falschen Codes pausiert – in einer Minute wieder."))
                                .foregroundStyle(.orange)
                        } else {
                            Text(spaced(remote.code)).font(.system(.title2, design: .monospaced).bold()).textSelection(.enabled)
                        }
                        Button(L("New Code", "Neuer Code")) { remote.newCode() }
                    }
                }
                LabeledContent(L("Address for manual entry", "Adresse zum Eintippen")) {
                    Text(addresses.isEmpty ? L("No network", "Kein Netz") : addresses.joined(separator: ", "))
                        .textSelection(.enabled).foregroundStyle(.secondary)
                }
                if remote.peers.isEmpty {
                    Text(L("No Vision Pro paired yet. Open AVP Play Remote on the headset: it finds this Mac and asks for the code.",
                           "Noch keine Vision Pro gekoppelt. Öffne AVP Play Remote auf dem Headset: Es findet diesen Mac und fragt nach dem Code."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(remote.peers) { peer in
                        HStack {
                            Image(systemName: "visionpro").foregroundStyle(remote.connected.contains(peer.clientId) ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name)
                                Text(detail(peer)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Remove", "Entfernen"), role: .destructive) { remote.remove(peer) }
                        }
                    }
                }
            }
        }
        .task(id: remote.enabled) { addresses = RemoteServer.addresses() }
    }

    /// Verbunden oder wann zuletzt, und seit wann gekoppelt – zwei Brillen heißen oft gleich.
    private func detail(_ peer: RemotePeer) -> String {
        let relative = Date.RelativeFormatStyle(presentation: .named, locale: L10n.locale)
        let paired = peer.paired.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale))
        let state = remote.connected.contains(peer.clientId) ? L("Connected", "Verbunden")
            : peer.lastSeen.map { L("Last connected \($0.formatted(relative))", "Zuletzt verbunden \($0.formatted(relative))") }
            ?? L("Not connected yet", "Noch nicht verbunden")
        return state + " · " + L("paired \(paired)", "gekoppelt \(paired)")
    }

    /// „123456“ als „123 456“ – leichter abzulesen.
    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}
