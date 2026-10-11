import Foundation
#if canImport(Darwin)
import Darwin
import Security
#endif

/// Loads an optional runtime plugin from the host application's signed Frameworks directory.
/// It never accepts a plugin path from a game manifest or other caller-controlled input.
public final class NativePluginWindowsRuntime: WindowsRuntime, @unchecked Sendable {
    private typealias LaunchFunction = @convention(c) (UnsafePointer<CChar>?) -> Int32
    private typealias StopFunction = @convention(c) () -> Int32
    private typealias StatusFunction = @convention(c) () -> Int32
    private typealias GraphicsCapabilitiesFunction = @convention(c) () -> UInt32
    private typealias LastErrorFunction = @convention(c) (UnsafeMutablePointer<CChar>?, UInt64) -> UInt64

    private let lock = NSLock()
    private var libraryHandle: UnsafeMutableRawPointer?
    private var launchFunction: LaunchFunction?
    private var preflightFunction: LaunchFunction?
    private var graphicsCapabilitiesFunction: GraphicsCapabilitiesFunction?
    private var stopFunction: StopFunction?
    private var statusFunction: StatusFunction?
    private var lastErrorFunction: LastErrorFunction?

    /// `frameworkName` is a bundle resource name such as `WindowsRuntimePlugin.framework`.
    /// The framework is resolved only from the app bundle's `Frameworks` directory.
    public init(frameworkName: String = "WindowsRuntimePlugin.framework") {
        #if canImport(Darwin)
        let frameworksURL = Bundle.main.bundleURL
            .appendingPathComponent("Frameworks", isDirectory: true)
            .resolvingSymlinksInPath()
        let frameworkURL = frameworksURL.appendingPathComponent(frameworkName, isDirectory: true)
            .resolvingSymlinksInPath()
        guard Self.isContained(frameworkURL, in: frameworksURL),
              let executableURL = Bundle(url: frameworkURL)?.executableURL
        else {
            return
        }

        guard Self.hasValidCodeSignature(at: frameworkURL),
              Self.isContained(executableURL, in: frameworkURL)
        else {
            return
        }

        guard let handle = dlopen(executableURL.path, RTLD_NOW | RTLD_LOCAL) else { return }
        guard let abiVersionAddress = dlsym(handle, "windows_vr_runtime_abi_version"),
              abiVersionAddress.assumingMemoryBound(to: UInt32.self).pointee == 1,
              let launchAddress = dlsym(handle, "windows_vr_launch_v1"),
              let stopAddress = dlsym(handle, "windows_vr_stop_v1"),
              let statusAddress = dlsym(handle, "windows_vr_status_v1"),
              let lastErrorAddress = dlsym(handle, "windows_vr_last_error_v1")
        else {
            dlclose(handle)
            return
        }

        libraryHandle = handle
        launchFunction = unsafeBitCast(launchAddress, to: LaunchFunction.self)
        if let preflightAddress = dlsym(handle, "windows_vr_preflight_v1") {
            preflightFunction = unsafeBitCast(preflightAddress, to: LaunchFunction.self)
        }
        if let capabilitiesAddress = dlsym(handle, "windows_vr_graphics_capabilities_v1") {
            graphicsCapabilitiesFunction = unsafeBitCast(capabilitiesAddress, to: GraphicsCapabilitiesFunction.self)
        }
        stopFunction = unsafeBitCast(stopAddress, to: StopFunction.self)
        statusFunction = unsafeBitCast(statusAddress, to: StatusFunction.self)
        lastErrorFunction = unsafeBitCast(lastErrorAddress, to: LastErrorFunction.self)
        #endif
    }

    deinit {
        // Intentionally keep the signed plugin loaded for process lifetime. This prevents
        // unloading code while a plugin-owned asynchronous launch or stop operation is active.
        _ = libraryHandle
    }

    public func preflight(manifest: WindowsGameManifest, gameDirectory: URL) throws {
        let requestJSON = try prepareRequest(manifest: manifest, gameDirectory: gameDirectory)
        lock.lock()
        defer { lock.unlock() }
        guard launchFunction != nil else { throw WindowsRuntimeError.integrationMissing }
        guard let preflightFunction else { return } // older signed V1 plugin
        let status = requestJSON.withCString { preflightFunction($0) }
        guard status == 0 else { throw WindowsRuntimeError.pluginRejectedRequest(status) }
    }

