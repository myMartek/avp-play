import CoreGraphics
import Foundation
import ImageIO

/// Das Urteil über einen Laborlauf aus seinen Bildern und seiner Zusammenfassung (moonshot s2-judge): Kam ein Bild,
/// ist es schwarz, einfarbig oder magenta (fehlende Texturen oder Shader), steht es still, und hielt der Lauf an
/// einem fehlenden Aufruf an? Es misst nur, was sich am Bild messen lässt; ob ein Menü erreicht ist, sagt es nicht.
public enum LabJudge {
    /// Was ein einzelnes Bild zeigt.
    public enum Look: String, Codable, Sendable {
        case picture        // Inhalt
        case black          // (fast) nichts
        case flat           // eine einzige Farbe – ein Löschen ohne Zeichnen, ein weißes oder rosa Bild
        case magenta        // großflächig Magenta: die Farbe fehlender Texturen und Shader
    }

    public struct Frame: Codable, Equatable, Sendable {
        public var name: String
        public var look: Look
        /// Mittlere Helligkeit und ihre Streuung, 0…1.
        public var mean: Double
        public var spread: Double
        /// Anteil magentafarbener Bildpunkte, 0…1.
        public var magenta: Double
        /// Die mittlere Farbe als #rrggbb.
        public var color: String
        /// Bei einem Vulkan-Spiel, das beide Augen speichert: wie das zweite Auge aussieht.
        public var otherEye: Look?
    }

    public enum Verdict: String, Codable, Sendable {
        case stopped        // an einem fehlenden Aufruf angehalten oder abgestürzt
        case noPicture      // kein Bild oder nur schwarze
        case brokenPicture  // am Ende einfarbig oder magenta
        case oneEye         // am Ende hat nur ein Auge Inhalt
        case frozen         // am Ende mehrere gleiche Bilder – bei einem ruhigen Menü auch richtig
        case picture        // am Ende Inhalt, der sich ändert
    }

    public struct Result: Codable, Equatable, Sendable {
        public var verdict: Verdict
        public var frames: [Frame]
        /// Das erste Bild mit Inhalt.
        public var firstPicture: String?
        /// Was die Zusammenfassung des Laufs über sein Ende sagt.
        public var stop: String?
    }

    // MARK: Ein Bild

    /// Misst ein Bild auf 64 × 64 verkleinert: genug für Farbe und Streuung, und schnell bei Hunderten.
    public static func measure(_ url: URL) -> (look: Look, mean: Double, spread: Double, magenta: Double, color: String, pixels: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return judge(pixels: pixels)
    }

    /// Dieselbe Messung auf RGBA-Bildpunkten (4 Bytes je Punkt).
    static func judge(pixels: [UInt8]) -> (look: Look, mean: Double, spread: Double, magenta: Double, color: String, pixels: [UInt8]) {
        let n = pixels.count / 4
        var sum = 0.0, sumSq = 0.0, mag = 0, r = 0.0, g = 0.0, b = 0.0
        for i in 0..<n {
            let pr = Double(pixels[i * 4]) / 255, pg = Double(pixels[i * 4 + 1]) / 255, pb = Double(pixels[i * 4 + 2]) / 255
            let luma = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
            sum += luma; sumSq += luma * luma
            r += pr; g += pg; b += pb
            if pr > 0.6, pb > 0.6, pg < 0.35 { mag += 1 }
        }
        let mean = sum / Double(n)
        let spread = max(0, sumSq / Double(n) - mean * mean).squareRoot()
        let magenta = Double(mag) / Double(n)
        let color = String(format: "#%02x%02x%02x", Int(r / Double(n) * 255), Int(g / Double(n) * 255), Int(b / Double(n) * 255))
        let look: Look
        if magenta > 0.3 { look = .magenta }
        else if mean < 0.02, spread < 0.02 { look = .black }
        else if spread < 0.012 { look = .flat }
        else { look = .picture }
        return (look, mean, spread, magenta, color, pixels)
    }

    // MARK: Ein Lauf

    /// Die gespeicherten Bilder eines Laufs, je Bild des Spiels die Datei des ersten Auges und, wo es eine gibt, die
    /// des zweiten. Ein GL-Spiel speichert ein Auge (`frame_NNN.png`), ein Vulkan-Spiel beide: über Metas
    /// Schnittstelle `vk_fNNNNN_s<Stufe>_eye<e>[_named].png` (die Stufe, die das Spiel nannte, trägt `_named`),
    /// über OpenXR `xr_fNNNNN_layer<n>_eye<e>.png` (die unterste Ebene ist das Bild der Welt).
    static func pictures(_ names: [String]) -> [(key: String, eye0: String, eye1: String?)] {
        var single: [(String, String, String?)] = []
        var eyes: [String: [Int: (rank: Int, name: String)]] = [:]
        for name in names where name.hasSuffix(".png") {
            if name.hasPrefix("frame_") { single.append((name, name, nil)); continue }
            let parts = name.dropLast(4).split(separator: "_")
            guard parts.count >= 4, parts[1].hasPrefix("f"),
                  let eyePart = parts.first(where: { $0.hasPrefix("eye") }), let eye = Int(eyePart.dropFirst(3)), eye < 2 else { continue }
            let rank: Int
            if parts[0] == "vk", let stage = Int(parts[2].dropFirst()) { rank = parts.last == "named" ? -1 : stage }
            else if parts[0] == "xr", let layer = Int(parts[2].dropFirst(5)) { rank = layer }
            else { continue }
            let key = "\(parts[0])_\(parts[1])"
            if let have = eyes[key]?[eye], have.rank <= rank { continue }
            eyes[key, default: [:]][eye] = (rank, name)
        }
        let paired = eyes.compactMap { key, e -> (String, String, String?)? in
            guard let first = e[0] ?? e[1] else { return nil }
            return (key, first.name, e[0] != nil ? e[1]?.name : nil)
        }
        return (single + paired).sorted { $0.0 < $1.0 }.map { (key: $0.0, eye0: $0.1, eye1: $0.2) }
    }

