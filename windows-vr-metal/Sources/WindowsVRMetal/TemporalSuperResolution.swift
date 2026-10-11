#if !os(visionOS)
import Foundation
import Metal
import MetalFX

/// The fixed texture contract used to construct one temporal scaler per eye.
///
/// Dimensions describe a uniform, non-foveated raster. Callers that receive
/// variable-rate or otherwise nonuniformly rasterized input must resolve it to
/// a uniform image before passing textures to this adapter.
public struct TemporalSuperResolutionConfiguration {
    public let inputWidth: Int
    public let inputHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let colorFormat: MTLPixelFormat
    public let depthFormat: MTLPixelFormat
    public let motionFormat: MTLPixelFormat
    public let outputFormat: MTLPixelFormat
    public let autoExposureEnabled: Bool

    public init(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat,
        motionFormat: MTLPixelFormat,
        outputFormat: MTLPixelFormat,
        autoExposureEnabled: Bool = false
    ) throws {
        guard inputWidth > 0, inputHeight > 0,
              outputWidth > 0, outputHeight > 0,
              outputWidth >= inputWidth, outputHeight >= inputHeight else {
            throw TemporalSuperResolutionError.invalidDimensions
        }

        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.colorFormat = colorFormat
        self.depthFormat = depthFormat
        self.motionFormat = motionFormat
        self.outputFormat = outputFormat
        self.autoExposureEnabled = autoExposureEnabled
    }
}

/// Per-eye temporal inputs. Motion vectors must describe this eye's current
/// input-resolution raster and follow the MetalFX coordinate convention.
public struct TemporalSuperResolutionFrame {
    public let color: any MTLTexture
    public let depth: any MTLTexture
    public let motion: any MTLTexture
    public let output: any MTLTexture
    public let exposure: (any MTLTexture)?
    public let jitterX: Float
    public let jitterY: Float
    public let motionScaleX: Float
    public let motionScaleY: Float
    public let depthIsReversed: Bool
    public let resetHistory: Bool

    public init(
        color: any MTLTexture,
        depth: any MTLTexture,
        motion: any MTLTexture,
        output: any MTLTexture,
        exposure: (any MTLTexture)? = nil,
        jitterX: Float,
        jitterY: Float,
        motionScaleX: Float,
        motionScaleY: Float,
        depthIsReversed: Bool,
        resetHistory: Bool = false
    ) {
        self.color = color
        self.depth = depth
        self.motion = motion
        self.output = output
        self.exposure = exposure
        self.jitterX = jitterX
        self.jitterY = jitterY
        self.motionScaleX = motionScaleX
        self.motionScaleY = motionScaleY
        self.depthIsReversed = depthIsReversed
        self.resetHistory = resetHistory
    }
}

public enum TemporalSuperResolutionError: Error, Equatable {
    case notOptedIn
    case temporalScalingUnsupported
    case scalerCreationFailed
    case invalidDimensions
    case invalidFrameValues
    case textureTypeMismatch
    case textureDimensionsMismatch
    case textureFormatMismatch
    case outputAliasesInput
    case exposureTextureMismatch
    case exposureModeMismatch
    case textureUsageMismatch
    case deviceMismatch
    case eyeRoutingUnavailable
}

/// Native MetalFX temporal super-resolution endpoint for a Windows graphics
/// translation layer. Opt-in is explicit and each eye owns independent scaler
/// history. This type does not install or emulate an NGX DLL.
public final class StereoTemporalSuperResolution {
    private let device: any MTLDevice
    private let configuration: TemporalSuperResolutionConfiguration
    private let left: any MTLFXTemporalScaler
    private let right: any MTLFXTemporalScaler
    private let encodeLock = NSLock()
    private var hasEncodedLeft = false
    private var hasEncodedRight = false

    /// Creates left and right scaler instances with separate temporal histories.
    /// The caller must explicitly pass `enabled: true` to opt in.
    public init(
        device: any MTLDevice,
        configuration: TemporalSuperResolutionConfiguration,
        enabled: Bool,
        eyeRoutingAvailable: Bool
    ) throws {
        guard enabled else {
            throw TemporalSuperResolutionError.notOptedIn
        }
        guard eyeRoutingAvailable else {
            throw TemporalSuperResolutionError.eyeRoutingUnavailable
        }
        guard MTLFXTemporalScalerDescriptor.supportsDevice(device) else {
            throw TemporalSuperResolutionError.temporalScalingUnsupported
        }

        self.device = device
        self.configuration = configuration
        self.left = try Self.makeScaler(device: device, configuration: configuration)
        self.right = try Self.makeScaler(device: device, configuration: configuration)
    }

