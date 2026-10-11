import Metal
import MetalFX
import WindowsVRMetalABI

#if !os(visionOS)
private func bridgedObject(_ pointer: UnsafeMutableRawPointer?) -> AnyObject? {
    guard let pointer else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}

private func statusForCreationError(_ error: Error) -> Int32 {
    guard let error = error as? TemporalSuperResolutionError else {
        return Int32(WVRMetalFXStatusCreationFailed.rawValue)
    }
    switch error {
    case .notOptedIn, .eyeRoutingUnavailable, .temporalScalingUnsupported:
        return Int32(WVRMetalFXStatusUnsupported.rawValue)
    case .scalerCreationFailed:
        return Int32(WVRMetalFXStatusCreationFailed.rawValue)
    default:
        return Int32(WVRMetalFXStatusInvalidArgument.rawValue)
    }
}

@_cdecl("WVRMetalFXSRCreateV1")
public func wvrMetalFXSRCreateV1(
    _ metalDevicePointer: UnsafeMutableRawPointer?,
    _ inputWidth: UInt32,
    _ inputHeight: UInt32,
    _ outputWidth: UInt32,
    _ outputHeight: UInt32,
    _ colorFormatRaw: UInt32,
    _ depthFormatRaw: UInt32,
    _ motionFormatRaw: UInt32,
    _ outputFormatRaw: UInt32,
    _ autoExposureEnabled: UInt8,
    _ optInEnabled: UInt8,
    _ eyeRoutingAvailable: UInt8,
    _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 {
    guard let outHandle else {
        return Int32(WVRMetalFXStatusInvalidArgument.rawValue)
    }
    outHandle.pointee = nil

    guard let object = bridgedObject(metalDevicePointer),
          let device = object as? any MTLDevice,
          let colorFormat = MTLPixelFormat(rawValue: UInt(colorFormatRaw)),
          let depthFormat = MTLPixelFormat(rawValue: UInt(depthFormatRaw)),
          let motionFormat = MTLPixelFormat(rawValue: UInt(motionFormatRaw)),
          let outputFormat = MTLPixelFormat(rawValue: UInt(outputFormatRaw)) else {
        return Int32(WVRMetalFXStatusInvalidArgument.rawValue)
    }

    do {
        let configuration = try TemporalSuperResolutionConfiguration(
            inputWidth: Int(inputWidth),
            inputHeight: Int(inputHeight),
            outputWidth: Int(outputWidth),
            outputHeight: Int(outputHeight),
            colorFormat: colorFormat,
            depthFormat: depthFormat,
            motionFormat: motionFormat,
            outputFormat: outputFormat,
            autoExposureEnabled: autoExposureEnabled != 0
        )
        let adapter = try StereoTemporalSuperResolution(
            device: device,
            configuration: configuration,
            enabled: optInEnabled != 0,
            eyeRoutingAvailable: eyeRoutingAvailable != 0
        )
        outHandle.pointee = Unmanaged.passRetained(adapter).toOpaque()
        return Int32(WVRMetalFXStatusSuccess.rawValue)
    } catch {
        return statusForCreationError(error)
    }
}

@_cdecl("WVRMetalFXSREncodeV1")
public func wvrMetalFXSREncodeV1(
    _ handle: UnsafeMutableRawPointer?,
    _ eyeRaw: UInt32,
    _ colorPointer: UnsafeMutableRawPointer?,
    _ depthPointer: UnsafeMutableRawPointer?,
    _ motionPointer: UnsafeMutableRawPointer?,
    _ outputPointer: UnsafeMutableRawPointer?,
    _ exposurePointer: UnsafeMutableRawPointer?,
    _ commandBufferPointer: UnsafeMutableRawPointer?,
    _ jitterX: Float,
    _ jitterY: Float,
    _ motionScaleX: Float,
    _ motionScaleY: Float,
    _ depthIsReversed: UInt8,
    _ resetHistory: UInt8
) -> Int32 {
    guard let handle,
          eyeRaw == UInt32(WVRMetalFXEyeLeft.rawValue)
            || eyeRaw == UInt32(WVRMetalFXEyeRight.rawValue),
          let colorObject = bridgedObject(colorPointer),
          let color = colorObject as? any MTLTexture,
          let depthObject = bridgedObject(depthPointer),
          let depth = depthObject as? any MTLTexture,
          let motionObject = bridgedObject(motionPointer),
          let motion = motionObject as? any MTLTexture,
          let outputObject = bridgedObject(outputPointer),
          let output = outputObject as? any MTLTexture,
          let commandBufferObject = bridgedObject(commandBufferPointer),
          let commandBuffer = commandBufferObject as? any MTLCommandBuffer else {
        return Int32(WVRMetalFXStatusInvalidArgument.rawValue)
    }

    let exposure: (any MTLTexture)?
    if let exposureObject = bridgedObject(exposurePointer) {
        guard let texture = exposureObject as? any MTLTexture else {
            return Int32(WVRMetalFXStatusInvalidArgument.rawValue)
        }
        exposure = texture
    } else {
        exposure = nil
    }

    let adapter = Unmanaged<StereoTemporalSuperResolution>
        .fromOpaque(handle)
        .takeUnretainedValue()
    let frame = TemporalSuperResolutionFrame(
        color: color,
        depth: depth,
        motion: motion,
        output: output,
        exposure: exposure,
        jitterX: jitterX,
        jitterY: jitterY,
        motionScaleX: motionScaleX,
        motionScaleY: motionScaleY,
        depthIsReversed: depthIsReversed != 0,
        resetHistory: resetHistory != 0
    )

    do {
        try adapter.encode(
            eye: eyeRaw == UInt32(WVRMetalFXEyeLeft.rawValue) ? .left : .right,
            frame: frame,
            commandBuffer: commandBuffer
        )
        return Int32(WVRMetalFXStatusSuccess.rawValue)
    } catch {
        return Int32(WVRMetalFXStatusFrameRejected.rawValue)
    }
}

@_cdecl("WVRMetalFXSRDestroyV1")
public func wvrMetalFXSRDestroyV1(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<StereoTemporalSuperResolution>.fromOpaque(handle).release()
}
#else
// MetalFX marks MTLFXTemporalScaler unavailable on visionOS, including the
// visionOS 27 SDK. Keep the C ABI present for hosts that link this package,
// but report unsupported instead of substituting spatial scaling or a fake SR
// implementation.
@_cdecl("WVRMetalFXSRCreateV1")
public func wvrMetalFXSRCreateV1(
    _ metalDevicePointer: UnsafeMutableRawPointer?,
    _ inputWidth: UInt32,
    _ inputHeight: UInt32,
    _ outputWidth: UInt32,
    _ outputHeight: UInt32,
    _ colorFormatRaw: UInt32,
    _ depthFormatRaw: UInt32,
    _ motionFormatRaw: UInt32,
    _ outputFormatRaw: UInt32,
    _ autoExposureEnabled: UInt8,
    _ optInEnabled: UInt8,
    _ eyeRoutingAvailable: UInt8,
    _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 {
    guard let outHandle else {
        return Int32(WVRMetalFXStatusInvalidArgument.rawValue)
    }
    outHandle.pointee = nil
    return Int32(WVRMetalFXStatusUnsupported.rawValue)
}

@_cdecl("WVRMetalFXSREncodeV1")
public func wvrMetalFXSREncodeV1(
    _ handle: UnsafeMutableRawPointer?,
    _ eyeRaw: UInt32,
    _ colorPointer: UnsafeMutableRawPointer?,
    _ depthPointer: UnsafeMutableRawPointer?,
    _ motionPointer: UnsafeMutableRawPointer?,
    _ outputPointer: UnsafeMutableRawPointer?,
    _ exposurePointer: UnsafeMutableRawPointer?,
    _ commandBufferPointer: UnsafeMutableRawPointer?,
    _ jitterX: Float,
    _ jitterY: Float,
    _ motionScaleX: Float,
    _ motionScaleY: Float,
    _ depthIsReversed: UInt8,
    _ resetHistory: UInt8
) -> Int32 {
    Int32(WVRMetalFXStatusUnsupported.rawValue)
}

@_cdecl("WVRMetalFXSRDestroyV1")
public func wvrMetalFXSRDestroyV1(_ handle: UnsafeMutableRawPointer?) {}
#endif
