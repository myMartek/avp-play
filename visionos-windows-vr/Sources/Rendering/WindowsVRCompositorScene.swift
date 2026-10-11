import ARKit
import CompositorServices
import Metal
import QuartzCore
import SwiftUI
import simd

/// Add this scene to the app's SceneBuilder to provide a compositor-backed
/// immersive destination for GPU frames submitted through the native bridge.
@available(visionOS 1.0, *)
struct WindowsVRCompositorScene: Scene {
    static let identifier = "WindowsVRCompositor"
    private let model: LauncherModel

    init(model: LauncherModel) {
        self.model = model
    }

    var body: some Scene {
        ImmersiveSpace(id: Self.identifier) {
            CompositorLayer(configuration: WindowsVRCompositorConfiguration()) { layerRenderer in
                let transfer = WindowsVRLayerRendererTransfer(renderer: layerRenderer)
                Task.detached(executorPreference: WindowsVRRenderTaskExecutor.shared) {
                    if #available(visionOS 26.0, *) {
                        let renderer = WindowsVRCompositorRenderer(layerRenderer: transfer.renderer)
                        await renderer.run()
                    }
                }
            }
            .onDisappear {
                Task { await model.immersiveSpaceDidClose() }
            }
        }
    }
}

// CompositorLayer hands renderer ownership to this dedicated rendering task.
// The UI never accesses it after transfer; all renderer use stays on the
// serial executor rather than inheriting SwiftUI's main actor.
private struct WindowsVRLayerRendererTransfer: @unchecked Sendable {
    let renderer: LayerRenderer
}

/// Guest frames use a uniform eye raster today. Keep foveation disabled until
/// the guest render pass consumes Apple's rasterization-rate maps. Dedicated
/// textures are preferred; the target mapper also handles layered eye slices.
@available(visionOS 1.0, *)
private struct WindowsVRCompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(
        capabilities: LayerRenderer.Capabilities,
        configuration: inout LayerRenderer.Configuration
    ) {
        let layouts = capabilities.supportedLayouts(options: [])
        if layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else if layouts.contains(.layered) {
            configuration.layout = .layered
        }
        configuration.isFoveationEnabled = false
        // The compositor bridge clears render targets and copies game frames
        // into them. Keep the layer textures usable for those Metal operations.
        configuration.colorUsage = [.renderTarget, .shaderRead]
    }
}

/// Compositor Services requires a dedicated render thread. This serial executor
/// keeps all access to LayerRenderer on one user-interactive queue.
private final class WindowsVRRenderTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.avpplay.windows-vr.compositor", qos: .userInteractive)
    static let shared = WindowsVRRenderTaskExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async {
            unownedJob.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }

    nonisolated func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

@available(visionOS 1.0, *)
@available(visionOS 26.0, *)
private final class WindowsVRCompositorRenderer {
    private let layerRenderer: LayerRenderer
    private let metalCommandQueue: MTLCommandQueue?
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let controllerTracking = WindowsVRControllerProvider()
    private let compositorClock = LayerRenderer.Clock()

    init(layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.metalCommandQueue = layerRenderer.device.makeCommandQueue()
    }

    func run() async {
        let deviceObject = layerRenderer.device as AnyObject
        let bindStatus = wvr_compositor_bind_metal_device_v1(Unmanaged.passUnretained(deviceObject).toOpaque())
        guard bindStatus == 0 else { return }

        // If permission or tracking is unavailable, output frames can still be
        // presented, while the shared ABI reports that the device pose is invalid.
        do {
            let authorization = await arSession.requestAuthorization(for: [.worldSensing, .accessoryTracking])
            let controllerProviders = await controllerTracking.configure(
                authorized: authorization[.accessoryTracking] == .allowed
            )
            var providers: [any DataProvider] = [worldTracking]
            providers.append(contentsOf: controllerProviders)
            try await arSession.run(providers)
        } catch {
            publishUnavailablePose()
        }

        while true {
            switch layerRenderer.state {
            case .paused:
                layerRenderer.waitUntilRunning()
            case .running:
                renderNextFrame()
            case .invalidated:
                arSession.stop()
                publishUnavailablePose()
                return
            @unknown default:
                arSession.stop()
                publishUnavailablePose()
                return
            }
        }
    }

    private func renderNextFrame() {
        guard let frame = layerRenderer.queryNextFrame(),
              let predictedTiming = frame.predictTiming()
        else {
            Thread.sleep(forTimeInterval: 0.001)
            return
        }

        frame.startUpdate()
        frame.endUpdate()
        compositorClock.wait(until: predictedTiming.optimalInputTime, tolerance: nil)
        frame.startSubmission()

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else {
            frame.endSubmission()
            return
        }

        for drawable in drawables {
            publishTargets(for: drawable)
            publishFrameTracking(for: drawable)
            render(drawable)
        }
        frame.endSubmission()
    }