    /// Encodes one eye's temporal scaling operation into the caller's command
    /// buffer. The caller owns command submission, resource lifetime, and frame
    /// ordering, and must call this independently for left and right eyes.
    public func encode(
        eye: Eye,
        frame: TemporalSuperResolutionFrame,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        encodeLock.lock()
        defer { encodeLock.unlock() }

        try validate(frame)
        guard ObjectIdentifier(commandBuffer.commandQueue.device as AnyObject)
                == ObjectIdentifier(device as AnyObject) else {
            throw TemporalSuperResolutionError.deviceMismatch
        }

        let scaler = eye == .left ? left : right
        let needsInitialReset = eye == .left ? !hasEncodedLeft : !hasEncodedRight

        scaler.colorTexture = frame.color
        scaler.depthTexture = frame.depth
        scaler.motionTexture = frame.motion
        scaler.outputTexture = frame.output
        scaler.exposureTexture = configuration.autoExposureEnabled ? nil : frame.exposure
        scaler.inputContentWidth = configuration.inputWidth
        scaler.inputContentHeight = configuration.inputHeight
        scaler.jitterOffsetX = frame.jitterX
        scaler.jitterOffsetY = frame.jitterY
        scaler.motionVectorScaleX = frame.motionScaleX
        scaler.motionVectorScaleY = frame.motionScaleY
        scaler.isDepthReversed = frame.depthIsReversed
        scaler.reset = frame.resetHistory || needsInitialReset
        scaler.encode(commandBuffer: commandBuffer)

        if eye == .left {
            hasEncodedLeft = true
        } else {
            hasEncodedRight = true
        }
    }

    public enum Eye: Sendable {
        case left
        case right
    }

    private static func makeScaler(
        device: any MTLDevice,
        configuration: TemporalSuperResolutionConfiguration
    ) throws -> any MTLFXTemporalScaler {
        let descriptor = MTLFXTemporalScalerDescriptor()
        descriptor.inputWidth = configuration.inputWidth
        descriptor.inputHeight = configuration.inputHeight
        descriptor.outputWidth = configuration.outputWidth
        descriptor.outputHeight = configuration.outputHeight
        descriptor.colorTextureFormat = configuration.colorFormat
        descriptor.depthTextureFormat = configuration.depthFormat
        descriptor.motionTextureFormat = configuration.motionFormat
        descriptor.outputTextureFormat = configuration.outputFormat
        descriptor.isAutoExposureEnabled = configuration.autoExposureEnabled
        guard let scaler = descriptor.makeTemporalScaler(device: device) else {
            throw TemporalSuperResolutionError.scalerCreationFailed
        }
        return scaler
    }

    private func validate(_ frame: TemporalSuperResolutionFrame) throws {
        let values = [
            frame.jitterX,
            frame.jitterY,
            frame.motionScaleX,
            frame.motionScaleY
        ]
        guard values.allSatisfy(\.isFinite) else {
            throw TemporalSuperResolutionError.invalidFrameValues
        }

        let inputTextures = [frame.color, frame.depth, frame.motion]
        guard inputTextures.allSatisfy({ $0.textureType == .type2D && $0.sampleCount == 1 }),
              frame.output.textureType == .type2D,
              frame.output.sampleCount == 1,
              frame.exposure.map({ $0.textureType == .type2D && $0.sampleCount == 1 }) ?? true else {
            throw TemporalSuperResolutionError.textureTypeMismatch
        }

        guard inputTextures.allSatisfy({
            $0.width == configuration.inputWidth && $0.height == configuration.inputHeight
        }),
        frame.output.width == configuration.outputWidth,
        frame.output.height == configuration.outputHeight else {
            throw TemporalSuperResolutionError.textureDimensionsMismatch
        }

        guard frame.color.pixelFormat == configuration.colorFormat,
              frame.depth.pixelFormat == configuration.depthFormat,
              frame.motion.pixelFormat == configuration.motionFormat,
              frame.output.pixelFormat == configuration.outputFormat else {
            throw TemporalSuperResolutionError.textureFormatMismatch
        }

        let requiredUsages = [left.colorTextureUsage, left.depthTextureUsage, left.motionTextureUsage]
        for (texture, requiredUsage) in zip(inputTextures, requiredUsages) {
            guard texture.usage.contains(requiredUsage) else {
                throw TemporalSuperResolutionError.textureUsageMismatch
            }
        }
        guard frame.output.usage.contains(left.outputTextureUsage) else {
            throw TemporalSuperResolutionError.textureUsageMismatch
        }

        let allTextures = inputTextures + [frame.output] + (frame.exposure.map { [$0] } ?? [])
        guard allTextures.allSatisfy({
            ObjectIdentifier($0.device as AnyObject) == ObjectIdentifier(device as AnyObject)
        }) else {
            throw TemporalSuperResolutionError.deviceMismatch
        }

        let outputIdentity = resourceIdentity(frame.output)
        let allInputs = inputTextures + (frame.exposure.map { [$0] } ?? [])
        guard allInputs.allSatisfy({ resourceIdentity($0) != outputIdentity }) else {
            throw TemporalSuperResolutionError.outputAliasesInput
        }

        if configuration.autoExposureEnabled {
            guard frame.exposure == nil else {
                throw TemporalSuperResolutionError.exposureModeMismatch
            }
        } else {
            guard let exposure = frame.exposure else {
                throw TemporalSuperResolutionError.exposureModeMismatch
            }
            guard exposure.width == 1, exposure.height == 1,
                  exposure.pixelFormat == .r16Float else {
                throw TemporalSuperResolutionError.exposureTextureMismatch
            }
        }
    }

    private func resourceIdentity(_ texture: any MTLTexture) -> ObjectIdentifier {
        if let root = texture.rootResource {
            return ObjectIdentifier(root as AnyObject)
        }
        return ObjectIdentifier(texture as AnyObject)
    }
}
#endif
