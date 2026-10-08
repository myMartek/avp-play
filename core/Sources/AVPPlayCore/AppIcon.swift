import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Liest das App-Icon aus einem APK und erzeugt daraus das dreilagige Icon, das visionOS erwartet.
/// Das Icon bleibt auf dem Rechner des Nutzers: es wird nur in dessen eigenen Build eingebunden.
public enum AppIcon {
    public enum Source: Sendable, Equatable {
        /// Klassisches Icon: ein fertiges Bild.
        case single(Data)
        /// Zweiteiliges Android-Icon; daraus werden Ebenen mit Tiefe.
        case adaptive(background: Data?, foreground: Data)
        /// Frei zusammengesetzt: ein Hintergrundbild (wird formatfüllend beschnitten) und ein freigestelltes Logo.
        case layered(background: Data, logo: Data)

        public var summary: String {
            switch self {
            case .single(let d): return L("classic, \(AppIcon.pixelSize(d))", "klassisch, \(AppIcon.pixelSize(d))")
            case .adaptive(let bg, let fg):
                return L("two-part, foreground \(AppIcon.pixelSize(fg))\(bg == nil ? ", no image background" : "")",
                         "zweiteilig, Vordergrund \(AppIcon.pixelSize(fg))\(bg == nil ? ", ohne Bild-Hintergrund" : "")")
            case .layered(let bg, let logo):
                return L("background \(AppIcon.pixelSize(bg)) with logo \(AppIcon.pixelSize(logo))",
                         "Hintergrund \(AppIcon.pixelSize(bg)) mit Logo \(AppIcon.pixelSize(logo))")
            }
        }
    }

    static let side = 1024

