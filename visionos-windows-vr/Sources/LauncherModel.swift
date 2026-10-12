import Foundation
import Observation
import QuartzCore
import UIKit
import Darwin
import WindowsVRCore

struct TransferredWindowsVRGame: Identifiable {
    let id: String
    let manifest: WindowsGameManifest
    let directory: URL
}

@MainActor
@Observable
final class LauncherModel {
    private(set) var manifest: WindowsGameManifest?
    private(set) var manifestName: String?
    private(set) var gameDirectory: URL?
    private(set) var gameFolderName: String?
    private(set) var isLaunching = false
    private(set) var hasAcceptedLaunch = false
    private(set) var isStopping = false
    private(set) var stopRequested = false
    private(set) var requiresRestart = false
    private(set) var runtimeStatus = L("No runtime session", "Keine Laufzeitsitzung")
    private(set) var launchError: String?
    private(set) var library: [WindowsVRLibraryEntry] = []
    private(set) var selectedLibraryEntryID: String?
    private(set) var selectedProfileID: String?
    private(set) var compositorCounters: WindowsVRCompositorCounters?
    private(set) var libraryError: String?
    private(set) var transferredGames: [TransferredWindowsVRGame] = []
    private(set) var transferImportError: String?
    var renderScaleDraft: Float = 1
    var profileNameDraft = L("Default", "Standard")
    var launchArgumentsText = "[]"
    var isShowingImportError = false
    private(set) var importError: String?

    @ObservationIgnored private let runtime = NativePluginWindowsRuntime()
    @ObservationIgnored private let jitCoordinator = JITCoordinator()
    private var gameDirectoryAccessURL: URL?
    private var immersiveSpaceIsOpen = false
    private var immersiveSpaceClosedDuringLaunch = false
    private var statusMonitor: Task<Void, Never>?

    init() {
        do {
            library = try WindowsVRLibraryStore.load()
        } catch {
            libraryError = error.localizedDescription
        }
    }

    var canLaunch: Bool {
        guard manifest != nil, gameDirectory != nil,
              !isLaunching, !hasAcceptedLaunch, !isStopping, !requiresRestart,
              runtime.isAvailable,
              manifest.map({ runtime.supportsGraphics($0.graphics) }) == true,
              manifest?.backend == .windowsWineFEX
        else { return false }
        let arguments = draftArguments
        return arguments.count <= 64 && arguments.allSatisfy { !$0.contains("\0") }
    }

    var launchUnavailableReason: String? {
        guard let manifest else { return L("Import a Windows VR manifest and select a game folder.", "Importiere ein Windows-VR-Manifest und wähle einen Spielordner aus.") }
        guard gameDirectory != nil else { return L("Select the folder containing the game before launching.", "Wähle vor dem Start den Ordner mit dem Spiel aus.") }
        if manifest.backend != .windowsWineFEX {
            return L("This app packages the x64 Wine/FEX runtime only. A native ARM64/ARM64EC Windows VR package is not embedded.", "Diese App enthält nur die x64-Wine/FEX-Laufzeit. Ein natives ARM64/ARM64EC-Windows-VR-Paket ist nicht eingebettet.")
        }
        if manifest.graphics == .vulkan {
            return L("Vulkan is not implemented by this runtime adapter. The request is blocked; no graphics fallback will be selected.", "Vulkan wird von diesem Laufzeitadapter nicht unterstützt. Die Anfrage wird blockiert; es wird kein Grafikmodus als Ersatz gewählt.")
        }
        if !runtime.isAvailable {
            return L("The signed WindowsRuntimePlugin.framework is unavailable. Launch is blocked; no placeholder backend will run.", "Das signierte WindowsRuntimePlugin.framework ist nicht verfügbar. Der Start wird blockiert; es wird kein Platzhalter-Backend ausgeführt.")
        }
        if !runtime.supportsGraphics(manifest.graphics) {
            return L("The app does not contain the matching experimental DXMT D3D12 runtime package. D3D11 is not substituted for a D3D12 request.", "Das passende experimentelle DXMT-D3D12-Laufzeitpaket ist nicht in der App enthalten. Eine D3D12-Anfrage wird nicht durch D3D11 ersetzt.")
        }
        if requiresRestart {
            return L("This process has consumed its single runtime session. Restart the app before another launch.", "Dieser Prozess hat seine einzige Laufzeitsitzung verwendet. Starte die App neu, bevor du ein weiteres Spiel startest.")
        }
        if isLaunching || hasAcceptedLaunch || isStopping {
            return L("A runtime session is active or changing state.", "Eine Laufzeitsitzung ist aktiv oder ändert gerade ihren Zustand.")
        }
        if draftArguments.count > 64 || draftArguments.contains(where: { $0.contains("\0") }) {
            return L("The profile arguments exceed the plugin limit or contain an invalid NUL character.", "Die Profilargumente überschreiten das Plugin-Limit oder enthalten ein ungültiges Nullzeichen.")
        }
        return nil
    }

