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
                let task = Task.detached(executorPreference: WindowsVRRenderTaskExecutor.shared) {
                    if #available(visionOS 26.0, *) {
                        let renderer = WindowsVRCompositorRenderer(layerRenderer: transfer.renderer)
                        await renderer.run()
                    }
                }
                WindowsVRCompositorTaskStore.shared.install(task)
            }
            .onDisappear {
                WindowsVRCompositorTaskStore.shared.stop()
                Task { await model.immersiveSpaceDidClose() }
            }
        }
    }
}

private final class WindowsVRCompositorTaskStore: @unchecked Sendable {
    static let shared = WindowsVRCompositorTaskStore()
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func install(_ newTask: Task<Void, Never>) {
        let previous = lock.withLock {
            let previous = task
            task = newTask
            return previous
        }
        previous?.cancel()
    }

    func stop() {
        let running = lock.withLock {
            let running = task
            task = nil
            return running
        }
        running?.cancel()
        wvr_compositor_pause_v1()
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
        // Match the guest runtime's advertised D3D11 sRGB swapchain format.
        // The compositor default may be RGBA16Float, which this first path
        // must not accidentally advertise as an unsupported 8-bit format.
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        // The compositor bridge clears render targets, copies exact-size game
        // frames, and spatially filters lower-resolution frames into them.
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
    private let spatialLibrary: MTLLibrary?
    private let spatialSampler: MTLSamplerState?
    private var spatialPipelines: [UInt: any MTLRenderPipelineState] = [:]
    // Owned snapshots outlive a guest swapchain lease. They are updated and read
    // on the same Metal command queue, never by retaining a reusable guest image.
    private var lastEyeSnapshots: [any MTLTexture] = []
    private var snapshotGeneration: UInt64 = 0

    private static let spatialShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct WVRSpatialVertexOut {
        float4 position [[position]];
        float2 uv;
    };
    vertex WVRSpatialVertexOut wvr_spatial_vertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        const float2 coordinates[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
        WVRSpatialVertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = coordinates[vertexID];
        return out;
    }
    struct WVRSpatialSource {
        float2 origin;
        float2 extent;
        uint slice;
        uint padding;
    };
    fragment float4 wvr_spatial_fragment(
        WVRSpatialVertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        sampler linearClamp [[sampler(0)]],
        constant WVRSpatialSource& region [[buffer(0)]]) {
        float2 pixel = clamp(region.origin + in.uv * region.extent, region.origin + 0.5, region.origin + region.extent - 0.5);
        float2 uv = pixel / float2(source.get_width(), source.get_height());
        return source.sample(linearClamp, uv);
    }
    fragment float4 wvr_spatial_array_fragment(
        WVRSpatialVertexOut in [[stage_in]],
        texture2d_array<float> source [[texture(0)]],
        sampler linearClamp [[sampler(0)]],
        constant WVRSpatialSource& region [[buffer(0)]]) {
        float2 pixel = clamp(region.origin + in.uv * region.extent, region.origin + 0.5, region.origin + region.extent - 0.5);
        float2 uv = pixel / float2(source.get_width(), source.get_height());
        return source.sample(linearClamp, uv, region.slice);
    }
    """

    init(layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.metalCommandQueue = layerRenderer.device.makeCommandQueue()
        self.spatialLibrary = try? layerRenderer.device.makeLibrary(
            source: Self.spatialShaderSource,
            options: nil
        )
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        self.spatialSampler = layerRenderer.device.makeSamplerState(descriptor: samplerDescriptor)
    }

    func run() async {
        wvr_compositor_pause_v1()
        let deviceObject = layerRenderer.device as AnyObject
        let bindStatus = wvr_compositor_bind_metal_device_v1(Unmanaged.passUnretained(deviceObject).toOpaque())
        guard bindStatus == 0 else {
            wvr_compositor_pause_v1()
            return
        }

        var trackingStarted = false
        defer {
            arSession.stop()
            controllerTracking.reset()
            wvr_compositor_pause_v1()
        }

        while !Task.isCancelled {
            switch layerRenderer.state {
            case .paused:
                wvr_compositor_pause_v1()
                if trackingStarted {
                    arSession.stop()
                    controllerTracking.reset()
                    trackingStarted = false
                }
                layerRenderer.waitUntilRunning()
            case .running:
                if !trackingStarted {
                    await startTracking()
                    trackingStarted = true
                }
                renderNextFrame()
            case .invalidated:
                return
            @unknown default:
                return
            }
        }
    }

    private func startTracking() async {
        do {
            let authorization = await arSession.requestAuthorization(for: [.worldSensing, .accessoryTracking])
            let controllerProviders = await controllerTracking.configure(
                authorized: authorization[.accessoryTracking] == .allowed
            )
            var providers: [any DataProvider] = [worldTracking]
            providers.append(contentsOf: controllerProviders)
            try await arSession.run(providers)
        } catch {
            controllerTracking.reset()
            publishUnavailablePose()
        }
    }

    private func renderNextFrame() {
        guard let frame = layerRenderer.queryNextFrame(),
              let predictedTiming = frame.predictTiming()
        else {
            publishUnavailablePose()
            controllerTracking.publishUnavailableState()
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
            wvr_compositor_pause_v1()
            publishUnavailablePose()
            controllerTracking.publishUnavailableState()
            return
        }

        for drawable in drawables {
            if publishTargets(for: drawable) {
                publishFrameTracking(for: drawable)
            } else {
                wvr_compositor_pause_v1()
                publishUnavailablePose()
                controllerTracking.publishUnavailableState()
            }
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

    @discardableResult
    private func publishTargets(for drawable: LayerRenderer.Drawable) -> Bool {
        guard drawable.views.count == 2,
              let view0 = target(for: drawable, viewIndex: 0),
              let view1 = target(for: drawable, viewIndex: 1)
        else { return false }

        return wvr_compositor_publish_targets_v1(
            view0.width, view0.height, view0.pixelFormat,
            view1.width, view1.height, view1.pixelFormat
        ) == 0
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

        var acquired = WVRAcquiredStereoFrameV2()
        acquired.structSize = UInt32(MemoryLayout<WVRAcquiredStereoFrameV2>.size)
        let acquireStatus = withUnsafeMutablePointer(to: &acquired) {
            wvr_compositor_acquire_latest_stereo_frame_v2($0)
        }
        let hasFrame = acquireStatus == 0 && acquired.lease != nil

        var leftTexture: (any MTLTexture)?
        var rightTexture: (any MTLTexture)?
        var readyEvent: (any MTLSharedEvent)?
        var leftSource: EyeSource?
        var rightSource: EyeSource?
        if hasFrame,
           let leftPointer = acquired.leftTexture,
           let rightPointer = acquired.rightTexture,
           let eventPointer = acquired.producerReadyEvent {
            leftTexture = Unmanaged<AnyObject>.fromOpaque(leftPointer).takeUnretainedValue() as? any MTLTexture
            rightTexture = Unmanaged<AnyObject>.fromOpaque(rightPointer).takeUnretainedValue() as? any MTLTexture
            readyEvent = Unmanaged<AnyObject>.fromOpaque(eventPointer).takeUnretainedValue() as? any MTLSharedEvent
            if let leftTexture, let rightTexture {
                leftSource = EyeSource(texture: leftTexture, slice: Int(acquired.leftSlice),
                                       x: Int(acquired.leftX), y: Int(acquired.leftY),
                                       width: Int(acquired.leftWidth), height: Int(acquired.leftHeight))
                rightSource = EyeSource(texture: rightTexture, slice: Int(acquired.rightSlice),
                                        x: Int(acquired.rightX), y: Int(acquired.rightY),
                                        width: Int(acquired.rightWidth), height: Int(acquired.rightHeight))
            }
        }

        var producerTargets = WVRRenderTargetInfoV1()
        producerTargets.structSize = UInt32(MemoryLayout<WVRRenderTargetInfoV1>.size)
        let targetStatus = wvr_compositor_copy_targets_v1(&producerTargets)
        let producerWidths = [producerTargets.width.0, producerTargets.width.1]
        let producerHeights = [producerTargets.height.0, producerTargets.height.1]
        let producerFormats = [producerTargets.pixelFormat.0, producerTargets.pixelFormat.1]
        let hasCurrentTargets = targetStatus == 0 && producerTargets.generation != 0 &&
            producerWidths.allSatisfy { $0 > 0 } && producerHeights.allSatisfy { $0 > 0 }

        let targets = (0..<drawable.views.count).compactMap { target(for: drawable, viewIndex: $0) }
        var sources = [leftSource, rightSource]
        let isNewGuestFrame = hasFrame
        if snapshotGeneration != producerTargets.generation || !hasCurrentTargets {
            lastEyeSnapshots.removeAll()
            snapshotGeneration = 0
        }
        if !hasFrame, lastEyeSnapshots.count == 2,
           snapshotGeneration == producerTargets.generation {
            sources = lastEyeSnapshots.map {
                EyeSource(texture: $0, slice: 0, x: 0, y: 0, width: $0.width, height: $0.height)
            }
        }
        let matchesTarget = (hasFrame || lastEyeSnapshots.count == 2) && hasCurrentTargets && drawable.views.count == 2 && targets.count == 2 &&
            sources.count == 2 && sources.allSatisfy { $0 != nil } && (!hasFrame || readyEvent != nil) &&
            targets.indices.allSatisfy { index in
                guard let source = sources[index] else { return false }
                return source.width <= Int(producerWidths[index]) &&
                       source.height <= Int(producerHeights[index]) &&
                       source.width > 0 && source.height > 0 && source.slice >= 0 &&
                       source.slice < source.texture.arrayLength &&
                       source.x >= 0 && source.y >= 0 &&
                       source.x <= source.texture.width && source.y <= source.texture.height &&
                       source.width <= source.texture.width - source.x &&
                       source.height <= source.texture.height - source.y &&
                       producerFormats[index] == targets[index].pixelFormat &&
                       UInt32(source.texture.pixelFormat.rawValue) == producerFormats[index] &&
                       source.texture.device === layerRenderer.device
            }

        if matchesTarget {
            if let readyEvent { commandBuffer.encodeWaitForEvent(readyEvent, value: acquired.producerReadyValue) }
            for index in 0..<2 {
                guard let source = sources[index] else { continue }
                let target = targets[index]
                if source.width == Int(target.width) && source.height == Int(target.height) {
                    guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                        clear(target, on: commandBuffer)
                        continue
                    }
                    blit.copy(
                        from: source.texture,
                        sourceSlice: source.slice,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: source.x, y: source.y, z: 0),
                        sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                        to: target.texture,
                        destinationSlice: target.slice,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: target.originX, y: target.originY, z: 0)
                    )
                    blit.endEncoding()
                } else if !encodeSpatialUpscale(source, to: target, on: commandBuffer) {
                    clear(target, on: commandBuffer)
                }
            }
        } else {
            // No valid guest frame or matching owned snapshot: clear output.
            // Reused snapshots are real prior colors, not generated game frames.
            for target in targets {
                clear(target, on: commandBuffer)
            }
        }

        if isNewGuestFrame && matchesTarget, let leftSource, let rightSource {
            cacheEyes([leftSource, rightSource], generation: producerTargets.generation, on: commandBuffer)
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

    private func cacheEyes(_ sources: [EyeSource], generation: UInt64,
                           on commandBuffer: any MTLCommandBuffer) {
        var snapshots = lastEyeSnapshots
        let canReuse = snapshots.count == sources.count && sources.indices.allSatisfy {
            snapshots[$0].width == sources[$0].width && snapshots[$0].height == sources[$0].height &&
                snapshots[$0].pixelFormat == sources[$0].texture.pixelFormat
        }
        if !canReuse {
            snapshots.removeAll()
            for source in sources {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: source.texture.pixelFormat, width: source.width, height: source.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead]
                guard let texture = layerRenderer.device.makeTexture(descriptor: descriptor) else {
                    lastEyeSnapshots.removeAll()
                    snapshotGeneration = 0
                    return
                }
                snapshots.append(texture)
            }
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        for index in sources.indices {
            blit.copy(from: sources[index].texture, sourceSlice: sources[index].slice, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: sources[index].x, y: sources[index].y, z: 0),
                      sourceSize: MTLSize(width: sources[index].width, height: sources[index].height, depth: 1),
                      to: snapshots[index], destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        lastEyeSnapshots = snapshots
        snapshotGeneration = generation
    }

    private func spatialPipeline(for format: MTLPixelFormat, sourceIsArray: Bool) -> (any MTLRenderPipelineState)? {
        let key = (format.rawValue << 1) | (sourceIsArray ? 1 : 0)
        if let cached = spatialPipelines[key] { return cached }
        guard let spatialLibrary,
              let vertex = spatialLibrary.makeFunction(name: "wvr_spatial_vertex"),
              let fragment = spatialLibrary.makeFunction(
                name: sourceIsArray ? "wvr_spatial_array_fragment" : "wvr_spatial_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        guard let pipeline = try? layerRenderer.device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        spatialPipelines[key] = pipeline
        return pipeline
    }

    private func encodeSpatialUpscale(
        _ source: EyeSource,
        to target: EyeTarget,
        on commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let isArray = source.texture.textureType == .type2DArray
        guard source.width > 0, source.height > 0,
              let pipeline = spatialPipeline(for: target.texture.pixelFormat, sourceIsArray: isArray),
              let spatialSampler,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: {
                  let pass = MTLRenderPassDescriptor()
                  let attachment = pass.colorAttachments[0]
                  attachment?.texture = target.texture
                  attachment?.slice = target.slice
                  attachment?.level = 0
                  attachment?.loadAction = .dontCare
                  attachment?.storeAction = .store
                  return pass
              }())
        else { return false }

        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(
            originX: Double(target.originX),
            originY: Double(target.originY),
            width: Double(target.width),
            height: Double(target.height),
            znear: 0.0,
            zfar: 1.0
        ))
        encoder.setFragmentTexture(source.texture, index: 0)
        encoder.setFragmentSamplerState(spatialSampler, index: 0)
        var region = WVRSpatialSourceUniform(
            origin: SIMD2<Float>(Float(source.x), Float(source.y)),
            extent: SIMD2<Float>(Float(source.width), Float(source.height)),
            slice: UInt32(source.slice), padding: 0)
        withUnsafeBytes(of: &region) { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
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

@available(visionOS 1.0, *)
private struct EyeSource {
    let texture: any MTLTexture
    let slice: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct WVRSpatialSourceUniform {
    var origin: SIMD2<Float>
    var extent: SIMD2<Float>
    var slice: UInt32
    var padding: UInt32
}