    private func target(for drawable: LayerRenderer.Drawable, viewIndex: Int) -> EyeTarget? {
        guard drawable.views.indices.contains(viewIndex) else { return nil }
        let map = drawable.views[viewIndex].textureMap
        guard drawable.colorTextures.indices.contains(map.textureIndex) else { return nil }
        let texture = drawable.colorTextures[map.textureIndex]
        let viewport = map.viewport
        let width = UInt32(max(0, Int(viewport.width.rounded(.down))))
        let height = UInt32(max(0, Int(viewport.height.rounded(.down))))
        guard width > 0, height > 0 else { return nil }
        return EyeTarget(
            texture: texture,
            slice: map.sliceIndex,
            originX: Int(viewport.originX.rounded(.down)),
            originY: Int(viewport.originY.rounded(.down)),
            width: width,
            height: height,
            pixelFormat: UInt32(texture.pixelFormat.rawValue)
        )
    }

    private func publishTargets(for drawable: LayerRenderer.Drawable) {
        guard drawable.views.count == 2,
              let view0 = target(for: drawable, viewIndex: 0),
              let view1 = target(for: drawable, viewIndex: 1)
        else { return }

        _ = wvr_compositor_publish_targets_v1(
            view0.width, view0.height, view0.pixelFormat,
            view1.width, view1.height, view1.pixelFormat
        )
    }

    private func publishFrameTracking(for drawable: LayerRenderer.Drawable) {
        guard drawable.views.count == 2 else {
            publishUnavailablePose()
            return
        }

        let targetTime = drawable.frameTiming.trackableAnchorTime
        let delta = compositorClock.now.duration(to: targetTime)
        let components = delta.components
        let deltaSeconds = Double(components.seconds) + Double(components.attoseconds) / 1.0e18
        let targetTimestamp = CACurrentMediaTime() + deltaSeconds
        controllerTracking.publishPredictedState(at: targetTimestamp)
        let anchor = worldTracking.queryDeviceAnchor(atTimestamp: targetTimestamp)
        let isTracked = anchor?.isTracked == true
        if isTracked, let anchor {
            drawable.deviceAnchor = anchor
        }
        let originFromDevice = isTracked ? anchor!.originFromAnchorTransform : matrix_identity_float4x4

        var deviceFromEye: [Float] = []
        var projections: [Float] = []
        var frustumTangents: [Float] = []
        for viewIndex in 0..<2 {
            let view = drawable.views[viewIndex]
            appendMatrix(view.transform, to: &deviceFromEye)
            appendMatrix(drawable.computeProjection(convention: .rightUpBack, viewIndex: viewIndex), to: &projections)

            // The runtime needs OpenVR's off-axis eye angles as well as the
            // projection matrix; Apple currently exposes these as four tangents.
            let fov = view.tangents
            frustumTangents.append(contentsOf: [fov.x, fov.y, fov.z, fov.w])
        }
        let depthRange = drawable.depthRange
        let headValues = matrixValues(originFromDevice)
        let depthValues = [depthRange.x, depthRange.y]
        let flags: UInt32 = isTracked ? 0b11 : 0

        headValues.withUnsafeBufferPointer { headBuffer in
            deviceFromEye.withUnsafeBufferPointer { eyeBuffer in
                projections.withUnsafeBufferPointer { projectionBuffer in
                    frustumTangents.withUnsafeBufferPointer { tangentBuffer in
                        depthValues.withUnsafeBufferPointer { depthBuffer in
                            _ = wvr_compositor_publish_frame_tracking_v1(
                                UInt64(max(0, targetTimestamp * 1.0e9)), flags,
                                headBuffer.baseAddress, eyeBuffer.baseAddress,
                                projectionBuffer.baseAddress, tangentBuffer.baseAddress,
                                depthBuffer.baseAddress
                            )
                        }
                    }
                }
            }
        }
    }

    private func publishUnavailablePose(timestamp: TimeInterval = CACurrentMediaTime()) {
        let identity = matrixValues(matrix_identity_float4x4)
        let eyes = identity + identity
        let projections = identity + identity
        let tangents = [Float](repeating: 0, count: 8)
        let depth = [Float](repeating: 0, count: 2)
        identity.withUnsafeBufferPointer { headBuffer in
            eyes.withUnsafeBufferPointer { eyeBuffer in
                projections.withUnsafeBufferPointer { projectionBuffer in
                    tangents.withUnsafeBufferPointer { tangentBuffer in
                        depth.withUnsafeBufferPointer { depthBuffer in
                            _ = wvr_compositor_publish_frame_tracking_v1(
                                UInt64(max(0, timestamp * 1.0e9)), 0,
                                headBuffer.baseAddress, eyeBuffer.baseAddress,
                                projectionBuffer.baseAddress, tangentBuffer.baseAddress,
                                depthBuffer.baseAddress
                            )
                        }
                    }
                }
            }
        }
    }

