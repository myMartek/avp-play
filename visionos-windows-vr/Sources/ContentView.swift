import SwiftUI
import UniformTypeIdentifiers
import WindowsVRCore

struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Bindable var model: LauncherModel
    @State private var importingManifest = false
    @State private var importingGameFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Game setup") {
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
                    Section("Selected game") {
                        LabeledContent("Title", value: manifest.title)
                        LabeledContent("Graphics", value: displayName(String(describing: manifest.graphics)))
                        LabeledContent("Backend", value: displayName(String(describing: manifest.backend)))
                        LabeledContent("Launch state", value: model.sessionStatus)
                    }

                    Section("Graphics options") {
                        LabeledContent("DLSS to MetalFX SR") {
                            Text("Unavailable")
                                .foregroundStyle(.secondary)
                        }
                        Text("Frame generation and foveated rendering are planned and are not available in this shell.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Section {
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
                                Task {
                                    await model.stop()
                                }
                            } label: {
                                if model.isStopping {
                                    ProgressView("Stopping session…")
                                } else {
                                    Label("Stop session", systemImage: "stop.fill")
                                }
                            }
                            .disabled(!model.hasAcceptedLaunch || model.isStopping)
                        }

                        if let launchError = model.launchError {
                            Text(launchError)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("launch-error")
                        }
                        if model.requiresRestart {
                            Text("The runtime may still own the guest session. Restart the app before selecting another game.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    } footer: {
                        Text("The runtime bridge reports when a plugin accepts a launch request. It cannot report whether the game became ready or is rendering.")
                    }
                }
            }
            .navigationTitle("Windows VR Research")
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
        case "vulkan": "Vulkan"
        case "windowsWineFEX": "Windows through Wine/FEX (integration unavailable)"
        case "nativeARM64": "Native ARM64 (integration unavailable)"
        default: value
        }
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
        if !model.hasAcceptedLaunch {
            await dismissImmersiveSpace()
        }
    }
}

private enum LaunchPreparationFailure: LocalizedError {
    case immersiveSpaceUnavailable

    var errorDescription: String? {
        "The immersive compositor window could not be opened, so no launch request was sent."
    }
}