    /// SHA-256 des maßgeblichen Bildes (bei zweiteiligen Icons: des Vordergrunds).
    public static func fingerprint(_ source: Source) -> String {
        let data: Data
        switch source {
        case .single(let d): data = d
        case .adaptive(_, let fg): data = fg
        case .layered(_, let logo): data = logo
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Manche Spiele liefern im APK kein eigenes Icon, sondern den Platzhalter ihrer Engine – auf der Quest
    /// stammt das Bild ohnehin aus dem Store. Ein Engine-Logo als App-Icon wäre schlechter als keins;
    /// solche Bilder werden deshalb übergangen. Die Liste wächst mit den Rezepten.
    static let enginePlaceholders: Set<String> = [
        "76bff962d190329218ebbbb90815e65fdc7eedc1cbec78ef90e7e0dbfe275ada",   // Unreal Engine 4.27, icon.png (96 px)
        "0d50d465ab68e033f8108efee0a7b28b78cbcccb78868f1e0060e410b0cd64b8",   // Unity 2022.3, ic_launcher_foreground.png (108 px)
    ]

    public static func isEnginePlaceholder(_ source: Source) -> Bool {
        enginePlaceholders.contains(fingerprint(source))
    }

    /// Ein vom Nutzer hinterlegtes Bild hat Vorrang vor dem aus dem APK.
    public static func custom(at url: URL) -> Source? {
        guard let data = try? Data(contentsOf: url), image(data) != nil else { return nil }
        return .single(data)
    }

    /// Sucht das Icon: Manifest -> `android:icon` -> Ressourcentabelle -> Datei im Archiv.
    public static func extract(apk: URL) throws -> Source? {
        let manifest = try ApkUnpacker.run(["/usr/bin/unzip", "-p", apk.path, "AndroidManifest.xml"]).data
        guard let app = try AXML.scan(manifest).first(where: { $0.tag == "application" }),
              let icon = app.attributes["icon"], icon.type == 0x01 else { return nil }
        guard let arsc = try? ApkUnpacker.run(["/usr/bin/unzip", "-p", apk.path, "resources.arsc"]).data, !arsc.isEmpty else { return nil }
        let names = Set(try ApkUnpacker.run(["/usr/bin/unzip", "-Z1", apk.path]).text.split(separator: "\n").map(String.init))

        func read(_ path: String) -> Data? {
            // Nur Pfade, die wirklich als Eintrag im Archiv stehen; sie gelangen als einzelnes Argument an unzip.
            guard names.contains(path), ApkUnpacker.isSafeEntry(path), !path.contains("*"), !path.contains("?"), !path.contains("[") else { return nil }
            return try? ApkUnpacker.run(["/usr/bin/unzip", "-p", apk.path, path]).data
        }
        func bestBitmap(_ id: UInt32) -> Data? {
            let candidates = ((try? ResourceTable.candidates(arsc: arsc, resourceId: id)) ?? [])
                .filter { AppIcon.isBitmap($0.path) }
                .sorted { ResourceTable.rank($0.density) > ResourceTable.rank($1.density) }
            for c in candidates { if let d = read(c.path), AppIcon.image(d) != nil { return d } }
            return nil
        }

        let all = try ResourceTable.candidates(arsc: arsc, resourceId: icon.data)
        if let xml = all.first(where: { $0.path.hasSuffix(".xml") }), let data = read(xml.path),
           let layers = try? AXML.scan(data) {
            let fg = layers.first { $0.tag == "foreground" }?.attributes["drawable"]
            let bg = layers.first { $0.tag == "background" }?.attributes["drawable"]
            if let fg, fg.type == 0x01, let front = bestBitmap(fg.data) {
                return .adaptive(background: bg.flatMap { $0.type == 0x01 ? bestBitmap($0.data) : nil }, foreground: front)
            }
        }
        return bestBitmap(icon.data).map(Source.single)
    }

    static func isBitmap(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".png") || p.hasSuffix(".webp") || p.hasSuffix(".jpg") || p.hasSuffix(".jpeg")
    }

    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func pixelSize(_ data: Data) -> String {
        image(data).map { "\($0.width)×\($0.height) px" } ?? L("unreadable", "unlesbar")
    }

    /// Eine Ebene von 1024×1024 als PNG. Die hinterste Ebene muss deckend sein.
    static func layer(opaque: Bool, _ draw: (CGContext, CGRect) -> Void) -> Data? {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        draw(ctx, CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Erzeugt die drei Ebenen (hinten, Mitte, vorn).
    public static func layers(from source: Source) -> (back: Data, middle: Data, front: Data)? {
        let dark = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        let empty = layer(opaque: false) { _, _ in }
        switch source {
        case .single(let data):
            guard let icon = image(data) else { return nil }
            let back = layer(opaque: true) { ctx, rect in
                ctx.setFillColor(dark); ctx.fill(rect)
                ctx.draw(icon, in: rect)
            }
            guard let back, let empty else { return nil }
            return (back, empty, empty)
        case .adaptive(let background, let foreground):
            guard let fg = image(foreground) else { return nil }
            // Android zeigt von den Ebenen nur die mittleren zwei Drittel; der Rand ist Spielraum für Bewegung.
            let zoomed = CGRect(x: -Double(side) / 4, y: -Double(side) / 4, width: Double(side) * 1.5, height: Double(side) * 1.5)
            let bg = background.flatMap(image)
            let back = layer(opaque: true) { ctx, rect in
                ctx.setFillColor(dark); ctx.fill(rect)
                if let bg { ctx.draw(bg, in: zoomed) }
            }
            let front = layer(opaque: false) { ctx, _ in ctx.draw(fg, in: zoomed) }
            guard let back, let empty, let front else { return nil }
            return (back, empty, front)
        case .layered(let background, let logo):
            guard let bg = image(background), let fg = image(logo) else { return nil }
            let canvas = Double(side)
            let back = layer(opaque: true) { ctx, rect in
                ctx.setFillColor(dark); ctx.fill(rect)
                // formatfüllend: die kürzere Seite füllt die Fläche, der Überstand wird mittig abgeschnitten
                let scale = max(canvas / Double(bg.width), canvas / Double(bg.height))
                let w = Double(bg.width) * scale, h = Double(bg.height) * scale
                ctx.draw(bg, in: CGRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
                // leicht abdunkeln, damit das Logo davor lesbar bleibt
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)); ctx.fill(rect)
            }
            let front = layer(opaque: false) { ctx, _ in
                // einpassen: das Logo nimmt höchstens 78 % der Breite und 60 % der Höhe ein
                let scale = min(canvas * 0.78 / Double(fg.width), canvas * 0.60 / Double(fg.height))
                let w = Double(fg.width) * scale, h = Double(fg.height) * scale
                ctx.draw(fg, in: CGRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
            }
            guard let back, let empty, let front else { return nil }
            return (back, empty, front)
        }
    }

    /// Hintergrund und Logo aus dem Bildspeicher des Steam-Clients des Nutzers (liegt lokal vor, sobald das
    /// Spiel in seiner Steam-Bibliothek erschienen ist). Kein Netzzugriff.
    public static func steamLibrary(appId: String, cacheRoots: [URL] = AppIcon.steamCacheRoots) -> Source? {
        guard !appId.isEmpty, appId.allSatisfy(\.isNumber) else { return nil }
        for root in cacheRoots {
            let dir = root.appendingPathComponent(appId, isDirectory: true)
            guard let hero = try? Data(contentsOf: dir.appendingPathComponent("library_hero.jpg")),
                  let logo = try? Data(contentsOf: dir.appendingPathComponent("logo.png")),
                  image(hero) != nil, image(logo) != nil else { continue }
            return .layered(background: hero, logo: logo)
        }
        return nil
    }

    public static var steamCacheRoots: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [support.appendingPathComponent("Steam/appcache/librarycache", isDirectory: true)]
    }

    /// Schreibt das Icon als `…solidimagestack` (Aufbau wie von Xcode erzeugt).
    public static func writeImageStack(_ source: Source, to directory: URL) throws {
        guard let images = layers(from: source) else { throw UnpackError.manifest(L("the icon couldn't be prepared", "Icon ließ sich nicht aufbereiten")) }
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = #""info" : { "author" : "xcode", "version" : 1 }"#
        try #"{ \#(info), "layers" : [ { "filename" : "Front.solidimagestacklayer" }, { "filename" : "Middle.solidimagestacklayer" }, { "filename" : "Back.solidimagestacklayer" } ] }"#
            .write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        for (name, data) in [("Front", images.front), ("Middle", images.middle), ("Back", images.back)] {
            let layerDir = directory.appendingPathComponent("\(name).solidimagestacklayer")
            let imageset = layerDir.appendingPathComponent("Content.imageset")
            try fm.createDirectory(at: imageset, withIntermediateDirectories: true)
            try "{ \(info) }".write(to: layerDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
            let file = "\(name.lowercased()).png"
            try #"{ "images" : [ { "filename" : "\#(file)", "idiom" : "vision", "scale" : "2x" } ], \#(info) }"#
                .write(to: imageset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
            try data.write(to: imageset.appendingPathComponent(file))
        }
    }
}

/// Liest aus `resources.arsc`, auf welche Dateien eine Ressourcen-ID zeigt (eine je Bildschirmdichte).
enum ResourceTable {
    struct Candidate: Equatable { let density: Int; let path: String }

    /// Höhere Dichte = größeres Bild. "Beliebig"/"keine" (0, 0xFFFE, 0xFFFF) zählen für Bilder zuletzt.
    static func rank(_ density: Int) -> Int { (1..<0xFFFE).contains(density) ? density : 0 }

    static func candidates(arsc: Data, resourceId: UInt32, depth: Int = 0) throws -> [Candidate] {
        let r = AXML.Reader(data: arsc)
        guard arsc.count >= 12, try r.u16(0) == 0x0002 else { throw UnpackError.manifest(L("not a resource table", "keine Ressourcentabelle")) }
        let package = Int(resourceId >> 24), typeId = Int((resourceId >> 16) & 0xFF), entry = Int(resourceId & 0xFFFF)
        var strings: [String] = []
        var out: [Candidate] = []
        var off = try r.u16(2)
        while off + 8 <= arsc.count {
            let type = try r.u16(off), headerSize = try r.u16(off + 2), size = Int(try r.u32(off + 4))
            guard size >= 8, off + size <= arsc.count else { break }
            if type == 0x0001, strings.isEmpty {
                strings = try AXML.stringPool(r, at: off)
            } else if type == 0x0200, Int(try r.u32(off + 8)) == package {
                var sub = off + headerSize
                while sub + 8 <= off + size {
                    let subType = try r.u16(sub), subHeader = try r.u16(sub + 2), subSize = Int(try r.u32(sub + 4))
                    guard subSize >= 8, sub + subSize <= off + size else { break }
                    if subType == 0x0201, try r.u8(sub + 8) == typeId {
                        let flags = try r.u8(sub + 9)
                        let count = Int(try r.u32(sub + 12)), entriesStart = Int(try r.u32(sub + 16))
                        let density = try r.u16(sub + 34)
                        let base = sub + subHeader
                        var entryOffset: Int?
                        if flags & 0x01 != 0 {                      // dünn besetzt: (Index, Offset/4)-Paare
                            for i in 0..<count where try r.u16(base + 4 * i) == entry {
                                entryOffset = (try r.u16(base + 4 * i + 2)) * 4
                            }
                        } else if flags & 0x02 != 0 {               // 16-Bit-Offsets
                            if entry < count { let o = try r.u16(base + 2 * entry); if o != 0xFFFF { entryOffset = o * 4 } }
                        } else if entry < count {
                            let o = try r.u32(base + 4 * entry)
                            if o != 0xFFFF_FFFF { entryOffset = Int(o) }
                        }
                        if let entryOffset {
                            let e = sub + entriesStart + entryOffset
                            let entrySize = try r.u16(e), entryFlags = try r.u16(e + 2)
                            var valueType = 0
                            var value: UInt32 = 0
                            if entryFlags & 0x0008 != 0 {            // kompakter Eintrag: Wert steht direkt darin
                                valueType = entryFlags >> 8
                                value = try r.u32(e + 4)
                            } else if entryFlags & 0x0001 == 0 {     // einfacher Wert (kein Bündel)
                                valueType = try r.u8(e + entrySize + 3)
                                value = try r.u32(e + entrySize + 4)
                            }
                            if valueType == 0x03, Int(value) < strings.count {
                                out.append(Candidate(density: density, path: strings[Int(value)]))
                            } else if valueType == 0x01, depth < 4, value != resourceId {
                                out += try candidates(arsc: arsc, resourceId: value, depth: depth + 1)
                            }
                        }
                    }
                    sub += subSize
                }
            }
            off += size
        }
        return out
    }
}

extension AXML {
    struct Value: Equatable { let type: Int; let data: UInt32 }
    struct Element: Equatable { let tag: String; let attributes: [String: Value] }

    /// Die Elemente eines binären XML mit ihren Attributen als Rohwerte (für Verweise auf Ressourcen).
    static func scan(_ data: Data) throws -> [Element] {
        let r = Reader(data: data)
        guard data.count >= 8, try r.u16(0) == 0x0003 else { throw UnpackError.manifest(L("not binary XML", "kein binäres XML")) }
        var strings: [String] = [], resourceMap: [UInt32] = [], out: [Element] = []
        var off = 8
        while off + 8 <= data.count {
            let type = try r.u16(off), headerSize = try r.u16(off + 2), size = Int(try r.u32(off + 4))
            guard size >= 8, off + size <= data.count else { throw UnpackError.manifest(L("chunk with an invalid size", "Abschnitt mit ungültiger Größe")) }
            func string(_ i: UInt32) -> String { Int(i) < strings.count ? strings[Int(i)] : "" }
            if type == 0x0001 {
                strings = try stringPool(r, at: off)
            } else if type == 0x0180 {
                resourceMap = try (0..<((size - headerSize) / 4)).map { try r.u32(off + headerSize + 4 * $0) }
            } else if type == 0x0102 {
                let attrStart = try r.u16(off + headerSize + 8), attrSize = try r.u16(off + headerSize + 10)
                var attributes: [String: Value] = [:]
                for i in 0..<(try r.u16(off + headerSize + 12)) {
                    let a = off + headerSize + attrStart + i * attrSize
                    let nameIndex = try r.u32(a + 4)
                    var name = string(nameIndex)
                    if name.isEmpty, Int(nameIndex) < resourceMap.count {
                        // Namen entfernt: über die Framework-ID erkennen (icon = 0x01010002, drawable = 0x01010199)
                        let known: [UInt32: String] = [0x01010002: "icon", 0x01010199: "drawable"]
                        name = known[resourceMap[Int(nameIndex)]] ?? ""
                    }
                    attributes[name] = Value(type: try r.u8(a + 15), data: try r.u32(a + 16))
                }
                out.append(Element(tag: string(try r.u32(off + headerSize + 4)), attributes: attributes))
            }
            off += size
        }
        return out
    }
}
