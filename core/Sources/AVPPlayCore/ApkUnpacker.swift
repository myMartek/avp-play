import Foundation

public enum UnpackError: Error, CustomStringConvertible {
    case notAnApk(String)
    case unsafeEntry(String)
    case manifest(String)
    case tool(String)

    public var description: String {
        switch self {
        case .notAnApk(let m): return L("Not a readable APK file: \(m)", "Keine lesbare APK-Datei: \(m)")
        case .unsafeEntry(let n): return L("The archive contains a path that is not allowed: \(n)", "Das Archiv enthält einen unzulässigen Pfad: \(n)")
        case .manifest(let m): return L("AndroidManifest.xml can't be read: \(m)", "AndroidManifest.xml ist nicht lesbar: \(m)")
        case .tool(let m): return L("Unpacking failed: \(m)", "Entpacken fehlgeschlagen: \(m)")
        }
    }
}

/// Ersetzt apktool für das, was die Toolchain aus einem APK braucht (Schritt 0, F5):
///   lib/arm64-v8a/*.so, assets/**, AndroidManifest.xml als Text und eine minimale apktool.yml.
/// Kein Java, keine Fremdabhängigkeit. Das Archiv wird mit dem Systemwerkzeug `unzip` gelesen; vorher
/// werden alle Eintragsnamen geprüft, damit nichts außerhalb des Zielordners landen kann.
public struct ApkUnpacker: Sendable {
    public struct Info: Sendable, Equatable {
        public var package: String?
        public var versionCode: String?
        public var versionName: String?
        public var files: Int
    }

    public init() {}

    static func wanted(_ name: String) -> Bool {
        name.hasPrefix("assets/") || (name.hasPrefix("lib/arm64-v8a/") && name.hasSuffix(".so"))
    }

    static func isSafeEntry(_ name: String) -> Bool {
        if name.hasPrefix("/") || name.contains("\\") || name.contains("\0") { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." }
    }

    public func unpack(apk: URL, to destination: URL) throws -> Info {
        let names = try ApkUnpacker.run(["/usr/bin/unzip", "-Z1", apk.path]).text
            .split(separator: "\n").map(String.init)
        guard names.contains("AndroidManifest.xml") else { throw UnpackError.notAnApk(L("no AndroidManifest.xml", "kein AndroidManifest.xml")) }
        if let bad = names.first(where: { !ApkUnpacker.isSafeEntry($0) }) { throw UnpackError.unsafeEntry(bad) }
        let files = names.filter { ApkUnpacker.wanted($0) && !$0.hasSuffix("/") }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Nur die gewünschten Bereiche; -o überschreibt, damit ein Lauf wiederholbar ist. Die Muster sind
        // fest, Eintragsnamen aus dem Archiv gelangen nicht in die Kommandozeile.
        _ = try ApkUnpacker.run(["/usr/bin/unzip", "-q", "-o", apk.path, "assets/*", "lib/arm64-v8a/*.so",
                                 "-d", destination.path], allowedExitCodes: [0, 11])

        let binary = try ApkUnpacker.run(["/usr/bin/unzip", "-p", apk.path, "AndroidManifest.xml"]).data
        let (text, package, code, name) = try AXML.decode(binary)
        try text.write(to: destination.appendingPathComponent("AndroidManifest.xml"), atomically: true, encoding: .utf8)
        let yml = "versionInfo:\n  versionCode: \(code ?? "")\n  versionName: \(name ?? "")\n"
        try yml.write(to: destination.appendingPathComponent("apktool.yml"), atomically: true, encoding: .utf8)
        return Info(package: package, versionCode: code, versionName: name, files: files.count)
    }

    static func run(_ argv: [String], allowedExitCodes: Set<Int32> = [0]) throws -> (data: Data, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard allowedExitCodes.contains(p.terminationStatus) else {
            throw UnpackError.tool(L("\(argv[0]) exited with \(p.terminationStatus): \(errText.prefix(200))",
                                     "\(argv[0]) endete mit \(p.terminationStatus): \(errText.prefix(200))"))
        }
        return (data, String(decoding: data, as: UTF8.self))
    }
}

/// Binäres Android-XML (AXML) -> Text, in der Form, die die Runtime liest:
/// `package="…"`, `<meta-data android:name="…" android:value="…"/>`, `<uses-permission android:name="…"/>`.
enum AXML {
    static let androidNS = "http://schemas.android.com/apk/res/android"
    // Nur für Builds, die die Attributnamen aus dem Stringpool entfernt haben.
    static let attributeIDs: [UInt32: String] = [0x01010003: "name", 0x01010024: "value", 0x01010025: "resource",
                                                 0x0101021b: "versionCode", 0x0101021c: "versionName", 0x01010001: "label"]

