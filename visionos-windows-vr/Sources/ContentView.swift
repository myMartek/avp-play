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
                Section("Game library") {
                    Picker("Saved game", selection: Binding(
                        get: { model.selectedLibraryEntryID ?? "" },
                        set: { identifier in
                            guard !identifier.isEmpty else { return }
                            do { try model.selectLibraryEntry(id: identifier) }
                            catch { model.presentLibraryError(error) }
                        }
                    )) {
                        Text("Not selected").tag("")
                        ForEach(model.library) { entry in
                            Text(entry.manifest.title).tag(entry.id)
                        }
                    }
                    .disabled(!model.canChangeSelection || model.library.isEmpty)

                    if let error = model.libraryError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    if model.manifest != nil && model.gameDirectory != nil {
                        Button("Save game to library", systemImage: "square.and.arrow.down") {
                            do { try model.saveCurrentGameToLibrary() }
                            catch { model.presentLibraryError(error) }
                        }
                        .disabled(!model.canChangeSelection)
                    }
                    if let selectedID = model.selectedLibraryEntryID {
                        Button("Remove saved game", systemImage: "trash", role: .destructive) {
                            do { try model.removeLibraryEntry(id: selectedID) }
                            catch { model.presentLibraryError(error) }
                        }
                        .disabled(!model.canChangeSelection)
                    }
                } footer: {
                    Text("Saved folders use local security-scoped bookmarks. Access is reopened only when you select a game and is released when its session ends or selection changes.")
                }

                Section("Mac transfers") {
                    Button("Refresh transferred games", systemImage: "arrow.clockwise") { model.refreshTransferredGames() }
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
                } footer: {
                    Text("The Mac companion copies owned local files into this app. Only folders with a final manifest marker appear; copying is not game compatibility verification.")
                }

                Section("Import") {
                    LabeledContent("Manifest") {
                        Text(model.manifestName ?? "Choose a Windows VR manifest")
                            .foregroundStyle(model.manifest == nil ? .secondary : .primary)
                    }
                    Button("Choose manifest…", systemImage: "doc.badge.gearshape") {
                        importingManifest = true
                    }
                    .disabled(!model.canChangeSelection)

                    LabeledContent("Game folder") {
                        Text(model.gameFolderName ?? "Choose the folder containing the game")
                            .foregroundStyle(model.gameDirectory == nil ? .secondary : .primary)
                    }
                    Button("Choose game folder…", systemImage: "folder") {
                        importingGameFolder = true
                    }
                    .disabled(!model.canChangeSelection)
                }

                if let manifest = model.manifest {
                    Section("Per-game profiles") {
                        if let entry = model.selectedEntry, !entry.profiles.isEmpty {
                            Picker("Profile", selection: Binding(
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
                            Text("Save this game to the library to create persistent profiles.")
                                .foregroundStyle(.secondary)
                        }

                        TextField("Profile name", text: $model.profileNameDraft)
                            .disabled(!model.canChangeSelection)
                        TextField("Launch arguments — JSON array of strings", text: $model.launchArgumentsText, axis: .vertical)
                            .lineLimit(2...6)
                            .disabled(!model.canChangeSelection)
                        Slider(value: $model.renderScaleDraft, in: 0.5...1, step: 0.05) {
                            Text("Spatial render scale")
                        }.disabled(!model.canChangeSelection)
                        LabeledContent("Spatial render scale", value: String(format: "%.0f%%", model.renderScaleDraft * 100))
                        Text("Below 100%, the guest renders smaller eyes and an ordinary Metal bilinear pass scales each eye. This is not temporal SR or DLSS.")
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("Save profile") {
                                do { try model.saveProfile() }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection || model.selectedEntry == nil)
                            Button("Save as new") {
                                do { try model.saveProfile(asNew: true) }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection || model.selectedEntry == nil)
                        }
                        if model.selectedProfileID != nil {
                            Button("Remove selected profile", systemImage: "trash", role: .destructive) {
                                do { try model.removeSelectedProfile() }
                                catch { model.presentLibraryError(error) }
                            }
                            .disabled(!model.canChangeSelection)
                        }
                    } footer: {
                        Text("Use a JSON array of strings. Arguments are passed as exact separate argv entries. Backend and graphics choices remain manifest-defined; unsupported graphics are blocked rather than silently substituted.")
                    }

                    Section("Selected game") {
                        LabeledContent("Title", value: manifest.title)
                        LabeledContent("Graphics", value: displayName(manifest.graphics.rawValue))
                        LabeledContent("Backend", value: displayName(manifest.backend.rawValue))
                        LabeledContent("Launch state", value: model.sessionStatus)
                        if let reason = model.launchUnavailableReason {
                            Text(reason).font(.callout).foregroundStyle(.orange)
                        }
                    }

                    Section("Runtime session") {
                        Button {
                            Task { await startLaunch() }
                        } label: {
                            if model.isLaunching {
                                ProgressView("Preparing immersive renderer and runtime…")
                            } else {
                                Label("Launch game", systemImage: "play.fill")
                            }
                        }
                        .disabled(!model.canLaunch)

                        if model.hasAcceptedLaunch {
                            Button(role: .destructive) {
                                Task { await model.stop() }
                            } label: {
                                if model.isStopping {
                                    ProgressView("Stopping session…")
                                } else {
                                    Label(model.stopRequested ? "Exit requested" : "Stop session", systemImage: "stop.fill")
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
                            Text("The native runtime has one session slot. Restart the app before selecting or launching another game.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("Plugin acceptance and Wine process activity do not report game readiness or rendered output.")
                    }
                }

                Section("Wine process status") {
                    LabeledContent("Wine/runtime", value: model.sessionStatus)
                    Text("Wine status is not compositor output or proof that the game is ready.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Compositor queue counters") {
                    LabeledContent("Submitted", value: counter(model.compositorCounters?.submittedFrames))
                    LabeledContent("Acquired", value: counter(model.compositorCounters?.acquiredFrames))
                    LabeledContent("Dropped", value: counter(model.compositorCounters?.droppedFrames))
                    LabeledContent("Completed", value: counter(model.compositorCounters?.completedFrames))
                    LabeledContent("Queued now", value: counter(model.compositorCounters?.queuedFrames))
                    Text("Native compositor ABI v1 advisory queue counters only. They are separate from Wine status and do not prove game rendering, display presentation, or readiness.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Compatibility report") {
                    Button("Export versioned JSON report", systemImage: "square.and.arrow.up") {
                        do {
                            reportDocument = CompatibilityReportDocument(data: try model.makeCompatibilityReportJSON())
                            exportingReport = true
                        } catch {
                            model.presentLibraryError(error)
                        }
                    }
                    .disabled(model.manifest == nil)
                    Text("Includes the device and OS version, requested profile, conservative capability reasons, separate Wine and compositor status, and explicit unknown/unmeasured metrics. Environment values are not exported.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Windows VR Research")
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
            .alert("Couldn’t open selection", isPresented: $model.isShowingImportError) {
                Button("OK", role: .cancel) { model.dismissImportError() }
            } message: {
                Text(model.importError ?? "The selected item could not be opened.")
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
        case "direct3D11": "Direct3D 11"
        case "direct3D12": "Direct3D 12 (experimental DXMT)"
        case "vulkan": "Vulkan (unavailable; launch blocked)"
        case "windowsWineFEX": "Windows through Wine/FEX"
        case "nativeARM64": "Native ARM64 PE (not packaged)"
        default: value
        }
    }

    private func counter<T: BinaryInteger>(_ value: T?) -> String {
        guard let value else { return "Unavailable" }
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
        "The immersive compositor window could not be opened, so no launch request was sent."
    }
}
