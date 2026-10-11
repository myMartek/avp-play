import Foundation
import Observation
import QuartzCore
import WindowsVRCore

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
    private(set) var requiresRestart = false
    private(set) var runtimeStatus = "No runtime session"
    private(set) var launchError: String?
    var isShowingImportError = false
    private(set) var importError: String?

    @ObservationIgnored private let runtime = NativePluginWindowsRuntime()
    @ObservationIgnored private let jitCoordinator = JITCoordinator()
    private var gameDirectoryAccessURL: URL?
    private var immersiveSpaceIsOpen = false
    private var immersiveSpaceClosedDuringLaunch = false
    private var statusMonitor: Task<Void, Never>?

    var canLaunch: Bool {
        manifest != nil && gameDirectory != nil && !isLaunching && !hasAcceptedLaunch && !isStopping && !requiresRestart
    }

    var canChangeSelection: Bool {
        !isLaunching && !hasAcceptedLaunch && !isStopping && !requiresRestart
    }

    var sessionStatus: String {
        if isStopping { return "Stopping" }
        if isLaunching { return "Starting" }
        if hasAcceptedLaunch { return runtimeStatus }
        if requiresRestart { return runtimeStatus }
        return "Not running"
    }

    func importManifest(_ result: Result<[URL], Error>) {
        guard canChangeSelection else { return }
        do {
            guard let url = try result.get().first else { return }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            guard didStartAccess else {
                throw ImportFailure.manifestAccessDenied
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(WindowsGameManifest.self, from: data)
            try decoded.validate()

            manifest = decoded
            manifestName = url.lastPathComponent
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
            let didStartAccess = url.startAccessingSecurityScopedResource()
            guard didStartAccess else {
                throw ImportFailure.folderAccessDenied
            }

            if let oldURL = gameDirectoryAccessURL {
                oldURL.stopAccessingSecurityScopedResource()
            }
            gameDirectoryAccessURL = url
            gameDirectory = url
            gameFolderName = url.lastPathComponent
            launchError = nil
        } catch {
            guard !isCancellation(error) else { return }
            showImportError(error)
        }
    }

    func launch(prepareCompositor: () async throws -> Void) async {
        guard canLaunch, let manifest, let gameDirectory else { return }
        isLaunching = true
        immersiveSpaceClosedDuringLaunch = false
        launchError = nil
        defer { isLaunching = false }

        do {
            guard runtime.isAvailable else { throw LauncherFailure.runtimePluginMissing }
            // The debugger helper can temporarily switch away from this app.
            // Prepare it before opening the compositor so that transition does
            // not tear down an already-initialized immersive session.
            try await jitCoordinator.prepareDebugger()
            try await prepareCompositor()
            guard immersiveSpaceIsOpen, !immersiveSpaceClosedDuringLaunch else {
                throw LaunchPreparationFailure.immersiveSpaceClosed
            }
            try await runtime.launch(manifest: manifest, gameDirectory: gameDirectory)
            // The plugin contract confirms enqueue/acceptance only, not game readiness or rendering.
            hasAcceptedLaunch = true
            runtimeStatus = "Launch accepted; game readiness unknown"
            beginStatusMonitoring()
            if !immersiveSpaceIsOpen || immersiveSpaceClosedDuringLaunch {
                try await runtime.stop()
                hasAcceptedLaunch = false
                requiresRestart = true
                statusMonitor?.cancel()
                statusMonitor = nil
                releaseGameDirectoryAccess()
                runtimeStatus = "Runtime stopped; restart the app before another launch"
            }
        } catch {
            if immersiveSpaceClosedDuringLaunch, hasAcceptedLaunch {
                requiresRestart = true
            }
            launchError = "The game could not be launched: \(error.localizedDescription)"
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
            // Compositor poses are predicted to the near-future display time.
            // Accept up to 100 ms ahead and 500 ms behind, with ordered
            // subtraction so UInt64 cannot underflow for a future timestamp.
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
        if isLaunching {
            immersiveSpaceClosedDuringLaunch = true
        }
        guard hasAcceptedLaunch, !isStopping else { return }

        isStopping = true
        defer { isStopping = false }
        do {
            try await runtime.stop()
            hasAcceptedLaunch = false
            requiresRestart = true
            runtimeStatus = "Runtime stopped; restart the app before another launch"
            statusMonitor?.cancel()
            statusMonitor = nil
            releaseGameDirectoryAccess()
        } catch {
            requiresRestart = true
            launchError = stopFailureMessage(error, becauseImmersiveClosed: true)
        }
    }

    func stop() async {
        guard hasAcceptedLaunch, !isStopping else { return }
        isStopping = true
        launchError = nil
        defer { isStopping = false }

        do {
            try await runtime.stop()
            hasAcceptedLaunch = false
            requiresRestart = true
            runtimeStatus = "Runtime stopped; restart the app before another launch"
            statusMonitor?.cancel()
            statusMonitor = nil
            releaseGameDirectoryAccess()
        } catch {
            launchError = stopFailureMessage(error, becauseImmersiveClosed: false)
        }
    }

    private func beginStatusMonitoring() {
        statusMonitor?.cancel()
        statusMonitor = Task { [weak self] in
            while !Task.isCancelled, let self, self.hasAcceptedLaunch {
                self.refreshRuntimeStatus()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func refreshRuntimeStatus() {
        let snapshot = runtime.nativeStatus()
        switch snapshot.state {
        case 0: runtimeStatus = "Launch accepted; runtime is idle"
        case 1: runtimeStatus = "Runtime preparing"
        case 2: runtimeStatus = "Wine services starting"
        case 3: runtimeStatus = "Guest process launching"
        case 4: runtimeStatus = "Wine process active; game readiness and rendering unknown"
        case 5: runtimeStatus = "Runtime stopping"
        case 6:
            runtimeStatus = "Runtime stopped; restart the app before another launch"
            hasAcceptedLaunch = false
            requiresRestart = true
            statusMonitor?.cancel()
            releaseGameDirectoryAccess()
        case 7:
            runtimeStatus = "Runtime failed; restart the app before another launch"
            hasAcceptedLaunch = false
            requiresRestart = true
            statusMonitor?.cancel()
            releaseGameDirectoryAccess()
            if let error = snapshot.lastError, !error.isEmpty {
                launchError = "The runtime reported a failure: \(error)"
            }
        default: runtimeStatus = "Runtime status unavailable"
        }
    }

    private func releaseGameDirectoryAccess() {
        gameDirectoryAccessURL?.stopAccessingSecurityScopedResource()
        gameDirectoryAccessURL = nil
    }

    private func stopFailureMessage(_ error: Error, becauseImmersiveClosed: Bool) -> String {
        if case WindowsRuntimeError.pluginRejectedRequest(let status) = error,
           status == 16 || status == -16 {
            return "The runtime is busy (EBUSY) and could not stop the guest. Let the guest exit naturally or restart the app; the session remains marked active."
        }
        if becauseImmersiveClosed {
            return "The immersive renderer closed, but the runtime could not confirm a stop. Restart the app before another launch. \(error.localizedDescription)"
        }
        return "The runtime could not confirm that the session stopped. The session remains marked active. \(error.localizedDescription)"
    }

    func dismissImportError() {
        isShowingImportError = false
        importError = nil
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
        "The signed WindowsRuntimePlugin.framework is not embedded in this app, so no launch request was sent."
    }
}

private enum LaunchPreparationFailure: LocalizedError {
    case immersiveSpaceClosed
    case rendererTimedOut

    var errorDescription: String? {
        switch self {
        case .immersiveSpaceClosed:
            "The immersive renderer closed before the launch request was sent."
        case .rendererTimedOut:
            "The immersive renderer did not bind Metal, publish stereo targets, and provide a fresh tracked head pose within 12 seconds. No launch request was sent."
        }
    }
}

private enum ImportFailure: LocalizedError {
    case manifestAccessDenied
    case folderAccessDenied

    var errorDescription: String? {
        switch self {
        case .manifestAccessDenied:
            "The app could not get permission to read the selected manifest."
        case .folderAccessDenied:
            "The app could not get permission to read the selected game folder."
        }
    }
}