    struct Reader {
        let data: Data
        func u8(_ o: Int) throws -> Int { try check(o, 1); return Int(data[data.startIndex + o]) }
        func u16(_ o: Int) throws -> Int { try check(o, 2); return try u8(o) | (try u8(o + 1) << 8) }
        func u32(_ o: Int) throws -> UInt32 {
            try check(o, 4)
            return UInt32(try u16(o)) | (UInt32(try u16(o + 2)) << 16)
        }
        func bytes(_ o: Int, _ n: Int) throws -> Data {
            try check(o, n)
            return data.subdata(in: (data.startIndex + o)..<(data.startIndex + o + n))
        }
        func check(_ o: Int, _ n: Int) throws {
            guard o >= 0, n >= 0, o + n <= data.count else { throw UnpackError.manifest(L("data ends unexpectedly", "Daten enden vorzeitig")) }
        }
    }

    static func stringPool(_ r: Reader, at off: Int) throws -> [String] {
        let headerSize = try r.u16(off + 2)
        let count = Int(try r.u32(off + 8))
        let utf8 = (try r.u32(off + 16) & 0x100) != 0
        let stringsStart = Int(try r.u32(off + 20))
        guard count < 1_000_000 else { throw UnpackError.manifest(L("string pool too large", "Stringpool zu groß")) }
        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var p = off + stringsStart + Int(try r.u32(off + headerSize + 4 * i))
            if utf8 {
                if try r.u8(p) & 0x80 != 0 { p += 1 }      // Zeichenanzahl (1 oder 2 Bytes), nicht gebraucht
                p += 1
                var n = try r.u8(p); p += 1
                if n & 0x80 != 0 { n = ((n & 0x7F) << 8) | (try r.u8(p)); p += 1 }
                out.append(String(decoding: try r.bytes(p, n), as: UTF8.self))
            } else {
                var n = try r.u16(p); p += 2
                if n & 0x8000 != 0 { n = ((n & 0x7FFF) << 16) | (try r.u16(p)); p += 2 }
                let raw = try r.bytes(p, 2 * n)
                out.append(String(decoding: stride(from: 0, to: raw.count, by: 2).map {
                    UInt16(raw[raw.startIndex + $0]) | (UInt16(raw[raw.startIndex + $0 + 1]) << 8)
                }, as: UTF16.self))
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// Kürzeste Dezimaldarstellung, die denselben 32-Bit-Wert ergibt (wie apktool: 2.1, nicht 2.0999999).
    static func floatText(_ bits: UInt32) -> String { "\(Float(bitPattern: bits))" }

    static func typedValue(type: Int, data: UInt32, raw: UInt32, strings: [String]) -> String {
        func string(_ i: UInt32) -> String { Int(i) < strings.count ? strings[Int(i)] : "" }
        if type == 0x03 { return string(raw != 0xFFFF_FFFF ? raw : data) }
        if raw != 0xFFFF_FFFF, type != 0x01, type != 0x02 { return string(raw) }
        switch type {
        case 0x01: return String(format: "@0x%08x", data)       // Referenz, nicht aufgelöst
        case 0x02: return String(format: "?0x%08x", data)
        case 0x12: return data != 0 ? "true" : "false"
        case 0x11: return String(format: "0x%x", data)
        case 0x04: return floatText(data)
        case 0x10...0x1F: return String(Int32(bitPattern: data))
        default: return String(format: "0x%08x", data)
        }
    }

    static func decode(_ data: Data) throws -> (text: String, package: String?, versionCode: String?, versionName: String?) {
        let r = Reader(data: data)
        guard data.count >= 8, try r.u16(0) == 0x0003 else { throw UnpackError.manifest(L("not binary XML", "kein binäres XML")) }
        var strings: [String] = [], resourceMap: [UInt32] = []
        var prefixes: [String: String] = [:], pendingNS: [(String, String)] = []
        var lines: [String] = [], depth = 0
        var package: String?, versionCode: String?, versionName: String?
        var off = 8
        while off + 8 <= data.count {
            let type = try r.u16(off), headerSize = try r.u16(off + 2), size = Int(try r.u32(off + 4))
            guard size >= 8, off + size <= data.count else { throw UnpackError.manifest(L("chunk with an invalid size", "Abschnitt mit ungültiger Größe")) }
            func string(_ i: UInt32) -> String { Int(i) < strings.count ? strings[Int(i)] : "" }
            switch type {
            case 0x0001:
                strings = try stringPool(r, at: off)
            case 0x0180:
                resourceMap = try (0..<((size - headerSize) / 4)).map { try r.u32(off + headerSize + 4 * $0) }
            case 0x0100:
                let prefix = string(try r.u32(off + headerSize)), uri = string(try r.u32(off + headerSize + 4))
                prefixes[uri] = prefix
                pendingNS.append((prefix, uri))
            case 0x0102:
                let tag = string(try r.u32(off + headerSize + 4))
                let attrStart = try r.u16(off + headerSize + 8), attrSize = try r.u16(off + headerSize + 10)
                let attrCount = try r.u16(off + headerSize + 12)
                var parts = ["<\(tag)"]
                for (p, u) in pendingNS { parts.append("xmlns:\(p)=\"\(u)\"") }
                pendingNS = []
                for i in 0..<attrCount {
                    let a = off + headerSize + attrStart + i * attrSize
                    let ns = try r.u32(a), nameIndex = try r.u32(a + 4), raw = try r.u32(a + 8)
                    let valueType = try r.u8(a + 15), valueData = try r.u32(a + 16)
                    var name = string(nameIndex)
                    if name.isEmpty, Int(nameIndex) < resourceMap.count {
                        let id = resourceMap[Int(nameIndex)]
                        name = attributeIDs[id] ?? String(format: "attr_0x%08x", id)
                    }
                    var uri = ns != 0xFFFF_FFFF ? string(ns) : ""
                    if uri.isEmpty, Int(nameIndex) < resourceMap.count, tag != "manifest" { uri = androidNS }
                    let value = typedValue(type: valueType, data: valueData, raw: raw, strings: strings)
                    let qualified = uri.isEmpty ? name : "\(prefixes[uri] ?? "android"):\(name)"
                    parts.append("\(qualified)=\"\(escape(value))\"")
                    if tag == "manifest" {
                        if name == "package" { package = value }
                        if name == "versionCode" { versionCode = value }
                        if name == "versionName" { versionName = value }
                    }
                }
                lines.append(String(repeating: "    ", count: max(depth, 0)) + parts.joined(separator: " ") + ">")
                depth += 1
            case 0x0103:
                depth -= 1
                lines.append(String(repeating: "    ", count: max(depth, 0)) + "</\(string(try r.u32(off + headerSize + 4)))>")
            default:
                break
            }
            off += size
        }
        let text = "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>\n" + lines.joined(separator: "\n") + "\n"
        return (text, package, versionCode, versionName)
    }
}