    var canChangeSelection: Bool {
        !isLaunching && !hasAcceptedLaunch && !isStopping && !requiresRestart
    }

    var selectedEntry: WindowsVRLibraryEntry? {
        guard let selectedLibraryEntryID else { return nil }
        return library.first(where: { $0.id == selectedLibraryEntryID })
    }

    var selectedProfileName: String? {
        selectedEntry?.profiles.first(where: { $0.id == selectedProfileID })?.name
    }

    var sessionStatus: String {
        if isStopping { return L("Stopping", "Wird beendet") }
        if isLaunching { return L("Starting", "Wird gestartet") }
        if hasAcceptedLaunch { return runtimeStatus }
        if requiresRestart { return runtimeStatus }
        return L("Not running", "Nicht gestartet")
    }

    func importManifest(_ result: Result<[URL], Error>) {
        guard canChangeSelection else { return }
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                throw ImportFailure.manifestAccessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 1024 * 1024 else { throw WindowsVRLibraryError.corruptLibrary }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(WindowsGameManifest.self, from: data)
            try decoded.validate()
            manifest = decoded
            manifestName = url.lastPathComponent
            launchArgumentsText = Self.argumentText(decoded.launchArguments)
            selectedLibraryEntryID = nil
            selectedProfileID = nil
            renderScaleDraft = 1
            profileNameDraft = L("Default", "Standard")
            launchError = nil
        } catch {
            guard !isCancellation(error) else { return }
            showImportError(error)
        }
    }

    func importGameFolder(_ result: Result<[URL], Error>) {
        guard canChangeSelection else { return }
        do {
            guard let url = try result.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                throw ImportFailure.folderAccessDenied
            }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { throw ImportFailure.folderAccessDenied }
            } catch {
                url.stopAccessingSecurityScopedResource()
                throw error
            }
            releaseGameDirectoryAccess()
            gameDirectoryAccessURL = url
            gameDirectory = url
            gameFolderName = url.lastPathComponent
            launchError = nil
        } catch {
            guard !isCancellation(error) else { return }
            showImportError(error)
        }
    }

    /// Discovers only app-container files copied by the Mac companion. External
    /// folders still require explicit import/bookmark access, never a broad scan.
    func refreshTransferredGames() {
        guard canChangeSelection else { return }
        transferredGames = []
        transferImportError = nil
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = documents.appendingPathComponent("WindowsVR/Games", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            let fm = FileManager.default
            let gameFolders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var candidates: [URL] = []
            for folder in gameFolders {
                let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true, isAppOwnedURL(folder) else { continue }
                // Accept both the original direct layout and immutable transfer
                // generations; incomplete transfers have no manifest marker.
                candidates.append(folder)
                candidates.append(contentsOf: try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            }
            for folder in candidates {
                let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true, isAppOwnedURL(folder) else { continue }
                let manifestURL = folder.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path), isAppOwnedURL(manifestURL) else { continue }
                let attributes = try fm.attributesOfItem(atPath: manifestURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024 * 1024 else { continue }
                do {
                    let decoded = try JSONDecoder().decode(WindowsGameManifest.self, from: Data(contentsOf: manifestURL))
                    try decoded.validate()
                    let executable = folder.appendingPathComponent(decoded.executableRelativePath.replacingOccurrences(of: String(decoding: [UInt8(92)], as: UTF8.self), with: "/")).resolvingSymlinksInPath()
                    let prefix = folder.resolvingSymlinksInPath().path + "/"
                    guard executable.path.hasPrefix(prefix),
                          try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    transferredGames.append(.init(id: folder.path, manifest: decoded, directory: folder))
                } catch {
                    transferImportError = L("Some transferred manifests could not be imported: \(error.localizedDescription)", "Einige übertragene Manifeste konnten nicht importiert werden: \(error.localizedDescription)")
                }
            }
            transferredGames.sort { $0.manifest.title.localizedCaseInsensitiveCompare($1.manifest.title) == .orderedAscending }
        } catch {
            transferImportError = L("Transferred games could not be listed: \(error.localizedDescription)", "Die übertragenen Spiele konnten nicht aufgelistet werden: \(error.localizedDescription)")
        }
    }

    func selectTransferredGame(id: String) throws {
        guard canChangeSelection else { return }
        guard let game = transferredGames.first(where: { $0.id == id }), isAppOwnedURL(game.directory) else {
            throw WindowsVRLibraryError.noSavedGame
        }
        releaseGameDirectoryAccess()
        gameDirectory = game.directory
        gameFolderName = game.directory.lastPathComponent
        manifest = game.manifest
        manifestName = L("manifest.json — Mac transfer", "manifest.json — Mac-Übertragung")
        selectedLibraryEntryID = nil
        selectedProfileID = nil
        renderScaleDraft = 1
        profileNameDraft = L("Default", "Standard")
        launchArgumentsText = Self.argumentText(game.manifest.launchArguments)
        launchError = nil
    }

    private func isAppOwnedURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let root = documents.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }

    func saveCurrentGameToLibrary() throws {
        guard canChangeSelection, let manifest, let gameDirectory else {
            throw WindowsVRLibraryError.noActiveGame
        }
        let bookmark = try WindowsVRLibraryStore.makeFolderBookmark(for: gameDirectory)
        let defaultProfile = try WindowsVRLaunchProfile(
            name: L("Default", "Standard"),
            backend: manifest.backend,
            graphics: manifest.graphics,
            launchArguments: draftArguments,
            environment: manifest.environment,
            renderScale: renderScaleDraft
        )
        var updated = library
        if let index = updated.firstIndex(where: { $0.manifest.id == manifest.id }) {
            updated[index].manifest = manifest
            updated[index].folderBookmark = bookmark
            if updated[index].profiles.isEmpty {
                updated[index].profiles = [defaultProfile]
                updated[index].selectedProfileID = defaultProfile.id
            }
            updated[index].updatedAt = Date()
            selectedLibraryEntryID = updated[index].id
            selectedProfileID = updated[index].selectedProfileID
        } else {
            let entry = WindowsVRLibraryEntry(
                manifest: manifest,
                folderBookmark: bookmark,
                profiles: [defaultProfile],
                selectedProfileID: defaultProfile.id
            )
            updated.append(entry)
            selectedLibraryEntryID = entry.id
            selectedProfileID = defaultProfile.id
        }
        try persist(updated)
        profileNameDraft = selectedProfileName ?? L("Default", "Standard")
    }

    func selectLibraryEntry(id: String) throws {
        guard canChangeSelection else { return }
        guard let entry = library.first(where: { $0.id == id }) else {
            throw WindowsVRLibraryError.noSavedGame
        }
        let resolved = try WindowsVRLibraryStore.resolveFolderBookmark(entry.folderBookmark)
        let didStartAccess = resolved.url.startAccessingSecurityScopedResource()
        guard didStartAccess || isAppOwnedURL(resolved.url) else {
            throw WindowsVRLibraryError.invalidBookmark
        }
        do {
            let values = try resolved.url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw WindowsVRLibraryError.invalidBookmark }
            var updated = library
            if let index = updated.firstIndex(where: { $0.id == id }), resolved.isStale {
                updated[index].folderBookmark = try WindowsVRLibraryStore.makeFolderBookmark(for: resolved.url)
                updated[index].updatedAt = Date()
                try persist(updated)
            }
            releaseGameDirectoryAccess()
            gameDirectoryAccessURL = didStartAccess ? resolved.url : nil
            gameDirectory = resolved.url
            gameFolderName = resolved.url.lastPathComponent
            selectedLibraryEntryID = id
            manifestName = L("\(entry.manifest.title) — library", "\(entry.manifest.title) — Bibliothek")
            manifest = entry.manifest
            let profile = entry.selectedProfile
            selectedProfileID = profile?.id
            if let profile {
                manifest = try profile.applying(to: entry.manifest)
                renderScaleDraft = profile.renderScale
                profileNameDraft = profile.name
                launchArgumentsText = Self.argumentText(profile.launchArguments)
            } else {
                renderScaleDraft = 1
                profileNameDraft = L("Default", "Standard")
                launchArgumentsText = Self.argumentText(entry.manifest.launchArguments)
            }
            launchError = nil
        } catch {
            if didStartAccess { resolved.url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func selectProfile(id: String) throws {
        guard canChangeSelection else { return }
        guard let entry = selectedEntry,
              let profile = entry.profiles.first(where: { $0.id == id }) else {
            throw WindowsVRLibraryError.noSelectedProfile
        }
        manifest = try profile.applying(to: entry.manifest)
        selectedProfileID = profile.id
        renderScaleDraft = profile.renderScale
        profileNameDraft = profile.name
        launchArgumentsText = Self.argumentText(profile.launchArguments)
        var updated = library
        if let index = updated.firstIndex(where: { $0.id == entry.id }) {
            updated[index].selectedProfileID = profile.id
            updated[index].updatedAt = Date()
            try persist(updated)
        }
    }

    func saveProfile(asNew: Bool = false) throws {
        guard canChangeSelection, let entry = selectedEntry else {
            throw WindowsVRLibraryError.noSavedGame
        }
        guard let baseManifest = manifest else { throw WindowsVRLibraryError.noActiveGame }
        let arguments = draftArguments
        guard arguments.count <= 64, arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw WindowsVRLibraryError.invalidProfileArguments
        }
        let cleanName = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 80 else {
            throw WindowsVRLibraryError.invalidProfileName
        }
        let existing = asNew ? nil : entry.profiles.first(where: { $0.id == selectedProfileID })
        let profile = try WindowsVRLaunchProfile(
            id: existing?.id ?? UUID().uuidString,
            name: cleanName,
            backend: baseManifest.backend,
            graphics: baseManifest.graphics,
            launchArguments: arguments,
            environment: baseManifest.environment,
            renderScale: renderScaleDraft
        )
        var updated = library
        guard let index = updated.firstIndex(where: { $0.id == entry.id }) else {
            throw WindowsVRLibraryError.noSavedGame
        }
        if let profileIndex = updated[index].profiles.firstIndex(where: { $0.id == profile.id }) {
            updated[index].profiles[profileIndex] = profile
        } else {
            updated[index].profiles.append(profile)
        }
        updated[index].selectedProfileID = profile.id
        updated[index].updatedAt = Date()
        try persist(updated)
        selectedProfileID = profile.id
        renderScaleDraft = profile.renderScale
        profileNameDraft = profile.name
        manifest = try profile.applying(to: updated[index].manifest)
    }

    func removeSelectedProfile() throws {
        guard canChangeSelection, let entry = selectedEntry,
              let selectedProfileID,
              entry.profiles.contains(where: { $0.id == selectedProfileID }) else {
            throw WindowsVRLibraryError.noSelectedProfile
        }
        var updated = library
        guard let index = updated.firstIndex(where: { $0.id == entry.id }) else {
            throw WindowsVRLibraryError.noSavedGame
        }
        updated[index].profiles.removeAll(where: { $0.id == selectedProfileID })
        updated[index].selectedProfileID = updated[index].profiles.first?.id
        updated[index].updatedAt = Date()
        try persist(updated)
        self.selectedProfileID = updated[index].selectedProfileID
        if let profile = updated[index].selectedProfile {
            manifest = try profile.applying(to: updated[index].manifest)
            renderScaleDraft = profile.renderScale
            profileNameDraft = profile.name
            launchArgumentsText = Self.argumentText(profile.launchArguments)
        } else {
            manifest = updated[index].manifest
            renderScaleDraft = 1
            profileNameDraft = L("Default", "Standard")
            launchArgumentsText = Self.argumentText(updated[index].manifest.launchArguments)
        }
    }

    func removeLibraryEntry(id: String) throws {
        guard canChangeSelection else { return }
        var updated = library
        guard updated.contains(where: { $0.id == id }) else { throw WindowsVRLibraryError.noSavedGame }
        updated.removeAll(where: { $0.id == id })
        try persist(updated)
        if selectedLibraryEntryID == id {
            releaseGameDirectoryAccess()
            selectedLibraryEntryID = nil
            selectedProfileID = nil
            manifest = nil
            manifestName = nil
            gameDirectory = nil
            gameFolderName = nil
            launchArgumentsText = "[]"
            renderScaleDraft = 1
            profileNameDraft = L("Default", "Standard")
        }
    }

    func launch(prepareCompositor: () async throws -> Void) async {
        guard canLaunch, let gameDirectory else { return }
        do {
            let launchManifest = try effectiveManifest()
            isLaunching = true
            immersiveSpaceClosedDuringLaunch = false
            launchError = nil
            defer { isLaunching = false }
            guard runtime.isAvailable else { throw LauncherFailure.runtimePluginMissing }
            try runtime.preflight(manifest: launchManifest, gameDirectory: gameDirectory)
            try await jitCoordinator.prepareDebugger()
            guard wvr_compositor_set_render_scale_v1(renderScaleDraft) == 0 else {
                throw WindowsVRLibraryError.invalidProfileArguments
            }
            try await prepareCompositor()
            guard immersiveSpaceIsOpen, !immersiveSpaceClosedDuringLaunch else {
                throw LaunchPreparationFailure.immersiveSpaceClosed
            }
            // WindowsVRCore emits only the unchanged v1 plugin JSON request.
            try await runtime.launch(manifest: launchManifest, gameDirectory: gameDirectory)
            hasAcceptedLaunch = true
            runtimeStatus = L("Launch accepted; game readiness unknown", "Start wurde angenommen; Spielbereitschaft unbekannt")
            beginStatusMonitoring()
            if !immersiveSpaceIsOpen || immersiveSpaceClosedDuringLaunch {
                try await runtime.stop()
                hasAcceptedLaunch = false
                requiresRestart = true
                statusMonitor?.cancel()
                statusMonitor = nil
                releaseGameDirectoryAccess()
                runtimeStatus = L("Runtime stopped; restart the app before another launch", "Laufzeit beendet; starte die App neu, bevor du ein weiteres Spiel startest")
            }
        } catch {
            if immersiveSpaceClosedDuringLaunch && hasAcceptedLaunch { requiresRestart = true }
            if hasAcceptedLaunch {
                recordStopFailure(error, becauseImmersiveClosed: immersiveSpaceClosedDuringLaunch)
            } else {
                let detail = runtime.nativeStatus().lastError
                launchError = L("The game could not be launched: \(detail?.isEmpty == false ? detail! : error.localizedDescription)", "Das Spiel konnte nicht gestartet werden: \(detail?.isEmpty == false ? detail! : error.localizedDescription)")
            }
        }
    }

    func waitForCompositorReady(timeout: Duration = .seconds(12)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if !immersiveSpaceIsOpen { throw LaunchPreparationFailure.immersiveSpaceClosed }
            var readiness = WVRCompositorReadinessV1()
            readiness.structSize = UInt32(MemoryLayout<WVRCompositorReadinessV1>.size)
            let status = wvr_compositor_copy_readiness_v1(&readiness)
            let nowNanoseconds = UInt64(max(0, CACurrentMediaTime() * 1.0e9))
            let trackingTimestamp = readiness.trackingTimestampNanoseconds
            let poseIsFresh = trackingTimestamp <= nowNanoseconds
                ? nowNanoseconds - trackingTimestamp < 500_000_000
                : trackingTimestamp - nowNanoseconds <= 100_000_000
            if status == 0, readiness.metalDeviceBound != 0,
               readiness.stereoTargetsPublished != 0,
               readiness.trackedHeadPoseAvailable != 0, poseIsFresh {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LaunchPreparationFailure.rendererTimedOut
    }

    func immersiveSpaceDidOpen() {
        immersiveSpaceIsOpen = true
        immersiveSpaceClosedDuringLaunch = false
    }

    func immersiveSpaceDidClose() async {
        immersiveSpaceIsOpen = false
        if isLaunching { immersiveSpaceClosedDuringLaunch = true }
        guard hasAcceptedLaunch, !isStopping, !stopRequested else { return }
        isStopping = true
        defer { isStopping = false }
        do {
            try await runtime.stop()
            hasAcceptedLaunch = false
            requiresRestart = true
            runtimeStatus = L("Runtime stopped; restart the app before another launch", "Laufzeit beendet; starte die App neu, bevor du ein weiteres Spiel startest")
            statusMonitor?.cancel()
            statusMonitor = nil
            releaseGameDirectoryAccess()
        } catch {
            requiresRestart = true
            recordStopFailure(error, becauseImmersiveClosed: true)
        }
    }

    func stop() async {
        guard hasAcceptedLaunch, !isStopping, !stopRequested else { return }
        isStopping = true
        launchError = nil
        defer { isStopping = false }
        do {
            try await runtime.stop()
            hasAcceptedLaunch = false
            requiresRestart = true
            runtimeStatus = L("Runtime stopped; restart the app before another launch", "Laufzeit beendet; starte die App neu, bevor du ein weiteres Spiel startest")
            statusMonitor?.cancel()
            statusMonitor = nil
            releaseGameDirectoryAccess()
        } catch {
            recordStopFailure(error, becauseImmersiveClosed: false)
        }
    }

    func makeCompatibilityReport() -> WindowsVRCompatibilityReport? {
        refreshCompositorCounters()
        guard let manifest, let launchManifest = try? effectiveManifest() else { return nil }
        let state = runtime.nativeStatus()
        let wine = WindowsVRWineStatus(
            stateCode: runtime.isAvailable ? state.state : nil,
            state: runtime.isAvailable ? wineStateName(state.state) : "plugin unavailable",
            detail: runtime.isAvailable ? state.lastError : WindowsRuntimeError.integrationMissing.localizedDescription
        )
        let profile = selectedEntry?.profiles.first(where: { $0.id == selectedProfileID })
        let requested = WindowsVRRequestedProfile(
            gameID: manifest.id,
            gameTitle: manifest.title,
            profileID: profile?.id,
            profileName: profileNameDraft.isEmpty ? "Current manifest" : profileNameDraft,
            backend: launchManifest.backend,
            graphics: launchManifest.graphics,
            executableRelativePath: launchManifest.executableRelativePath,
            launchArguments: launchManifest.launchArguments,
            environment: launchManifest.environment,
            spatialRenderScale: renderScaleDraft
        )
        let pluginAvailable = runtime.isAvailable
        let graphicsAssessment: WindowsVRCapabilityAssessment
        if launchManifest.graphics == .vulkan {
            graphicsAssessment = .init(id: "Vulkan", status: "unavailable", reason: "Vulkan requests are rejected; no graphics fallback is selected.")
        } else if launchManifest.graphics == .direct3D12 {
            graphicsAssessment = .init(id: "Direct3D 12", status: runtime.supportsGraphics(.direct3D12) ? "experimental / unverified" : "unavailable", reason: runtime.supportsGraphics(.direct3D12)
                ? "The signed bundle declares a matching DXMT D3D12 transport package. The pinned backend exposes Shader Model 5.1/DXBC; DXIL/Shader Model 6, mesh shaders and ray tracing are unsupported. Headset execution, game compatibility and performance are not established by this report."
                : "The matching experimental DXMT D3D12 native/guest package is absent. A D3D12 manifest is retained but cannot launch; D3D11 is not substituted.")
        } else if pluginAvailable {
            graphicsAssessment = .init(id: "Direct3D 11", status: "conditional", reason: "The signed plugin is loadable, but this source-only report cannot establish that game startup or frame submission succeeds.")
        } else {
            graphicsAssessment = .init(id: "Direct3D 11", status: "unavailable", reason: "The signed runtime plugin is not available in this app process.")
        }
        let backendAssessment = WindowsVRCapabilityAssessment(
            id: launchManifest.backend.rawValue,
            status: pluginAvailable && launchManifest.backend == .windowsWineFEX ? "conditional" : "unavailable",
            reason: pluginAvailable && launchManifest.backend == .windowsWineFEX
                ? "The version-1 plugin can receive this explicit backend request; guest readiness and runtime resource availability remain unverified. The plugin must reject unsupported backends without fallback."
                : "The selected backend is not packaged or the signed runtime plugin is unavailable; launch is blocked."
        )
        let capabilities = [
            backendAssessment,
            graphicsAssessment,
            .init(id: "Spatial eye scaling", status: "conditional", reason: "Uniform per-eye Metal bilinear scaling is implemented in source; default render scale is 1.0. Quality and GPU benefit are unmeasured."),
            .init(id: "MetalFX temporal super resolution", status: "unavailable", reason: "The visionOS 27 SDK marks the temporal scaler unavailable on the initial target; no alternate SR backend is connected."),
            .init(id: "Frame generation", status: "unavailable", reason: "No frame-generation adapter or measured stereo pacing path is implemented."),
            .init(id: "Guest-pipeline foveation", status: "unavailable", reason: "No guest rendering-pass integration or validated gaze/raster-rate path is connected.")
        ]
        let device = UIDevice.current
        return WindowsVRCompatibilityReport(
            deviceModel: device.model + " (" + (Self.systemString("hw.machine") ?? "hardware identifier unavailable") + ")",
            operatingSystemName: device.systemName,
            operatingSystemVersion: device.systemVersion,
            operatingSystemBuildDescription: ProcessInfo.processInfo.operatingSystemVersionString + " / " + (Self.systemString("kern.osversion") ?? "build identifier unavailable"),
            requestedProfile: requested,
            runtimePluginAvailable: pluginAvailable,
            wineStatus: wine,
            compositorCounters: compositorCounters,
            capabilities: capabilities
        )
    }

    func makeCompatibilityReportJSON() throws -> Data {
        guard let report = makeCompatibilityReport() else { throw WindowsVRLibraryError.noActiveGame }
        return try report.encodedJSON()
    }

    var reportFilename: String {
        let name = manifest?.title ?? "windows-vr"
        let safe = name.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return "\(String(safe))-compatibility-report.json"
    }

    func dismissImportError() {
        isShowingImportError = false
        importError = nil
    }

    func presentLibraryError(_ error: Error) {
        showImportError(error)
    }

    private var draftArguments: [String] {
        // JSON preserves empty argv entries, spaces, and embedded newlines.
        // Invalid drafts stay visibly invalid rather than silently repairing argv.
        (try? JSONDecoder().decode([String].self, from: Data(launchArgumentsText.utf8))) ?? [String(decoding: [UInt8(0)], as: UTF8.self)]
    }

    private static func argumentText(_ arguments: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(arguments) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func effectiveManifest() throws -> WindowsGameManifest {
        guard let manifest else { throw WindowsVRLibraryError.noActiveGame }
        guard draftArguments.count <= 64, !draftArguments.contains(where: { $0.contains(String(decoding: [UInt8(0)], as: UTF8.self)) }) else {
            throw WindowsVRLibraryError.invalidProfileArguments
        }
        let selectedProfile = selectedEntry?.profiles.first(where: { $0.id == selectedProfileID })
        let base = try selectedProfile?.applying(to: selectedEntry?.manifest ?? manifest) ?? manifest
        return try WindowsGameManifest(
            id: base.id,
            title: base.title,
            executableRelativePath: base.executableRelativePath,
            backend: base.backend,
            graphics: base.graphics,
            launchArguments: draftArguments,
            environment: base.environment,
            schemaVersion: base.schemaVersion
        )
    }

    private static func systemString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size <= 4096 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname(key, buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func persist(_ updated: [WindowsVRLibraryEntry]) throws {
        guard libraryError == nil else { throw WindowsVRLibraryError.corruptLibrary }
        try WindowsVRLibraryStore.save(updated)
        library = updated
        libraryError = nil
    }

    private func refreshCompositorCounters() {
        var stats = WVRCompositorStatsV1()
        stats.abiVersion = WVR_COMPOSITOR_ABI_VERSION
        stats.structSize = UInt32(MemoryLayout<WVRCompositorStatsV1>.size)
        guard wvr_compositor_copy_stats_v1(&stats) == 0 else {
            compositorCounters = nil
            return
        }
        compositorCounters = WindowsVRCompositorCounters(
            abiVersion: stats.abiVersion,
            submittedFrames: stats.submittedFrames,
            acquiredFrames: stats.acquiredFrames,
            droppedFrames: stats.droppedFrames,
            completedFrames: stats.completedFrames,
            queuedFrames: stats.queuedFrames
        )
    }

    private func beginStatusMonitoring() {
        statusMonitor?.cancel()
        statusMonitor = Task { [weak self] in
            while !Task.isCancelled, let self, self.hasAcceptedLaunch {
                self.refreshRuntimeStatus()
                self.refreshCompositorCounters()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refreshRuntimeStatus() {
        let snapshot = runtime.nativeStatus()
        switch snapshot.state {
        case 0: runtimeStatus = L("Launch accepted; runtime is idle", "Start wurde angenommen; Laufzeit ist im Leerlauf")
        case 1: runtimeStatus = L("Runtime preparing", "Laufzeit wird vorbereitet")
        case 2: runtimeStatus = L("Wine services starting", "Wine-Dienste werden gestartet")
        case 3: runtimeStatus = L("Guest process launching", "Gastprozess wird gestartet")
        case 4: runtimeStatus = L("Wine process active; game readiness and rendering unknown", "Wine-Prozess aktiv; Spielbereitschaft und Rendering unbekannt")
        case 5:
            stopRequested = true
            runtimeStatus = L("Exit requested; waiting for the guest and Wine process", "Beenden angefordert; warte auf Gast- und Wine-Prozess")
        case 6:
            stopRequested = false
            runtimeStatus = L("Runtime stopped; restart the app before another launch", "Laufzeit beendet; starte die App neu, bevor du ein weiteres Spiel startest")
            hasAcceptedLaunch = false
            requiresRestart = true
            statusMonitor?.cancel()
            releaseGameDirectoryAccess()
        case 7:
            stopRequested = false
            runtimeStatus = L("Runtime failed; restart the app before another launch", "Laufzeitfehler; starte die App neu, bevor du ein weiteres Spiel startest")
            hasAcceptedLaunch = false
            requiresRestart = true
            statusMonitor?.cancel()
            releaseGameDirectoryAccess()
            if let error = snapshot.lastError, !error.isEmpty {
                launchError = L("The runtime reported a failure: \(error)", "Die Laufzeit meldet einen Fehler: \(error)")
            }
        default: runtimeStatus = L("Runtime status unavailable", "Laufzeitstatus nicht verfügbar")
        }
    }

    private func wineStateName(_ state: Int32) -> String {
        switch state {
        case 0: "idle"
        case 1: "preparing"
        case 2: "Wine services starting"
        case 3: "guest process launching"
        case 4: "Wine process active; game readiness unknown"
        case 5: "stopping"
        case 6: "stopped"
        case 7: "failed"
        default: "unknown state"
        }
    }

    private func releaseGameDirectoryAccess() {
        gameDirectoryAccessURL?.stopAccessingSecurityScopedResource()
        gameDirectoryAccessURL = nil
    }

    private func recordStopFailure(_ error: Error, becauseImmersiveClosed: Bool) {
        if case WindowsRuntimeError.stopPending = error {
            stopRequested = true
            runtimeStatus = L("Exit requested; waiting for the guest and Wine process", "Beenden angefordert; warte auf Gast- und Wine-Prozess")
            launchError = becauseImmersiveClosed
                ? L("The immersive renderer closed. Cooperative exit was requested; the runtime still owns the session until Wine exits.", "Der immersive Renderer wurde geschlossen. Das geordnete Beenden wurde angefordert; die Laufzeit behält die Sitzung bis zum Ende von Wine.")
                : nil
            // Keep both access and monitoring until native stopped/failed status.
            return
        }
        launchError = stopFailureMessage(error, becauseImmersiveClosed: becauseImmersiveClosed)
    }

    private func stopFailureMessage(_ error: Error, becauseImmersiveClosed: Bool) -> String {
        if case WindowsRuntimeError.pluginRejectedRequest(let status) = error,
           status == 16 || status == -16 {
            return L("The runtime is busy (EBUSY) and could not stop the guest. Let the guest exit naturally or restart the app; the session remains marked active.", "Die Laufzeit ist ausgelastet (EBUSY) und konnte den Gast nicht beenden. Warte, bis der Gast selbst beendet wird, oder starte die App neu; die Sitzung bleibt als aktiv markiert.")
        }
        if becauseImmersiveClosed {
            return L("The immersive renderer closed, but the runtime could not confirm a stop. Restart the app before another launch. \(error.localizedDescription)", "Der immersive Renderer wurde geschlossen, aber die Laufzeit konnte das Beenden nicht bestätigen. Starte die App neu, bevor du ein weiteres Spiel startest. \(error.localizedDescription)")
        }
        return L("The runtime could not confirm that the session stopped. The session remains marked active. \(error.localizedDescription)", "Die Laufzeit konnte das Beenden der Sitzung nicht bestätigen. Die Sitzung bleibt als aktiv markiert. \(error.localizedDescription)")
    }

    private func showImportError(_ error: Error) {
        importError = error.localizedDescription
        isShowingImportError = true
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError
    }
}

private enum LauncherFailure: LocalizedError {
    case runtimePluginMissing
    var errorDescription: String? {
        L("The signed WindowsRuntimePlugin.framework is not embedded in this app, so no launch request was sent.", "Das signierte WindowsRuntimePlugin.framework ist nicht in dieser App eingebettet. Es wurde keine Startanfrage gesendet.")
    }
}

private enum LaunchPreparationFailure: LocalizedError {
    case immersiveSpaceClosed
    case rendererTimedOut

    var errorDescription: String? {
        switch self {
        case .immersiveSpaceClosed:
            L("The immersive renderer closed before the launch request was sent.", "Der immersive Renderer wurde geschlossen, bevor die Startanfrage gesendet wurde.")
        case .rendererTimedOut:
            L("The immersive renderer did not bind Metal, publish stereo targets, and provide a fresh tracked head pose within 12 seconds. No launch request was sent.", "Der immersive Renderer hat innerhalb von 12 Sekunden weder Metal gebunden und Stereo-Ziele veröffentlicht noch eine aktuelle getrackte Kopfpose bereitgestellt. Es wurde keine Startanfrage gesendet.")
        }
    }
}

private enum ImportFailure: LocalizedError {
    case manifestAccessDenied
    case folderAccessDenied

    var errorDescription: String? {
        switch self {
        case .manifestAccessDenied:
            L("The app could not get permission to read the selected manifest.", "Die App konnte keine Leseberechtigung für das ausgewählte Manifest erhalten.")
        case .folderAccessDenied:
            L("The app could not get permission to read the selected game folder.", "Die App konnte keine Leseberechtigung für den ausgewählten Spielordner erhalten.")
        }
    }
}
