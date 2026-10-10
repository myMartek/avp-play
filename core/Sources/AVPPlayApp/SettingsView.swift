import AVPPlayCore
import SwiftUI

/// Welche Sprache das Programm spricht: die des Systems oder eine fest gewählte.
enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, en, de
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Same as macOS", "Wie macOS")
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }
}

/// Die Einstellungen des Programms (⌘,): Sprache und, für Leute die es brauchen, die Kennung der Apps.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var prefixDraft = ""

    var body: some View {
        Form {
            Section {
                Picker(L("Language", "Sprache"), selection: Binding(get: { model.languageChoice }, set: { model.languageChoice = $0 })) {
                    ForEach(LanguageChoice.allCases) { Text($0.title).tag($0) }
                }
                Text(L("Menus that macOS provides itself switch the next time you open the app.",
                       "Menüs, die macOS selbst stellt, wechseln beim nächsten Öffnen des Programms."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section(L("Online catalogue", "Online-Katalog")) {
                Toggle(L("Show more games from the online catalogue and allow feedback", "Weitere Spiele aus dem Online-Katalog zeigen und Rückmeldungen erlauben"),
                       isOn: Binding(get: { model.onlineCatalog }, set: { model.onlineCatalog = $0; model.loadCatalog() }))
                Text(L("The catalogue is a small service of this project (avpplay.martek.de). The app sends it what you search for and the identifiers of games you open; a report you choose to send contains the game, its build and your answer. It never receives your Meta sign-in or anything about your account or device.",
                       "Der Katalog ist ein kleiner Dienst dieses Projekts (avpplay.martek.de). Die App schickt ihm, wonach du suchst, und die Kennungen der Spiele, die du öffnest; eine Rückmeldung, die du abschickst, enthält das Spiel, seinen Build und deine Antwort. Deine Meta-Anmeldung oder etwas über dein Konto oder Gerät bekommt er nie."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("Pictures", "Bilder")) {
                Toggle(L("Load pictures of games from the Meta Store", "Bilder der Spiele aus dem Meta-Store laden"), isOn: $model.storePictures)
                Text(L("For games whose files are not on this Mac yet, the app fetches the picture from the game's public page in the Meta Store (meta.com) – only for games you are looking at, without your Meta sign-in, and keeps a small copy in a cache that the Data page can empty. Without this, such games show a coloured tile with their name.",
                       "Für Spiele, deren Dateien noch nicht auf diesem Mac liegen, holt die App das Bild von der öffentlichen Seite des Spiels im Meta-Store (meta.com) – nur für Spiele, die du gerade siehst, ohne deine Meta-Anmeldung, und hält eine kleine Kopie in einem Zwischenspeicher, den die Datenverwaltung leeren kann. Ohne das zeigen solche Spiele eine farbige Fläche mit ihrem Namen."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("Downloads", "Downloads")) {
                StoreLocationBox()
                Text(L("Downloaded games are kept here – easily tens of gigabytes each. You can choose a folder on another disk, for example an external one; the games already downloaded move there. While that disk is not connected, nothing is downloaded or installed. Under “Data” in the main window you see what is stored and can remove it.",
                       "Hier liegen die heruntergeladenen Spiele – schnell zweistellige Gigabyte pro Spiel. Du kannst einen Ordner auf einer anderen Platte wählen, etwa einer externen; die schon geladenen Spiele ziehen dorthin um. Solange diese Platte nicht angeschlossen ist, wird nichts geladen oder installiert. Unter „Datenverwaltung“ im Hauptfenster siehst du, was gespeichert ist, und kannst es entfernen."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("Updates", "Aktualisierung")) {
                Toggle(L("Check for new versions once a day", "Einmal am Tag nach neuen Fassungen sehen"),
                       isOn: Binding(get: { model.autoUpdateCheck }, set: { model.autoUpdateCheck = $0 }))
                HStack {
                    Text(L("This is version \(model.appVersion).", "Dies ist Version \(model.appVersion)."))
                    Spacer()
                    switch model.updateState {
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Text(L("Up to date", "Aktuell")).foregroundStyle(.secondary)
                    case .failed(let why): Text(why).foregroundStyle(.orange).lineLimit(2).help(why)
                    default:
                        if let release = model.update {
                            Text(L("Version \(release.version) is available", "Version \(release.version) ist da")).foregroundStyle(.secondary)
                        }
                    }
                    Button(L("Check Now", "Jetzt nachsehen")) { Task { await model.checkForUpdate(manual: true) } }
                        .disabled([.checking, .downloading, .installing].contains(model.updateState))
                }
                if let release = model.update {
                    HStack {
                        switch model.updateState {
                        case .downloading:
                            ProgressView().controlSize(.small)
                            Text(L("Downloading version \(release.version) …", "Version \(release.version) wird geladen …"))
                        case .installing:
                            ProgressView().controlSize(.small)
                            Text(L("Checking and installing …", "Wird geprüft und eingespielt …"))
                        default:
                            Button(model.canSelfUpdate ? L("Install Version \(release.version) and Relaunch", "Version \(release.version) einspielen und neu starten")
                                                       : L("Open Download Page", "Download-Seite öffnen")) {
                                Task { await model.installUpdate() }
                            }
                            .buttonStyle(.borderedProminent)
                            Link(L("What’s new", "Was ist neu"), destination: release.page)
                        }
                        Spacer()
                    }
                }
                Text(L("The check asks GitHub for the latest release of AVP Play and sends nothing else. A new version is only installed if it is signed by the same developer and notarised by Apple.",
                       "Dabei wird GitHub nach der neuesten Veröffentlichung von AVP Play gefragt, sonst wird nichts gesendet. Eine neue Fassung wird nur eingespielt, wenn sie vom selben Entwickler signiert und von Apple beglaubigt ist."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("Advanced", "Erweitert")) {
                LabeledContent(L("App identifier prefix", "Präfix der App-Kennung")) {
                    TextField("", text: $prefixDraft, prompt: Text(Toolchain.defaultBundlePrefix()))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                        .onSubmit(applyPrefix)
                }
                Text(L("Every game is installed under this prefix plus its own name, for example \(model.bundlePrefix).doom3quest. Leave it empty for the default, which starts with your macOS user name.",
                       "Jedes Spiel wird unter diesem Präfix und seinem eigenen Namen installiert, zum Beispiel \(model.bundlePrefix).doom3quest. Leer lassen für den Standard, der mit deinem macOS-Benutzernamen beginnt."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("If you change it, the Vision Pro treats every game as a new app: the one installed before stays next to it, and game data is copied again.",
                       "Wenn du es änderst, sieht die Vision Pro jedes Spiel als neue App: die bisher installierte bleibt daneben stehen, und die Spieldaten werden neu kopiert."))
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Apply", "Übernehmen"), action: applyPrefix)
                        .disabled(!prefixDraft.isEmpty && !Toolchain.isValidBundlePrefix(prefixDraft))
                    Button(L("Use Default", "Standard verwenden")) {
                        prefixDraft = ""
                        applyPrefix()
                    }
                    .disabled(model.customBundlePrefix.isEmpty)
                    if !prefixDraft.isEmpty, !Toolchain.isValidBundlePrefix(prefixDraft) {
                        Text(L("Letters, digits, hyphens and dots only, like com.example.games.",
                               "Nur Buchstaben, Ziffern, Bindestriche und Punkte, etwa com.example.games."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { prefixDraft = model.customBundlePrefix }
    }

    private func applyPrefix() {
        guard prefixDraft.isEmpty || Toolchain.isValidBundlePrefix(prefixDraft) else { return }
        model.customBundlePrefix = prefixDraft
        model.refresh()
    }
}