    private func render(_ drawable: LayerRenderer.Drawable) {
        guard let commandBuffer = metalCommandQueue?.makeCommandBuffer() else { return }

        var acquired = WVRAcquiredStereoFrameV1()
        acquired.structSize = UInt32(MemoryLayout<WVRAcquiredStereoFrameV1>.size)
        let acquireStatus = withUnsafeMutablePointer(to: &acquired) {
            wvr_compositor_acquire_latest_stereo_frame_v1($0)
        }
        let hasFrame = acquireStatus == 0 && acquired.lease != nil

        var leftTexture: (any MTLTexture)?
        var rightTexture: (any MTLTexture)?
        var readyEvent: (any MTLSharedEvent)?
        if hasFrame,
           let leftPointer = acquired.leftTexture,
           let rightPointer = acquired.rightTexture,
           let eventPointer = acquired.producerReadyEvent {
            leftTexture = Unmanaged<AnyObject>.fromOpaque(leftPointer).takeUnretainedValue() as? any MTLTexture
            rightTexture = Unmanaged<AnyObject>.fromOpaque(rightPointer).takeUnretainedValue() as? any MTLTexture
            readyEvent = Unmanaged<AnyObject>.fromOpaque(eventPointer).takeUnretainedValue() as? any MTLSharedEvent
        }

        let targets = (0..<drawable.views.count).compactMap { target(for: drawable, viewIndex: $0) }
        let sources = [leftTexture, rightTexture]
        let matchesTarget = hasFrame && drawable.views.count == 2 && targets.count == 2 &&
            sources.count == 2 && sources.allSatisfy { $0 != nil } && readyEvent != nil &&
            targets.indices.allSatisfy { index in
                guard let source = sources[index] else { return false }
                return source.width == Int(targets[index].width) &&
                       source.height == Int(targets[index].height) &&
                       source.pixelFormat == targets[index].texture.pixelFormat &&
                       source.device === layerRenderer.device
            }

        if matchesTarget, let readyEvent {
            commandBuffer.encodeWaitForEvent(readyEvent, value: acquired.producerReadyValue)
            for index in 0..<2 {
                guard let source = sources[index] else { continue }
                let target = targets[index]
                guard let blit = commandBuffer.makeBlitCommandEncoder() else { continue }
                blit.copy(
                    from: source,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: Int(target.width), height: Int(target.height), depth: 1),
                    to: target.texture,
                    destinationSlice: target.slice,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: target.originX, y: target.originY, z: 0)
                )
                blit.endEncoding()
            }
        } else {
            // An absent/stale/mismatched game frame becomes black compositor
            // output. No substitute scene or test pattern is drawn.
            for target in targets {
                clear(target, on: commandBuffer)
            }
        }

        // No guest composition-depth extension is implemented. Initialize
        // reverse-Z depth to the far plane rather than presenting undefined
        // memory; this does not provide depth-correct positional reprojection.
        for texture in drawable.depthTextures {
            for slice in 0..<texture.arrayLength {
                let pass = MTLRenderPassDescriptor()
                pass.depthAttachment.texture = texture
                pass.depthAttachment.slice = slice
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 0
                commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            }
        }
        drawable.encodePresent(commandBuffer: commandBuffer)
        if let lease = acquired.lease {
            // The native bridge owns this lease until the completion callback.
            // Capture its address as a Sendable value across Metal's callback.
            let leaseAddress = UInt(bitPattern: lease)
            commandBuffer.addCompletedHandler { _ in
                wvr_compositor_release_acquired_frame_v1(UnsafeMutableRawPointer(bitPattern: leaseAddress))
            }
        }
        commandBuffer.commit()
    }

    private func clear(_ target: EyeTarget, on commandBuffer: any MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        let attachment = descriptor.colorAttachments[0]
        attachment?.texture = target.texture
        attachment?.slice = target.slice
        attachment?.level = 0
        attachment?.loadAction = .clear
        attachment?.storeAction = .store
        attachment?.clearColor = MTLClearColorMake(0, 0, 0, 1)
        commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
    }

    private func appendMatrix(_ matrix: simd_float4x4, to values: inout [Float]) {
        values.append(contentsOf: matrixValues(matrix))
    }

    private func matrixValues(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }
}

@available(visionOS 1.0, *)
private struct EyeTarget {
    let texture: any MTLTexture
    let slice: Int
    let originX: Int
    let originY: Int
    let width: UInt32
    let height: UInt32
    let pixelFormat: UInt32
}