    public func launch(manifest: WindowsGameManifest, gameDirectory: URL) async throws {
        let requestJSON = try prepareRequest(manifest: manifest, gameDirectory: gameDirectory)
        let status = try invokeLaunch(requestJSON)
        guard status == 0 else { throw WindowsRuntimeError.pluginRejectedRequest(status) }
    }

    private func prepareRequest(manifest: WindowsGameManifest, gameDirectory: URL) throws -> String {
        try manifest.validate()
        guard supportsGraphics(manifest.graphics) else {
            throw WindowsRuntimeError.graphicsPackageMissing(manifest.graphics)
        }
        guard gameDirectory.isFileURL else {
            throw WindowsRuntimeError.invalidGameDirectory
        }

        let localRelativePath = manifest.executableRelativePath.replacingOccurrences(of: "\\", with: "/")
        let executableURL = gameDirectory.appendingPathComponent(localRelativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootURL = gameDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isContained(executableURL, in: rootURL) else {
            throw WindowsGameManifestError.invalidExecutableRelativePath
        }
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw WindowsRuntimeError.missingExecutable
        }
        let executableValues = try executableURL.resourceValues(forKeys: [.isRegularFileKey])
        guard executableValues.isRegularFile == true else {
            throw WindowsRuntimeError.executableNotRegularFile
        }

        let request = LaunchRequest(
            schemaVersion: 1,
            gameID: manifest.id,
            backend: manifest.backend.rawValue,
            graphics: manifest.graphics.rawValue,
            gameDirectory: rootURL.path,
            executablePath: executableURL.path,
            arguments: manifest.launchArguments,
            environment: manifest.environment
        )
        let requestData = try JSONEncoder().encode(request)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw WindowsRuntimeError.integrationMissing
        }

        return requestJSON
    }

    public func supportsGraphics(_ graphics: WindowsGraphicsAPI) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard launchFunction != nil else { return false }
        let mask = graphicsCapabilitiesFunction?() ?? 1 // older signed V1 plugin: D3D11 only
        switch graphics {
        case .direct3D11: return mask & 1 != 0
        case .direct3D12: return mask & 2 != 0
        case .vulkan: return false
        }
    }

    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return launchFunction != nil
    }

    public func stop() async throws {
        guard let status = invokeStop() else {
            throw WindowsRuntimeError.integrationMissing
        }
        #if canImport(Darwin)
        if status == EINPROGRESS { throw WindowsRuntimeError.stopPending }
        #endif
        guard status == 0 else {
            throw WindowsRuntimeError.pluginRejectedRequest(status)
        }
    }

    /// Native bridge state: 0 idle, 1 preparing, 2 wineserver startup, 3 launching,
    /// 4 running, 5 stopping, 6 stopped, 7 failed.
    public func nativeStatus() -> (state: Int32, lastError: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let statusFunction else { return (7, WindowsRuntimeError.integrationMissing.localizedDescription) }
        var buffer = [CChar](repeating: 0, count: 1024)
        let errorFunction = lastErrorFunction
        let count = errorFunction?(&buffer, UInt64(buffer.count)) ?? 0
        let error = count > 0 ? String(cString: buffer) : nil
        return (statusFunction(), error)
    }

    private func invokeLaunch(_ requestJSON: String) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let launchFunction else {
            throw WindowsRuntimeError.integrationMissing
        }
        return requestJSON.withCString { launchFunction($0) }
    }

    private func invokeStop() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let stopFunction else { return nil }
        return stopFunction()
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func hasValidCodeSignature(at url: URL) -> Bool {
        #if os(macOS)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
        #else
        // iOS-family platforms enforce signed executable code when loading app-bundled frameworks.
        return true
        #endif
    }

    private struct LaunchRequest: Encodable {
        let schemaVersion: Int
        let gameID: String
        let backend: String
        let graphics: String
        let gameDirectory: String
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
    }
}
