import Foundation

public enum WindowsVRFrameContractError: Error, LocalizedError, Sendable, Equatable {
    case invalidEyeSize(WindowsVREye)
    case incorrectEyeAssignment
    case invalidDepthMetadata
    case invalidMotionMetadata

    public var errorDescription: String? {
        switch self {
        case .invalidEyeSize(let eye):
            return "The \(eye.rawValue) eye frame size must be positive."
        case .incorrectEyeAssignment:
            return "Frame metadata must assign left and right eye data to the matching eyes."
        case .invalidDepthMetadata:
            return "Depth metadata must use finite, positive near and far distances with far greater than near."
        case .invalidMotionMetadata:
            return "Motion metadata must use a finite, positive frame interval."
        }
    }
}

public struct PixelSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum WindowsVREye: String, Sendable, Equatable {
    case left
    case right
}

public enum DepthEncoding: String, Sendable, Equatable {
    case linearMeters
    case deviceDepth
    case reversedDeviceDepth
}

public struct DepthFrameMetadata: Sendable, Equatable {
    public let encoding: DepthEncoding
    public let nearMeters: Float
    public let farMeters: Float

    public init(encoding: DepthEncoding, nearMeters: Float, farMeters: Float) {
        self.encoding = encoding
        self.nearMeters = nearMeters
        self.farMeters = farMeters
    }
}

public enum MotionVectorSpace: String, Sendable, Equatable {
    case normalizedUV
    case pixels
}

public struct MotionFrameMetadata: Sendable, Equatable {
    public let coordinateSpace: MotionVectorSpace
    /// Time between the current and previous rendered frames, in seconds.
    public let frameDeltaSeconds: Float
    /// Vectors point from the current pixel to its location in the previous frame.
    public let direction: MotionVectorDirection

    public init(
        coordinateSpace: MotionVectorSpace,
        frameDeltaSeconds: Float,
        direction: MotionVectorDirection = .currentToPrevious
    ) {
        self.coordinateSpace = coordinateSpace
        self.frameDeltaSeconds = frameDeltaSeconds
        self.direction = direction
    }
}

public enum MotionVectorDirection: String, Sendable, Equatable {
    case currentToPrevious
}

public struct TemporalJitterMetadata: Sendable, Equatable {
    /// Projection jitter in pixel units for this eye's current frame.
    public let xPixels: Float
    public let yPixels: Float

    public init(xPixels: Float, yPixels: Float) {
        self.xPixels = xPixels
        self.yPixels = yPixels
    }
}

public struct PerEyeFrameMetadata: Sendable, Equatable {
    public let eye: WindowsVREye
    public let size: PixelSize
    public let depth: DepthFrameMetadata?
    public let motion: MotionFrameMetadata?
    public let temporalJitter: TemporalJitterMetadata?

    public init(
        eye: WindowsVREye,
        size: PixelSize,
        depth: DepthFrameMetadata? = nil,
        motion: MotionFrameMetadata? = nil,
        temporalJitter: TemporalJitterMetadata? = nil
    ) {
        self.eye = eye
        self.size = size
        self.depth = depth
        self.motion = motion
        self.temporalJitter = temporalJitter
    }

    public func validate() throws {
        guard size.width > 0, size.height > 0 else {
            throw WindowsVRFrameContractError.invalidEyeSize(eye)
        }
        if let depth {
            guard depth.nearMeters.isFinite, depth.farMeters.isFinite,
                  depth.nearMeters > 0, depth.farMeters > depth.nearMeters
            else {
                throw WindowsVRFrameContractError.invalidDepthMetadata
            }
        }
        if let motion {
            guard motion.frameDeltaSeconds.isFinite, motion.frameDeltaSeconds > 0 else {
                throw WindowsVRFrameContractError.invalidMotionMetadata
            }
        }
        if let temporalJitter,
           (!temporalJitter.xPixels.isFinite || !temporalJitter.yPixels.isFinite) {
            throw WindowsVRFrameContractError.invalidMotionMetadata
        }
    }
}

public struct WindowsVRFrameMetadata: Sendable, Equatable {
    public let leftEye: PerEyeFrameMetadata
    public let rightEye: PerEyeFrameMetadata

    public init(leftEye: PerEyeFrameMetadata, rightEye: PerEyeFrameMetadata) {
        self.leftEye = leftEye
        self.rightEye = rightEye
    }

    public func validate() throws {
        guard leftEye.eye == .left, rightEye.eye == .right else {
            throw WindowsVRFrameContractError.incorrectEyeAssignment
        }
        try leftEye.validate()
        try rightEye.validate()
    }
}

/// Declares optional translation behavior for a future graphics adapter.
public struct WindowsVRUpscalerOptions: Codable, Sendable, Equatable {
    /// Opt in to mapping a game's DLSS super-resolution request to MetalFX temporal scaling.
    public let mapDLSSSuperResolutionToMetalFXTemporalScaling: Bool

    /// Frame generation has no adapter and is unavailable in this contract.
    public var frameGenerationEnabled: Bool { false }
    /// Foveation has no adapter and is unavailable in this contract.
    public var foveationEnabled: Bool { false }

    public init(mapDLSSSuperResolutionToMetalFXTemporalScaling: Bool = false) {
        self.mapDLSSSuperResolutionToMetalFXTemporalScaling = mapDLSSSuperResolutionToMetalFXTemporalScaling
    }
}
