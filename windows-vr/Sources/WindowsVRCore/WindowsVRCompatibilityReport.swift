import Foundation

public struct WindowsVRRequestedProfile: Codable, Sendable, Equatable {
    public let gameID: String
    public let gameTitle: String
    public let profileID: String?
    public let profileName: String
    public let backend: String
    public let graphics: String
    public let executableRelativePath: String
    public let launchArguments: [String]
    public let spatialRenderScale: Float
    /// Values are intentionally omitted; environment values can contain secrets.
    public let environmentVariableNames: [String]

    public init(
        gameID: String,
        gameTitle: String,
        profileID: String?,
        profileName: String,
        backend: WindowsRuntimeBackend,
        graphics: WindowsGraphicsAPI,
        executableRelativePath: String,
        launchArguments: [String],
        environment: [String: String],
        spatialRenderScale: Float = 1
    ) {
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.profileID = profileID
        self.profileName = profileName
        self.backend = backend.rawValue
        self.graphics = graphics.rawValue
        self.executableRelativePath = executableRelativePath
        self.launchArguments = launchArguments
        self.spatialRenderScale = spatialRenderScale
        self.environmentVariableNames = environment.keys.sorted()
    }
}

public struct WindowsVRCapabilityAssessment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let status: String
    public let reason: String

    public init(id: String, status: String, reason: String) {
        self.id = id
        self.status = status
        self.reason = reason
    }
}

public struct WindowsVRWineStatus: Codable, Sendable, Equatable {
    public let stateCode: Int32?
    public let state: String
    public let detail: String?

    public init(stateCode: Int32?, state: String, detail: String?) {
        self.stateCode = stateCode
        self.state = state
        self.detail = detail
    }
}

/// Snapshot of the native compositor ABI's queue counters. These counters are
/// advisory and must not be interpreted as game readiness or rendering proof.
public struct WindowsVRCompositorCounters: Codable, Sendable, Equatable {
    public let abiVersion: UInt32?
    public let submittedFrames: UInt64?
    public let acquiredFrames: UInt64?
    public let droppedFrames: UInt64?
    public let completedFrames: UInt64?
    public let queuedFrames: UInt32?
    public let capturedAt: Date

    public init(
        abiVersion: UInt32?,
        submittedFrames: UInt64?,
        acquiredFrames: UInt64?,
        droppedFrames: UInt64?,
        completedFrames: UInt64?,
        queuedFrames: UInt32?,
        capturedAt: Date = Date()
    ) {
        self.abiVersion = abiVersion
        self.submittedFrames = submittedFrames
        self.acquiredFrames = acquiredFrames
        self.droppedFrames = droppedFrames
        self.completedFrames = completedFrames
        self.queuedFrames = queuedFrames
        self.capturedAt = capturedAt
    }
}

public struct WindowsVRUnmeasuredMetric: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let value: String
    public let unit: String
    public let reason: String

    public init(id: String, unit: String, reason: String) {
        self.id = id
        self.value = "unknown / not measured"
        self.unit = unit
        self.reason = reason
    }
}

/// A versioned, honest record of the selected request and available evidence.
public struct WindowsVRCompatibilityReport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let deviceModel: String
    public let operatingSystemName: String
    public let operatingSystemVersion: String
    public let operatingSystemBuildDescription: String
    public let requestedProfile: WindowsVRRequestedProfile
    public let runtimePluginAvailable: Bool
    public let wineStatus: WindowsVRWineStatus
    public let compositorCounters: WindowsVRCompositorCounters?
    public let capabilities: [WindowsVRCapabilityAssessment]
    public let unmeasuredMetrics: [WindowsVRUnmeasuredMetric]
    public let interpretation: String

    public init(
        generatedAt: Date = Date(),
        deviceModel: String,
        operatingSystemName: String,
        operatingSystemVersion: String,
        operatingSystemBuildDescription: String,
        requestedProfile: WindowsVRRequestedProfile,
        runtimePluginAvailable: Bool,
        wineStatus: WindowsVRWineStatus,
        compositorCounters: WindowsVRCompositorCounters?,
        capabilities: [WindowsVRCapabilityAssessment]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.deviceModel = deviceModel
        self.operatingSystemName = operatingSystemName
        self.operatingSystemVersion = operatingSystemVersion
        self.operatingSystemBuildDescription = operatingSystemBuildDescription
        self.requestedProfile = requestedProfile
        self.runtimePluginAvailable = runtimePluginAvailable
        self.wineStatus = wineStatus
        self.compositorCounters = compositorCounters
        self.capabilities = capabilities
        self.unmeasuredMetrics = [
            .init(id: "simulationRate", unit: "frames/second", reason: "No guest simulation telemetry is connected."),
            .init(id: "newlyRenderedStereoFrames", unit: "frames/second", reason: "The plugin ABI exposes no game-rendered-frame callback."),
            .init(id: "interpolatedFrames", unit: "frames/second", reason: "Frame generation is unavailable."),
            .init(id: "compositorPresentationRate", unit: "frames/second", reason: "Queue counters do not measure display presentation rate."),
            .init(id: "cpuFrameTime", unit: "milliseconds", reason: "No guest CPU timing instrumentation is connected."),
            .init(id: "gpuFrameTime", unit: "milliseconds", reason: "No per-game GPU timing instrumentation is connected."),
            .init(id: "missedDeadlines", unit: "count", reason: "No compositor deadline telemetry is exposed by the current ABI."),
            .init(id: "inputToDisplayLatency", unit: "milliseconds", reason: "No end-to-end input latency measurement is connected."),
            .init(id: "memoryUse", unit: "bytes", reason: "No per-session memory telemetry is connected."),
            .init(id: "startupCompilation", unit: "seconds", reason: "No repeatable startup-compilation measurement was collected."),
            .init(id: "sustainedThermalBehavior", unit: "observation", reason: "No sustained gameplay session was measured."),
            .init(id: "nativePerformanceComparison", unit: "comparison", reason: "No equivalent native build and matched-scene baseline is available.")
        ]
        self.interpretation = "Launch acceptance and Wine process status do not establish game readiness, VR rendering, compatibility, or performance. Compositor counters are advisory queue diagnostics only."
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
