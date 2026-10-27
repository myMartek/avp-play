import ARKit
import CompositorServices
import SwiftUI

/// Ein Fenster auf dem Mac mit einem Knopf, der den Raum in der gekoppelten Vision Pro öffnet, und den Messwerten.
@main
struct D30RemoteApp: App {
    @StateObject private var stats = LabStats.shared

    var body: some Scene {
        Window("d30-remote", id: "main") {
            LabWindow().environmentObject(stats)
        }
        .defaultSize(width: 520, height: 420)

        RemoteImmersiveSpace(id: "cube") {
            CubeSpace()
        }
        // Auf dem Mac gibt es nur stufenlos (Krone, Raum sichtbar) und voll; voll zeigt den Würfel auf Schwarz (schwarze Kacheln am Rand: ob es sie
        // ohne Passthrough auch gibt).
        .immersionStyle(selection: Binding<any ImmersionStyle>(
            get: { stats.full ? FullImmersionStyle.full as any ImmersionStyle : ProgressiveImmersionStyle.progressive },
            set: { stats.full = $0 is FullImmersionStyle }), in: .progressive, .full)
    }
}

struct LabWindow: View {
    @EnvironmentObject var stats: LabStats
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.supportsRemoteScenes) private var supportsRemoteScenes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("d30-remote").font(.title2.bold())
            Text("Der Mac rendert einen Würfel, die Vision Pro zeigt ihn. Vorher die Vision Pro mit diesem Mac koppeln (Mac Virtual Display / Kontrollzentrum).")
                .foregroundStyle(.secondary)
            Text(supportsRemoteScenes ? "Entfernte Räume: unterstützt" : "Entfernte Räume: von diesem System nicht unterstützt")
                .foregroundStyle(supportsRemoteScenes ? .green : .orange)
            HStack {
                Button("In der Vision Pro öffnen") {
                    Task {
                        let result = await openImmersiveSpace(id: "cube")
                        stats.note("openImmersiveSpace: \(result)")
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Schließen") { Task { await dismissImmersiveSpace() } }
            }
            HStack(spacing: 16) {
                Toggle("Voll (ohne Raum)", isOn: $stats.full)
                Toggle("Farbe 16 Bit mit Alpha", isOn: $stats.wideColor)
            }
            Text("Umschalter gelten beim nächsten Öffnen: erst „Schließen“, dann neu öffnen.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Zustand"); Text(stats.state) }
                GridRow { Text("Bilder"); Text("\(stats.frames)") }
                GridRow { Text("Bildabstand"); Text(stats.interval) }
                GridRow { Text("Vorlauf bis zur Anzeige"); Text(stats.lead) }
                GridRow { Text("Kopfposition"); Text(stats.head) }
                GridRow { Text("Pinch-Ereignisse"); Text("\(stats.pinches)") }
                GridRow { Text("Letztes Ereignis"); Text(stats.lastEvent).lineLimit(2) }
            }
            .font(.callout.monospacedDigit())
            Divider()
            ScrollView {
                Text(stats.log.joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 380)
    }
}

/// Der Raum: eine Compositor-Ebene, gerendert vom Mac. Das Gerät kommt aus der Umgebung des Raums.
struct CubeSpace: CompositorContent {
    @Environment(\.remoteDeviceIdentifier) private var device

    var body: some CompositorContent {
        CompositorLayer(configuration: CubeConfiguration(wideColor: LabStats.shared.wideColor)) { @MainActor layer in
            LabStats.shared.note("Ebene da, Gerät: \(device.map { "\($0)" } ?? "keins"), \(LabStats.shared.full ? "voll" : "gemischt"), Farbe \(layer.configuration.colorFormat == .rgba16Float ? "16 Bit" : "8 Bit")")
            layer.onSpatialEvent = { events in
                for event in events { LabStats.shared.spatial(event) }
            }
            let renderer = CubeRenderer(layer: layer, device: device, opaque: LabStats.shared.full)
            let thread = Thread { renderer.run() }
            thread.name = "d30-remote render"
            thread.start()
        }
    }
}

struct CubeConfiguration: CompositorLayerConfiguration {
    var wideColor = false

    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        let wide = wideColor && capabilities.supportedColorFormats(options: []).contains(.rgba16Float)
        configuration.colorFormat = wide ? .rgba16Float : .bgra8Unorm_srgb
        configuration.layout = .dedicated
        configuration.isFoveationEnabled = capabilities.supportsFoveation
    }
}

/// Die Messwerte, für das Fenster. Der Render-Faden schreibt höchstens zehnmal pro Sekunde hinein.
@MainActor
final class LabStats: ObservableObject {
    static let shared = LabStats()
    @Published var state = "–"
    @Published var frames = 0
    @Published var interval = "–"
    @Published var lead = "–"
    @Published var head = "–"
    @Published var pinches = 0
    @Published var lastEvent = "–"
    @Published var log: [String] = []
    @Published var full = false
    @Published var wideColor = false

    func note(_ line: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func spatial(_ event: SpatialEventCollection.Event) {
        if event.phase == .active, event.kind == .indirectPinch { pinches += 1 }
        let pose = event.inputDevicePose.map { p in String(format: "Hand %.2f %.2f %.2f", p.pose3D.position.x, p.pose3D.position.y, p.pose3D.position.z) } ?? "ohne Handpose"
        lastEvent = "\(event.kind) \(event.phase) \(event.chirality.map { "\($0)" } ?? "-") · \(pose)"
    }
}
