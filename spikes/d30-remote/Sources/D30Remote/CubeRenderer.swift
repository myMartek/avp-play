import ARKit
import CompositorServices
import Metal
import QuartzCore
import SwiftUI
import simd

/// Der Render-Faden: ein Würfel einen Meter vor dem Startpunkt, pro Auge gezeichnet, mit der Kopfposition aus dem
/// ARKit der Brille. Misst den Abstand der Bilder und den Vorlauf bis zur geplanten Anzeige.
final class CubeRenderer: @unchecked Sendable {
    let layer: LayerRenderer
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let vertices: MTLBuffer
    let session: ARKitSession?
    let worldTracking = WorldTrackingProvider()
    private var lastFrame: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var leads: [Double] = []
    private var frames = 0
    private var lastReport: CFTimeInterval = 0
    private var tracked = 0
    private var described = false

    init(layer: LayerRenderer, device remote: RemoteDeviceIdentifier?) {
        self.layer = layer
        device = layer.device
        queue = device.makeCommandQueue()!
        session = remote.map { ARKitSession(device: $0) }

        let library = try! device.makeLibrary(source: CubeRenderer.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cubeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cubeFragment")
        descriptor.colorAttachments[0].pixelFormat = layer.configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = layer.configuration.depthFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater // Compositor Services rechnet mit umgekehrter Tiefe
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)!
        let data = CubeRenderer.cube()
        vertices = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<SIMD4<Float>>.stride, options: [])!
    }

    func run() {
        if let session {
            Task {
                do {
                    try await session.run([worldTracking])
                    report(state: "ARKit läuft (Weltverfolgung)")
                } catch {
                    report(state: "ARKit: \(error)")
                }
            }
        } else {
            report(state: "kein entferntes Gerät – keine Kopfposition")
        }
        while true {
            switch layer.state {
            case .paused:
                report(state: "pausiert")
                layer.waitUntilRunning()
            case .running:
                autoreleasepool { renderFrame() }
            case .invalidated:
                report(state: "beendet")
                return
            @unknown default:
                return
            }
        }
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else { return }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        // Auf dem Mac gibt es nur die Liste (eine Ebene kann mehrere Ziele haben); jedes wird gleich gezeichnet.
        let drawables = frame.queryDrawables()
        // Ohne Ziel (Raum pausiert, etwa nach der Krone) endet das Bild ohne endSubmission – sonst bricht
        // Compositor Services das Programm ab.
        guard let first = drawables.first, let commands = queue.makeCommandBuffer() else { return }
        if !described {
            described = true
            report(state: "Ziele: \(drawables.count), Ansichten: \(first.views.count), Farbtexturen: \(first.colorTextures.count), Foveation-Karten: \(first.rasterizationRateMaps.count)")
        }

        let clock = LayerRenderer.Clock()
        let presentation = first.frameTiming.presentationTime
        let lead = seconds(clock.now.duration(to: presentation))
        let when = seconds(LayerRenderer.Clock.Instant.epoch.duration(to: presentation))
        let anchor = worldTracking.queryDeviceAnchor(atTimestamp: when)
        if anchor?.isTracked == true { tracked += 1 }
        let head = anchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        // Der Würfel steht fest im Raum: 1 m vor und 1,2 m über dem Ursprung, dreht sich langsam.
        let angle = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 20) / 20 * 2 * .pi)
        let model = translation(0, 1.2, -1) * rotationY(angle) * scale(0.25)
        for drawable in drawables {
            drawable.deviceAnchor = anchor
            for (i, view) in drawable.views.enumerated() {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.colorTextures[i]
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[0].storeAction = .store
                pass.depthAttachment.texture = drawable.depthTextures[i]
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.storeAction = .store
                // Mit Foveation ist die Textur ungleichmäßig aufgelöst; ohne die Karte im Durchgang wird das Bild
                // verzerrt angezeigt (gekrümmte Kanten, schwarze Kacheln am Rand).
                if i < drawable.rasterizationRateMaps.count {
                    pass.rasterizationRateMap = drawable.rasterizationRateMaps[i]
                }
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
                let viewMatrix = (head * view.transform).inverse
                var mvp = drawable.computeProjection(viewIndex: i) * viewMatrix * model
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setCullMode(.back)
                encoder.setFrontFacing(.counterClockwise)
                let viewport = view.textureMap.viewport
                encoder.setViewport(viewport)
                encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
                encoder.endEncoding()
            }
            drawable.encodePresent(commandBuffer: commands)
        }
        commands.commit()
        frame.endSubmission()

        measure(lead: lead, head: head, tracked: anchor?.isTracked == true)
    }

    private func measure(lead: Double, head: simd_float4x4, tracked isTracked: Bool) {
        let now = CACurrentMediaTime()
        if lastFrame > 0 { intervals.append(now - lastFrame) }
        lastFrame = now
        leads.append(lead)
        frames += 1
        guard now - lastReport > 0.1 else { return }
        lastReport = now
        let meanInterval = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let meanLead = leads.reduce(0, +) / Double(max(leads.count, 1))
        intervals.removeAll(keepingCapacity: true)
        leads.removeAll(keepingCapacity: true)
        let frames = self.frames, tracked = self.tracked
        let position = head.columns.3
        DispatchQueue.main.async {
            let stats = LabStats.shared
            stats.frames = frames
            stats.interval = meanInterval > 0 ? String(format: "%.1f ms (%.0f Hz)", meanInterval * 1000, 1 / meanInterval) : "–"
            stats.lead = String(format: "%.1f ms", meanLead * 1000)
            stats.head = isTracked ? String(format: "%.2f %.2f %.2f (verfolgt in %d Bildern)", position.x, position.y, position.z, tracked)
                                   : "nicht verfolgt"
        }
    }

    private func report(state: String) {
        DispatchQueue.main.async {
            LabStats.shared.state = state
            LabStats.shared.note(state)
        }
    }

    // MARK: - Geometrie

    static func cube() -> [SIMD4<Float>] {
        // Je Ecke Position und Farbe im Wechsel (Farbe als w = Index der Seite).
        let p: [SIMD3<Float>] = [[-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1], [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1]]
        let faces: [[Int]] = [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]
        var out: [SIMD4<Float>] = []
        for (side, f) in faces.enumerated() {
            for i in [0, 1, 2, 0, 2, 3] { out.append(SIMD4(p[f[i]], Float(side))) }
        }
        return out
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; float3 color; };
    vertex Out cubeVertex(uint id [[vertex_id]], const device float4 *v [[buffer(0)]], constant float4x4 &mvp [[buffer(1)]]) {
        float3 colors[6] = { float3(1,0.3,0.3), float3(0.3,1,0.3), float3(0.3,0.3,1), float3(1,1,0.3), float3(0.3,1,1), float3(1,0.3,1) };
        Out o; o.position = mvp * float4(v[id].xyz, 1); o.color = colors[int(v[id].w)]; return o;
    }
    fragment float4 cubeFragment(Out in [[stage_in]]) { return float4(in.color, 1); }
    """
}

func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(x, y, z, 1)
    return m
}

func rotationY(_ a: Float) -> simd_float4x4 {
    simd_float4x4(SIMD4(cos(a), 0, -sin(a), 0), SIMD4(0, 1, 0, 0), SIMD4(sin(a), 0, cos(a), 0), SIMD4(0, 0, 0, 1))
}

func scale(_ s: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4(s, s, s, 1))
}