    /// Urteilt über den Ordner eines Laufs (`frames/*.png`, `summary.txt`).
    public static func judge(folder: URL) -> Result {
        let fm = FileManager.default
        let framesDir = folder.appendingPathComponent("frames", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: framesDir.path)) ?? []
        var frames: [Frame] = []
        var last: [[UInt8]] = []
        for picture in pictures(names) {
            guard let m = measure(framesDir.appendingPathComponent(picture.eye0)) else { continue }
            var frame = Frame(name: picture.eye0, look: m.look, mean: m.mean, spread: m.spread, magenta: m.magenta, color: m.color)
            if let other = picture.eye1 { frame.otherEye = measure(framesDir.appendingPathComponent(other))?.look }
            frames.append(frame)
            last.append(m.pixels)
        }
        let summary = (try? String(contentsOf: folder.appendingPathComponent("summary.txt"), encoding: .utf8)) ?? ""
        return verdict(frames: frames, pixels: last, summary: summary)
    }

    static func verdict(frames: [Frame], pixels: [[UInt8]], summary: String) -> Result {
        let lines = summary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // A named stop that the game ran past is a call it did without, not the end: Red Matter names one Java method
        // it lacks and plays on for a minute (Mac, 2026-10-27). It counts when the run failed, or as a fault.
        let failed = lines.first { $0.hasPrefix("time:") }.map { !$0.hasSuffix("exit 0") } ?? true
        let stop = lines.first { $0.hasPrefix("FAULT") || ($0.hasPrefix("STOPPED:") && failed) }
        let first = frames.first { $0.look == .picture }?.name
        var result = Result(verdict: .picture, frames: frames, firstPicture: first, stop: stop)
        // Das Ende zählt: ein Ladebildschirm am Anfang ist schwarz, ein Absturz am Ende nicht zu übersehen.
        let tail = Array(frames.suffix(max(1, frames.count / 3)))
        if stop != nil {
            result.verdict = .stopped
        } else if frames.isEmpty || first == nil {
            result.verdict = frames.contains { $0.look == .flat || $0.look == .magenta } ? .brokenPicture : .noPicture
        } else if tail.allSatisfy({ $0.look != .picture }) {
            result.verdict = tail.allSatisfy { $0.otherEye == .picture } ? .oneEye
                : tail.allSatisfy { $0.look == .black } ? .noPicture : .brokenPicture
        } else if tail.allSatisfy({ $0.otherEye != nil && $0.otherEye != .picture }) {
            result.verdict = .oneEye
        } else if pixels.count >= 3, still(Array(pixels.suffix(3))) {
            result.verdict = .frozen
        }
        return result
    }

    /// Sind die Bilder gleich, bis auf Rauschen? Mittlere Abweichung unter einem halben Prozent.
    static func still(_ images: [[UInt8]]) -> Bool {
        guard let base = images.first else { return false }
        return images.dropFirst().allSatisfy { other in
            guard other.count == base.count else { return false }
            var diff = 0
            for i in 0..<base.count where i % 4 != 3 { diff += abs(Int(base[i]) - Int(other[i])) }
            return Double(diff) / Double(base.count / 4 * 3) / 255 < 0.005
        }
    }

    /// Das Urteil in einem Satz.
    public static func describe(_ r: Result) -> String {
        switch r.verdict {
        case .stopped: return L("Stopped: \(r.stop ?? "")", "Angehalten: \(r.stop ?? "")")
        case .noPicture: return L("No picture: every saved frame is black.", "Kein Bild: Jedes gespeicherte Bild ist schwarz.")
        case .brokenPicture:
            let look = r.frames.last { $0.look != .picture }
            return look?.look == .magenta
                ? L("Broken picture: mostly magenta at the end (missing textures or shaders).",
                    "Kaputtes Bild: Am Ende großteils magenta (fehlende Texturen oder Shader).")
                : L("Broken picture: one colour at the end (\(look?.color ?? "?")).",
                    "Kaputtes Bild: Am Ende eine einzige Farbe (\(look?.color ?? "?")).")
        case .oneEye:
            return L("One eye: at the end only one of the two eyes has content.",
                     "Ein Auge: Am Ende hat nur eines der beiden Augen Inhalt.")
        case .frozen:
            return L("Picture, but the last saved frames are the same (a still menu, or the game hangs).",
                     "Bild, aber die letzten gespeicherten Bilder sind gleich (ein ruhiges Menü, oder das Spiel hängt).")
        case .picture:
            return L("Picture: content from \(r.firstPicture ?? "?") on, changing to the end.",
                     "Bild: Inhalt ab \(r.firstPicture ?? "?"), bis zum Ende in Bewegung.")
        }
    }

    /// Schreibt `judge.json` in den Ordner und gibt das Urteil zurück.
    @discardableResult
    public static func write(folder: URL) throws -> Result {
        let r = judge(folder: folder)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(r).write(to: folder.appendingPathComponent("judge.json"), options: .atomic)
        return r
    }
}
