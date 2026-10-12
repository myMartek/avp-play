import SwiftUI
import UniformTypeIdentifiers
import WindowsVRCore

struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Bindable var model: LauncherModel
    @State private var importingManifest = false
    @State private var importingGameFolder = false
    @State private var exportingReport = false
    @State private var reportDocument = CompatibilityReportDocument(data: Data())

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Saved game", "Gespeichertes Spiel"), selection: Binding(
                        get: { model.selectedLibraryEntryID ?? "" },
                        set: { identifier in
                            guard !identifier.isEmpty else { return }
                            do { try model.selectLibraryEntry(id: identifier) }
                            catch { model.presentLibraryError(error) }
                        }
                    )) {
                        Text(L("Not selected", "Nicht ausgewählt")).tag("")
                        ForEach(model.library) { entry in
                            Text(entry.manifest.title).tag(entry.id)
                        }
                    }
                    .disabled(!model.canChangeSelection || model.library.isEmpty)

                    if let error = model.libraryError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    if model.manifest != nil && model.gameDirectory != nil {
                        Button(L("Save game to library", "Spiel in Bibliothek speichern"), systemImage: "square.and.arrow.down") {
                            do { try model.saveCurrentGameToLibrary() }
                            catch { model.presentLibraryError(error) }
                        }
                        .disabled(!model.canChangeSelection)
                    }
                    if let selectedID = model.selectedLibraryEntryID {
                        Button(L("Remove saved game", "Gespeichertes Spiel entfernen"), systemImage: "trash", role: .destructive) {
                            do { try model.removeLibraryEntry(id: selectedID) }
                            catch { model.presentLibraryError(error) }
                        }
                        .disabled(!model.canChangeSelection)
                    }
                } header: {
                        Text(L("Game library", "Spielebibliothek"))
                    } footer: {
                    Text(L("Saved folders use local security-scoped bookmarks. Access is reopened only when you select a game and is released when its session ends or selection changes.", "Gespeicherte Ordner verwenden lokale Lesezeichen mit Sicherheitsbereich. Der Zugriff wird erst bei der Spielauswahl wiederhergestellt und nach Sitzungsende oder Auswahlwechsel freigegeben."))
                }

                Section {
                    Button(L("Refresh transferred games", "Übertragene Spiele aktualisieren"), systemImage: "arrow.clockwise") { model.refreshTransferredGames() }
                        .disabled(!model.canChangeSelection)
                    ForEach(model.transferredGames) { game in
                        Button(game.manifest.title) {
                            do { try model.selectTransferredGame(id: game.id) }
                            catch { model.presentLibraryError(error) }
                        }.disabled(!model.canChangeSelection)
                    }
                    if let error = model.transferImportError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                        Text(L("Mac transfers", "Mac-Übertragungen"))
                    } footer: {
                    Text(L("The Mac companion copies owned local files into this app. Only folders with a final manifest marker appear; copying is not game compatibility verification.", "Die Mac-Begleit-App kopiert lokal vorhandene Dateien in diese App. Angezeigt werden nur Ordner mit einer abschließenden Manifestmarkierung; das Kopieren prüft nicht die Spielkompatibilität."))
                }

                Section(L("Import", "Importieren")) {
                    LabeledContent(L("Manifest", "Manifest")) {
                        Text(model.manifestName ?? L("Choose a Windows VR manifest", "Windows-VR-Manifest auswählen"))
                            .foregroundStyle(model.manifest == nil ? .secondary : .primary)
                    }
                    Button(L("Choose manifest…", "Manifest auswählen …"), systemImage: "doc.badge.gearshape") {
                        importingManifest = true
                    }
                    .disabled(!model.canChangeSelection)

                    LabeledContent(L("Game folder", "Spielordner")) {
                        Text(model.gameFolderName ?? L("Choose the folder containing the game", "Ordner mit dem Spiel auswählen"))
                            .foregroundStyle(model.gameDirectory == nil ? .secondary : .primary)
                    }
                    Button(L("Choose game folder…", "Spielordner auswählen …"), systemImage: "folder") {
                        importingGameFolder = true
                    }
                    .disabled(!model.canChangeSelection)
                }

                if let manifest = model.manifest {
                    Section {
                        if let entry = model.selectedEntry, !entry.profiles.isEmpty {
                            Picker(L("Profile", "Profil"), selection: Binding(
                                get: { model.selectedProfileID ?? "" },
                                set: { identifier in
                                    guard !identifier.isEmpty else { return }
                                    do { try model.selectProfile(id: identifier) }
                                    catch { model.presentLibraryError(error) }
                                }
                            )) {
                                ForEach(entry.profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .disabled(!model.canChangeSelection)
                        } else {
                            Text(L("Save this game to the library to create persistent profiles.", "Speichere dieses Spiel in der Bibliothek, um dauerhafte Profile anzulegen."))
                                .foregroundStyle(.secondary)
                        }

                        TextField(L("Profile name", "Profilname"), text: $model.profileNameDraft)
                            .disabled(!model.canChangeSelection)
                        TextField(L("Launch arguments — JSON array of strings", "Startargumente — JSON-Array aus Zeichenfolgen"), text: $model.launchArgumentsText, axis: .vertical)
                            .lineLimit(2...6)
                            .disabled(!model.canChangeSelection)
                        Slider(value: $model.renderScaleDraft, in: 0.5...1, step: 0.05) {
                            Text(L("Spatial render scale", "Räumliche Render-Skalierung"))
                        }.disabled(!model.canChangeSelection)
                        LabeledContent(L("Spatial render scale", "Räumliche Render-Skalierung"), value: String(format: "%.0f%%", model.renderScaleDraft * 100))
                        Text(L("Below 100%, the guest renders smaller eyes and an ordinary Metal bilinear pass scales each eye. This is not temporal SR or DLSS.", "Unter 100 % rendert das Gastsystem kleinere Augenbilder, die anschließend mit einem gewöhnlichen bilinearen Metal-Durchlauf skaliert werden. Das ist weder temporales Super-Resolution noch DLSS."))
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button(L("Save profile", "Profil speichern")) {
                                do { try model.saveProfile() }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection || model.selectedEntry == nil)
                            Button(L("Save as new", "Als neues Profil speichern")) {
                                do { try model.saveProfile(asNew: true) }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection || model.selectedEntry == nil)
                        }
                        if model.selectedProfileID != nil {
                            Button(L("Remove selected profile", "Ausgewähltes Profil entfernen"), systemImage: "trash", role: .destructive) {
                                do { try model.removeSelectedProfile() }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection)
                        }
                    } header: {
                        Text(L("Per-game profiles", "Spielprofile"))
                    } footer: {
                        Text(L("Use a JSON array of strings. Arguments are passed as exact separate argv entries. Backend and graphics choices remain manifest-defined; unsupported graphics are blocked rather than silently substituted.", "Verwende ein JSON-Array aus Zeichenfolgen. Argumente werden exakt als einzelne argv-Einträge übergeben. Backend und Grafikoption bleiben im Manifest festgelegt; nicht unterstützte Grafikmodi werden blockiert und nicht stillschweigend ersetzt."))
                    }

                    Section(L("Selected game", "Ausgewähltes Spiel")) {
                        LabeledContent(L("Title", "Titel"), value: manifest.title)
                        LabeledContent(L("Graphics", "Grafik"), value: displayName(manifest.graphics.rawValue))
                        LabeledContent(L("Backend", "Backend"), value: displayName(manifest.backend.rawValue))
                        LabeledContent(L("Launch state", "Startstatus"), value: model.sessionStatus)
                        if let reason = model.launchUnavailableReason {
                            Text(reason).font(.callout).foregroundStyle(.orange)
                        }
                    }

                    Section {
                        Button {
                            Task { await startLaunch() }
                        } label: {
                            if model.isLaunching {
                                ProgressView(L("Preparing immersive renderer and runtime…", "Immersiven Renderer und Laufzeit werden vorbereitet …"))
                            } else {
                                Label(L("Launch game", "Spiel starten"), systemImage: "play.fill")
                            }
                        }
                        .disabled(!model.canLaunch)

                        if model.hasAcceptedLaunch {
                            Button(role: .destructive) {
                                Task { await model.stop() }
                            } label: {
                                if model.isStopping {
                                    ProgressView(L("Stopping session…", "Sitzung wird beendet …"))
                                } else {
                                    Label(model.stopRequested ? L("Exit requested", "Beenden angefordert") : L("Stop session", "Sitzung beenden"), systemImage: "stop.fill")
                                }
                            }
                            .disabled(!model.hasAcceptedLaunch || model.isStopping || model.stopRequested)
                        }
                        if let launchError = model.launchError {
                            Text(launchError)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("launch-error")
                        }
                        if model.requiresRestart {
                            Text(L("The native runtime has one session slot. Restart the app before selecting or launching another game.", "Die native Laufzeit unterstützt nur eine Sitzung. Starte die App neu, bevor du ein anderes Spiel auswählst oder startest."))
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text(L("Runtime session", "Laufzeitsitzung"))
                    } footer: {
                        Text(L("Plugin acceptance and Wine process activity do not report game readiness or rendered output.", "Die Annahme durch das Plugin und die Aktivität des Wine-Prozesses geben weder Auskunft über die Spielbereitschaft noch über gerenderte Bilder."))
                    }
                }

                Section(L("Wine process status", "Wine-Prozessstatus")) {
                    LabeledContent(L("Wine/runtime", "Wine/Laufzeit"), value: model.sessionStatus)
                    Text(L("Wine status is not compositor output or proof that the game is ready.", "Der Wine-Status zeigt weder die Compositor-Ausgabe noch die Spielbereitschaft an."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(L("Compositor queue counters", "Compositor-Warteschlangenzähler")) {
                    LabeledContent(L("Submitted", "Eingereiht"), value: counter(model.compositorCounters?.submittedFrames))
                    LabeledContent(L("Acquired", "Übernommen"), value: counter(model.compositorCounters?.acquiredFrames))
                    LabeledContent(L("Dropped", "Verworfen"), value: counter(model.compositorCounters?.droppedFrames))
                    LabeledContent(L("Completed", "Abgeschlossen"), value: counter(model.compositorCounters?.completedFrames))
                    LabeledContent(L("Queued now", "Aktuell eingereiht"), value: counter(model.compositorCounters?.queuedFrames))
                    Text(L("Native compositor ABI v1 advisory queue counters only. They are separate from Wine status and do not prove game rendering, display presentation, or readiness.", "Die Zähler der nativen Compositor-ABI v1 sind nur Richtwerte. Sie sind unabhängig vom Wine-Status und belegen weder Spielrendering noch Bildausgabe oder Spielbereitschaft."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(L("Compatibility report", "Kompatibilitätsbericht")) {
                    Button(L("Export versioned JSON report", "Versionierten JSON-Bericht exportieren"), systemImage: "square.and.arrow.up") {
                        do {
                            reportDocument = CompatibilityReportDocument(data: try model.makeCompatibilityReportJSON())
                            exportingReport = true
                        } catch {
                            model.presentLibraryError(error)
                        }
                    }
                    .disabled(model.manifest == nil)
                    Text(L("Includes the device and OS version, requested profile, conservative capability reasons, separate Wine and compositor status, and explicit unknown/unmeasured metrics. Environment values are not exported.", "Der Bericht enthält Geräte- und Betriebssystemversion, das angeforderte Profil, vorsichtige Begründungen zu Funktionen, getrennte Wine- und Compositor-Status sowie ausdrücklich unbekannte oder nicht gemessene Werte. Umgebungsvariablen werden nicht exportiert."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L("Windows VR Research", "Windows-VR-Forschung"))
            .task { model.refreshTransferredGames() }
            .fileImporter(
                isPresented: $importingManifest,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false,
                onCompletion: model.importManifest
            )
            .fileImporter(
                isPresented: $importingGameFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: model.importGameFolder
            )
            .fileExporter(
                isPresented: $exportingReport,
                document: reportDocument,
                contentType: .json,
                defaultFilename: model.reportFilename
            ) { result in
                if case .failure(let error) = result { model.presentLibraryError(error) }
            }
            .alert(L("Couldn’t open selection", "Auswahl konnte nicht geöffnet werden"), isPresented: $model.isShowingImportError) {
                Button(L("OK", "OK"), role: .cancel) { model.dismissImportError() }
            } message: {
                Text(model.importError ?? L("The selected item could not be opened.", "Das ausgewählte Element konnte nicht geöffnet werden."))
            }
            .onChange(of: model.hasAcceptedLaunch) { _, accepted in
                if !accepted && model.requiresRestart {
                    Task { await dismissImmersiveSpace() }
                }
            }
        }
    }

    private func displayName(_ value: String) -> String {
        switch value {
        case "direct3D11": L("Direct3D 11", "Direct3D 11")
        case "direct3D12": L("Direct3D 12 (experimental DXMT)", "Direct3D 12 (DXMT, experimentell)")
        case "vulkan": L("Vulkan (unavailable; launch blocked)", "Vulkan (nicht verfügbar; Start blockiert)")
        case "windowsWineFEX": L("Windows through Wine/FEX", "Windows über Wine/FEX")
        case "nativeARM64": L("Native ARM64 PE (not packaged)", "Natives ARM64-PE (nicht enthalten)")
        default: value
        }
    }

    private func counter<T: BinaryInteger>(_ value: T?) -> String {
        guard let value else { return L("Unavailable", "Nicht verfügbar") }
        return String(value)
    }

    @MainActor
    private func startLaunch() async {
        await model.launch {
            guard case .opened = await openImmersiveSpace(id: WindowsVRCompositorScene.identifier) else {
                throw LaunchPreparationFailure.immersiveSpaceUnavailable
            }
            model.immersiveSpaceDidOpen()
            try await model.waitForCompositorReady()
        }
        if !model.hasAcceptedLaunch { await dismissImmersiveSpace() }
    }
}

private struct CompatibilityReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum LaunchPreparationFailure: LocalizedError {
    case immersiveSpaceUnavailable
    var errorDescription: String? {
        L("The immersive compositor window could not be opened, so no launch request was sent.", "Das immersive Compositor-Fenster konnte nicht geöffnet werden. Es wurde keine Startanfrage gesendet.")
    }
}
