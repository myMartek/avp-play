import Foundation

/// Der Kompatibilitäts-Fingerabdruck eines APKs: welche Engine, welche Grafik-Schnittstelle, welche
/// XR-Schnittstellen und welche ihrer Funktionen ein Spiel benutzt, welche Java-Pakete und welche Middleware es
/// mitbringt. Nur Namen – nie Inhalt: keine Bilder, keine Texte, kein Code des Spiels. Daraus lässt sich ablesen,
/// was die Runtime für ein Spiel können muss, bevor es geladen und gebaut ist (moonshot.md, `s2-fingerprint`).
public struct Fingerprint: Codable, Equatable, Sendable {
    /// Wird erhöht, wenn sich ändert, was ein Fingerabdruck enthält; alte gelten dann als neu zu erstellen.
    public static let currentFormat = 2

    public enum Engine: String, Codable, Sendable {
        case unity, unreal, godot, native
    }

    /// Die XR-Schnittstellen der Quest, jede mit dem Präfix ihrer Funktionen und der Bibliothek, die sie liefert.
    public enum Family: String, Codable, Sendable, CaseIterable {
        /// Metas Plattform-SDK (`ovr_User_…`, `ovr_IAP_…`): Konto, Käufe, Räume, Bestenlisten.
        case platform
        /// OVRPlugin (`ovrp_…`), über das Unity und Unreal mit der Brille reden.
        case ovrplugin
        /// Die alte VrApi (`vrapi_…`) der ersten Quest-Jahre.
        case vrapi
        /// OpenXR (`xr…`).
        case openxr

        public var prefix: String {
            switch self {
            case .platform: return "ovr_"
            case .ovrplugin: return "ovrp_"
            case .vrapi: return "vrapi_"
            case .openxr: return "xr"
            }
        }

        /// Die Bibliothek im APK, die die Schnittstelle liefert. Ihre eigenen Namen sind das Angebot, nicht der
        /// Bedarf des Spiels; sie wird darum nicht nach Namen durchsucht.
        public var provider: String {
            switch self {
            case .platform: return "libovrplatformloader.so"
            case .ovrplugin: return "libOVRPlugin.so"
            case .vrapi: return "libvrapi.so"
            case .openxr: return "libopenxr_loader.so"
            }
        }

        /// Ob ein Name zu dieser Familie gehört: Präfix, dann ein Großbuchstabe (`ovr_User_Get`, `xrCreateSession`).
        func matches(_ name: String) -> Bool {
            guard name.hasPrefix(prefix), name.count > prefix.count + 2 else { return false }
            let next = name[name.index(name.startIndex, offsetBy: prefix.count)]
            guard next.isASCII, next.isUppercase else { return false }
            if self == .openxr {
                // Engines haben eigene Namen mit „xr“ (Unitys `xrDevice`); OpenXR-Funktionen beginnen mit einem Verb.
                return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
                    && Family.openxrVerbs.contains { name.hasPrefix("xr" + $0) && name.count > $0.count + 2 }
            }
            return true
        }

        /// Die Verben, mit denen OpenXR-Funktionen (Kern und Erweiterungen) beginnen.
        static let openxrVerbs = ["Acquire", "Allocate", "Apply", "Attach", "Begin", "Cancel", "Capture", "Change", "Clear",
                                  "Compute", "Convert", "Create", "Delete", "Deserialize", "Destroy", "Disable", "Discover",
                                  "Downsample", "Enable", "End", "Enumerate", "Erase", "Free", "Get", "Initialize", "Load",
                                  "Locate", "Negotiate", "Path", "Pause", "Perf", "Persist", "Poll", "Publish", "Query",
                                  "Release", "Request", "Reset", "Resize", "Result", "Resume", "Retrieve", "Save", "Send",
                                  "Session", "Set", "Share", "Start", "Stop", "String", "Structure", "Submit", "Suggest",
                                  "Sync", "Thermal", "Trigger", "Try", "Unpersist", "Update", "Wait"]

        static func of(_ name: String) -> Family? {
            // ovrp_ vor ovr_: das längere Präfix zuerst.
            [.ovrplugin, .platform, .vrapi, .openxr].first { $0.matches(name) }
        }
    }

    public struct Graphics: Codable, Equatable, Sendable {
        /// Das Spiel kann Vulkan benutzen (bindet es ein oder lädt es beim Start).
        public var vulkan = false
        /// Das Spiel kann OpenGL ES benutzen.
        public var gles = false
        /// Die im Manifest verlangte OpenGL-ES-Fassung (`0x00030002` = 3.2), soweit angegeben.
        public var glesVersion: String?
        public init(vulkan: Bool = false, gles: Bool = false, glesVersion: String? = nil) {
            self.vulkan = vulkan; self.gles = gles; self.glesVersion = glesVersion
        }
    }

    public var format = Fingerprint.currentFormat
    public var package: String?
    public var versionCode: String?
    public var engine: Engine = .native
    /// Unity „2021.3.16f1“, Unreal „4.27“; `nil`, wo nicht erkennbar.
    public var engineVersion: String?
    /// Bei Unity: `il2cpp` oder `mono`.
    public var scripting: String?
    public var architectures: [String] = []
    public var graphics = Graphics()
    /// Die Schnittstellen, die das Spiel mitbringt oder aufruft.
    public var interfaces: [Family] = []
    /// Pro Familie (Schlüssel: `Family.rawValue`) die Funktionen, die das Spiel einbindet oder beim Namen nachschlägt.
    public var functions: [String: [String]] = [:]
    /// Der Teil davon, den nativer Code fest einbindet (dynamische Importe); der Rest wird nur beim Namen genannt,
    /// etwa weil Unity die ganze Hülle des Plattform-SDKs mitbringt, auch was das Spiel nie aufruft.
    public var imported: [String: [String]] = [:]
    /// OpenXR-Erweiterungen, die das Spiel beim Namen nennt (`XR_FB_space_warp`).
    public var openxrExtensions: [String] = []
    /// Die nativen Bibliotheken für arm64 (nur die Dateinamen).
    public var libraries: [String] = []
    /// Erkannte Middleware (FMOD, Wwise, Vivox, …), aus den Namen der Bibliotheken.
    public var middleware: [String] = []
    /// `uses-feature` aus dem Manifest (`oculus.software.handtracking`, `com.oculus.feature.PASSTHROUGH`).
    public var features: [String] = []
    public var permissions: [String] = []
    /// Namen der `meta-data` von Oculus und Meta im Manifest; Werte nur, wo sie Geräte nennen.
    public var metaData: [String] = []
    /// Java-Pakete aus dem Dex-Code, auf drei Stufen gekürzt (`com.oculus.vrapi`); ohne Java und Android selbst.
    public var javaPackages: [String] = []
    /// Java-Klassen, die nativer Code beim Namen nennt (JNI, `com/oculus/…`).
    public var jniClasses: [String] = []

    public init() {}

    public func functions(_ family: Family) -> [String] { functions[family.rawValue] ?? [] }
    public func imported(_ family: Family) -> [String] { imported[family.rawValue] ?? [] }
}

extension Fingerprint {
    /// Erstellt den Fingerabdruck eines APKs. Liest das Archiv mit `unzip`, legt die nativen Bibliotheken, den
    /// Dex-Code und (bei Unity mit Mono) die Assemblys in einen Ordner auf Zeit und löscht ihn danach.
    public static func make(apk: URL) throws -> Fingerprint {
        let names = try ApkUnpacker.run(["/usr/bin/unzip", "-Z1", apk.path]).text.split(separator: "\n").map(String.init)
        guard names.contains("AndroidManifest.xml") else { throw UnpackError.notAnApk(L("no AndroidManifest.xml", "kein AndroidManifest.xml")) }
        if let bad = names.first(where: { !ApkUnpacker.isSafeEntry($0) }) { throw UnpackError.unsafeEntry(bad) }
        let manifest = try ApkUnpacker.run(["/usr/bin/unzip", "-p", apk.path, "AndroidManifest.xml"]).data
        let decoded = try AXML.decode(manifest)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-fingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        // Feste Muster; Eintragsnamen aus dem Archiv gelangen nicht in die Kommandozeile. 11 = ein Muster traf nichts.
        _ = try ApkUnpacker.run(["/usr/bin/unzip", "-q", "-o", apk.path, "lib/arm64-v8a/*.so", "classes*.dex",
                                 "assets/bin/Data/Managed/*.dll", "-d", temp.path], allowedExitCodes: [0, 11])

        var input = Input(manifest: decoded.text, entries: names)
        input.package = decoded.package
        input.versionCode = decoded.versionCode
        for name in names where !name.hasSuffix("/") {
            let file = temp.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            if name.hasPrefix("lib/arm64-v8a/") { input.libraries.append((String(name.split(separator: "/").last ?? ""), data)) }
            else if name.hasSuffix(".dex") { input.dex.append(data) }
            else if name.hasSuffix(".dll") { input.assemblies.append(data) }
        }
        return make(input)
    }

    /// Was in einen Fingerabdruck eingeht – getrennt vom Lesen des Archivs, damit es sich ohne APK prüfen lässt.
    struct Input {
        var manifest: String
        var entries: [String]
        var package: String?
        var versionCode: String?
        /// Dateiname und Inhalt der nativen Bibliotheken für arm64.
        var libraries: [(name: String, data: Data)] = []
        var dex: [Data] = []
        var assemblies: [Data] = []
    }

    static func make(_ input: Input) -> Fingerprint {
        var fp = Fingerprint()
        fp.package = input.package
        fp.versionCode = input.versionCode
        fp.architectures = ApkUnpacker.architectures(entries: input.entries).sorted()
        let libNames = input.libraries.map(\.name)
        fp.libraries = libNames.sorted()
        let lower = Set(libNames.map { $0.lowercased() })

        if lower.contains("libunity.so") {
            fp.engine = .unity
            fp.scripting = lower.contains("libil2cpp.so") ? "il2cpp" : "mono"
        } else if lower.contains("libue4.so") || lower.contains("libunreal.so") {
            fp.engine = .unreal
        } else if lower.contains("libgodot_android.so") {
            fp.engine = .godot
        }

        var functions: [Family: Set<String>] = [:], imported: [Family: Set<String>] = [:]
        var extensions = Set<String>(), classes = Set<String>(), versions: [String: Int] = [:]
        var needed = Set<String>(), vulkanNamed = false, glNamed = false
        let providers = Set(Family.allCases.map { $0.provider.lowercased() })

        for (name, data) in input.libraries where !providers.contains(name.lowercased()) {
            let isUnity = name.lowercased() == "libunity.so"
            if let elf = ELFSymbols(data) {
                needed.formUnion(elf.needed)
                for symbol in elf.imports {
                    if let family = Family.of(symbol) {
                        functions[family, default: []].insert(symbol)
                        imported[family, default: []].insert(symbol)
                    }
                    if symbol.hasPrefix("vk") { vulkanNamed = true }
                    if symbol.hasPrefix("egl") || symbol.hasPrefix("glDraw") { glNamed = true }
                }
            }
            NameScanner.scan(data) { token in
                if let id = NameScanner.identifier(token), let family = Family.of(id) {
                    functions[family, default: []].insert(id)
                } else if NameScanner.isExtension(token) {
                    extensions.insert(token)
                } else if let version = NameScanner.unrealVersion(token) {
                    versions[version, default: 0] += 1
                } else if isUnity, NameScanner.isUnityVersion(token) {
                    versions[token, default: 0] += 1
                } else if NameScanner.isClassPath(token) {
                    classes.insert(token)
                }
                if token == "vkGetInstanceProcAddr" || token == "vkCreateInstance" { vulkanNamed = true }
                if token == "eglCreateContext" { glNamed = true }
            }
        }
        // Unity mit Mono: die Plattform-Aufrufe stehen in den Assemblys (P/Invoke beim Namen).
        for data in input.assemblies {
            NameScanner.scan(data) { token in
                if let id = NameScanner.identifier(token), let family = Family.of(id) { functions[family, default: []].insert(id) }
            }
        }

        fp.functions = Dictionary(uniqueKeysWithValues: functions.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value.sorted()) })
        fp.imported = Dictionary(uniqueKeysWithValues: imported.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value.sorted()) })
        fp.openxrExtensions = extensions.sorted()
        fp.jniClasses = classes.sorted()
        // Fertige Fassungen (f, p) vor Vorabfassungen: libunity nennt auch die älteste Fassung, die es lesen kann (`2018.3.0a1`).
        func isRelease(_ v: String) -> Bool { v.contains("f") || v.contains("p") || !v.contains(where: \.isLetter) }
        fp.engineVersion = versions.max { a, b in
            if isRelease(a.key) != isRelease(b.key) { return !isRelease(a.key) }
            return a.value < b.value || (a.value == b.value && a.key > b.key)
        }?.key
        // Eine Schnittstelle zählt, wenn der Code des Spiels sie aufruft. Die Bibliothek allein sagt wenig: viele
        // Spiele bringen libvrapi.so mit, rufen sie aber nur über OVRPlugin auf, das die Runtime ersetzt.
        fp.interfaces = Family.allCases.filter { !(functions[$0]?.isEmpty ?? true) }

        let manifest = Manifest(input.manifest)
        fp.features = manifest.features
        fp.permissions = manifest.permissions
        fp.metaData = manifest.metaData
        fp.graphics = Graphics(vulkan: vulkanNamed || needed.contains("libvulkan.so") || manifest.features.contains { $0.hasPrefix("android.hardware.vulkan") },
                               gles: glNamed || needed.contains("libGLESv3.so") || needed.contains("libGLESv2.so") || needed.contains("libEGL.so"),
                               glesVersion: manifest.glesVersion)
        fp.middleware = middleware(libraries: lower)
        fp.javaPackages = Array(Set(input.dex.flatMap(DexStrings.packages))).sorted()
        return fp
    }

    /// Middleware nach dem Namen ihrer Bibliothek; ein Name kann zu mehreren Merkmalen passen, jede Middleware
    /// zählt einmal.
    static let middlewareMarkers: [(marker: String, name: String)] = [
        ("fmod", "FMOD"), ("aksoundengine", "Wwise"), ("wwise", "Wwise"), ("vivox", "Vivox"), ("photon", "Photon"),
        ("eossdk", "Epic Online Services"), ("steam_api", "Steamworks"), ("bhaptics", "bHaptics"),
        ("ovrlipsync", "Oculus Lipsync"), ("ovraudio", "Oculus Spatializer"), ("audio360", "Audio360"),
        ("resonanceaudio", "Resonance Audio"), ("phonon", "Steam Audio"), ("firebase", "Firebase"),
        ("crashlytics", "Crashlytics"), ("playfab", "PlayFab"), ("agora", "Agora"), ("normcore", "Normcore"),
        ("sentry", "Sentry"), ("bugsnag", "Bugsnag"), ("backtrace", "Backtrace"), ("discord", "Discord"),
        ("modio", "mod.io"), ("vuplex", "Vuplex"), ("sdl2", "SDL2"), ("openal", "OpenAL"), ("bink", "Bink"),
        ("cri_ware", "CRIWARE"), ("criware", "CRIWARE"), ("avcodec", "FFmpeg"), ("ffmpeg", "FFmpeg"),
        ("oculusxrplugin", "Oculus XR Plugin"), ("unityopenxr", "Unity OpenXR"), ("metaxr", "Meta XR SDK"),
        ("pxr", "Pico"), ("gvr", "Google VR"), ("havok", "Havok"), ("physx", "PhysX"),
    ]

    static func middleware(libraries: Set<String>) -> [String] {
        Array(Set(middlewareMarkers.filter { m in libraries.contains { $0.contains(m.marker) } }.map(\.name))).sorted()
    }
}

/// Die Angaben aus dem Manifest (als Text, wie `AXML.decode` es schreibt), die zum Fingerabdruck gehören.
struct Manifest {
    var features: [String] = []
    var permissions: [String] = []
    var metaData: [String] = []
    var glesVersion: String?

    /// Diese `meta-data` nennen Geräte oder Modi; ihr Wert gehört dazu. Alle anderen Werte bleiben draußen – dort
    /// stehen auch Schlüssel von Diensten.
    static let valuedMetaData: Set<String> = ["com.oculus.supportedDevices", "com.oculus.handtracking.version",
                                              "com.oculus.handtracking.frequency", "com.oculus.vr.focusaware"]

    init(_ text: String) {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Manche Manifeste haben Leerzeichen am Ende eines Namens (`android.hardware.xr.input.controller `).
            let name = Manifest.attribute("android:name", in: trimmed)?.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<uses-feature") {
                if let name { features.append(name) }
                if let gl = Manifest.attribute("android:glEsVersion", in: trimmed) { glesVersion = gl }
            } else if trimmed.hasPrefix("<uses-permission"), let name {
                permissions.append(name)
            } else if trimmed.hasPrefix("<meta-data"), let name, name.hasPrefix("com.oculus.") || name.hasPrefix("com.meta.") {
                if Manifest.valuedMetaData.contains(name), let value = Manifest.attribute("android:value", in: trimmed) {
                    metaData.append("\(name)=\(value)")
                } else {
                    metaData.append(name)
                }
            }
        }
        features = Array(Set(features)).sorted()
        permissions = Array(Set(permissions)).sorted()
        metaData = Array(Set(metaData)).sorted()
    }

    static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: " \(name)=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

/// Liest aus einer ELF-Datei (64 Bit, Little Endian) die gebrauchten Bibliotheken, die eingebundenen und die
/// angebotenen Funktionen – nur die Namen aus der dynamischen Symboltabelle.
struct ELFSymbols {
    var needed: [String] = []
    var imports: [String] = []
    var exports: [String] = []

    private init() {}

    init?(_ data: Data) {
        let parsed = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ELFSymbols? in
            func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= raw.count ? Int(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) : nil }
            func u32(_ o: Int) -> Int? { o >= 0 && o + 4 <= raw.count ? Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) : nil }
            func u64(_ o: Int) -> Int? {
                guard o >= 0, o + 8 <= raw.count else { return nil }
                let v = raw.loadUnaligned(fromByteOffset: o, as: UInt64.self).littleEndian
                return v <= UInt64(Int.max) ? Int(v) : nil
            }
            func cString(_ table: (offset: Int, size: Int), _ index: Int) -> String? {
                guard index >= 0, index < table.size else { return nil }
                var end = table.offset + index
                let limit = min(raw.count, table.offset + table.size)
                while end < limit, raw[end] != 0 { end += 1 }
                guard end < limit else { return nil }
                return String(decoding: UnsafeRawBufferPointer(rebasing: raw[(table.offset + index)..<end]), as: UTF8.self)
            }
            guard raw.count >= 64, raw[0] == 0x7F, raw[1] == 0x45, raw[2] == 0x4C, raw[3] == 0x46,
                  raw[4] == 2, raw[5] == 1,
                  let shoff = u64(0x28), let shentsize = u16(0x3A), let shnum = u16(0x3C), shentsize >= 64 else { return nil }
            struct Section { var type: Int; var offset: Int; var size: Int; var link: Int; var entsize: Int }
            var sections: [Section] = []
            for i in 0..<shnum {
                let h = shoff + i * shentsize
                guard let type = u32(h + 4), let offset = u64(h + 24), let size = u64(h + 32), let link = u32(h + 40),
                      let entsize = u64(h + 56) else { return nil }
                sections.append(Section(type: type, offset: offset, size: size, link: link, entsize: entsize))
            }
            func table(_ index: Int) -> (offset: Int, size: Int)? {
                guard sections.indices.contains(index), sections[index].type == 3 else { return nil }
                let s = sections[index]
                return s.offset + s.size <= raw.count ? (s.offset, s.size) : nil
            }
            var result = ELFSymbols()
            for s in sections {
                switch s.type {
                case 11: // SHT_DYNSYM
                    guard let strings = table(s.link), s.offset + s.size <= raw.count else { continue }
                    let size = s.entsize >= 24 ? s.entsize : 24
                    for o in stride(from: s.offset + size, to: s.offset + s.size - 23, by: size) {
                        guard let nameIndex = u32(o), nameIndex != 0, let shndx = u16(o + 6) else { continue }
                        let info = Int(raw[o + 4]), binding = info >> 4, kind = info & 0xF
                        guard binding == 1 || binding == 2, let name = cString(strings, nameIndex) else { continue }
                        if shndx == 0 { result.imports.append(name) }
                        else if kind == 1 || kind == 2 { result.exports.append(name) }
                    }
                case 6: // SHT_DYNAMIC
                    guard let strings = table(s.link) else { continue }
                    for o in stride(from: s.offset, to: s.offset + s.size - 15, by: 16) {
                        guard let tag = u64(o) else { break }
                        if tag == 0 { break }
                        if tag == 1, let value = u64(o + 8), let name = cString(strings, value) { result.needed.append(name) }
                    }
                default:
                    continue
                }
            }
            return result
        }
        guard let parsed else { return nil }
        self = parsed
    }
}

/// Sucht in Binärdaten nach Namen: Folgen von Zeichen, aus denen Bezeichner, Klassenpfade und Fassungen bestehen.
/// Nur was einem der Muster entspricht, wird zu Text; der Rest bleibt unberührt.
enum NameScanner {
    /// Bezeichner-Zeichen plus `/ $ . + -` für Klassenpfade (`com/oculus/Foo$Bar`) und Fassungen (`2021.3.1f1`,
    /// `++UE4+Release-4.27`).
    static let tokenBytes: [Bool] = (0..<256).map { b in
        let c = UInt8(b)
        return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || c == 0x5F || c == 0x2F || c == 0x24 || c == 0x2E || c == 0x2B || c == 0x2D
    }

    /// Anfänge, nach denen überhaupt gesucht wird; alles andere wird übersprungen, ohne Text zu bilden.
    static let starts: [[UInt8]] = ["ovr", "vrapi_", "xr", "XR_", "UE4", "UE5", "com/", "org/", "net/", "io/", "tv/",
                                    "de/", "co/", "jp/", "vk", "egl", "1", "2", "3", "4", "5", "6"].map { Array($0.utf8) }

    static func scan(_ data: Data, _ body: (String) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            while i < n {
                guard tokenBytes[Int(bytes[i])] else { i += 1; continue }
                var start = i
                while i < n, tokenBytes[Int(bytes[i])] { i += 1 }
                var end = i
                // Satzzeichen am Rand gehören nicht zum Namen.
                while start < end, [0x2B, 0x2D, 0x2E, 0x2F].contains(bytes[start]) { start += 1 }
                while end > start, [0x2B, 0x2D, 0x2E, 0x2F].contains(bytes[end - 1]) { end -= 1 }
                let length = end - start
                guard length >= 5, length <= 256 else { continue }
                let matched = starts.contains { prefix in
                    prefix.count <= length && prefix.indices.allSatisfy { bytes[start + $0] == prefix[$0] }
                }
                guard matched else { continue }
                body(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))
            }
        }
    }

    /// Der Bezeichner am Anfang eines Tokens (`ovr_User_Get.isOk` → `ovr_User_Get`), wenn das Token mit einem
    /// Familienpräfix beginnt.
    static func identifier(_ token: String) -> String? {
        guard token.hasPrefix("ovr") || token.hasPrefix("vrapi_") || token.hasPrefix("xr") else { return nil }
        let id = token.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        return id.count >= 5 ? String(id) : nil
    }

    /// Die Hersteller, deren OpenXR-Erweiterungen die Quest anbietet. Was andere anbieten (Varjo, Microsoft, HTC,
    /// Pico, …), fragt ein Spiel nur nach, falls es da ist; auf der Quest ist es ebenso wenig da.
    static let questVendors: Set<String> = ["KHR", "EXT", "FB", "META", "METAX1", "METAX2", "OCULUS"]

    static func isQuestExtension(_ name: String) -> Bool {
        let parts = name.split(separator: "_")
        return parts.count >= 3 && questVendors.contains(String(parts[1]))
    }

    /// Ein OpenXR-Erweiterungsname: `XR_`, Hersteller in Großbuchstaben, Rest klein (`XR_FB_space_warp`).
    static func isExtension(_ token: String) -> Bool {
        let parts = token.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "XR", !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              let first = parts[2].first, first.isASCII, first.isLowercase || first.isNumber else { return false }
        return parts[2].allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
    }

    /// Die Fassung aus Unreals Kennung `++UE4+Release-4.27` (ohne Pluszeichen am Anfang, wie das Token sie liefert).
    static func unrealVersion(_ token: String) -> String? {
        for marker in ["UE4+Release-", "UE5+Release-"] {
            if let r = token.range(of: marker) {
                let version = token[r.upperBound...].prefix { $0.isNumber || $0 == "." }
                return version.isEmpty ? nil : String(version)
            }
        }
        return nil
    }

    /// Eine Unity-Fassung: `2021.3.16f1`, `5.6.7f1`.
    static func isUnityVersion(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), (2017...2099).contains(year) || (6000...6999).contains(year) || year == 5,
              Int(parts[1]) != nil else { return false }
        let last = parts[2]
        guard let letter = last.firstIndex(where: { "abfp".contains($0) }), letter != last.startIndex,
              Int(last[..<letter]) != nil, Int(last[last.index(after: letter)...]) != nil else { return false }
        return true
    }

    /// Ein Java-Klassenpfad, wie JNI ihn schreibt: mindestens zwei Schrägstriche, letzter Teil groß (`com/oculus/vrapi/VrApi`).
    static func isClassPath(_ token: String) -> Bool {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }),
              let first = parts.last?.first, first.isASCII, first.isUppercase else { return false }
        return parts.dropLast().allSatisfy { $0.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") } }
            && parts.last!.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
    }
}

/// Liest die Typnamen aus Dex-Code und macht daraus Java-Pakete.
enum DexStrings {
    /// Pakete, die zu Java, Kotlin oder Android selbst gehören und nichts über das Spiel sagen.
    static let platformPrefixes = ["java.", "javax.", "kotlin.", "kotlinx.", "dalvik.", "android.", "org.w3c.",
                                   "org.xml.", "org.json.", "org.apache.http.", "sun."]

    static func packages(_ data: Data) -> [String] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String] in
            func u32(_ o: Int) -> Int? { o >= 0 && o + 4 <= raw.count ? Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) : nil }
            guard raw.count > 0x70, raw[0] == 0x64, raw[1] == 0x65, raw[2] == 0x78,
                  let count = u32(0x38), let table = u32(0x3C), count < 10_000_000 else { return [] }
            var found = Set<String>()
            for i in 0..<count {
                guard var o = u32(table + 4 * i) else { break }
                // ULEB128: Länge in UTF-16-Einheiten, dann MUTF-8 bis zur Null.
                var guardBytes = 0
                while o < raw.count, raw[o] & 0x80 != 0, guardBytes < 5 { o += 1; guardBytes += 1 }
                o += 1
                guard o < raw.count, raw[o] == 0x4C else { continue } // "L"
                var end = o
                while end < raw.count, raw[end] != 0, raw[end] != 0x3B, end - o < 512 { end += 1 }
                guard end < raw.count, raw[end] == 0x3B else { continue } // ";"
                let path = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(o + 1)..<end]), as: UTF8.self)
                let parts = path.split(separator: "/")
                guard parts.count >= 2 else { continue }
                let package = parts.dropLast().prefix(3).joined(separator: ".")
                if !platformPrefixes.contains(where: { (package + ".").hasPrefix($0) }) { found.insert(package) }
            }
            return Array(found)
        }
    }
}

/// Was vom Fingerabdruck an den Katalogdienst geht, wenn der Nutzer das Teilen einschaltet: Engine, Grafik,
/// Schnittstellen, fest eingebundene Funktionen, Erweiterungen, Middleware, Gerätemerkmale. Ohne Paketnamen,
/// Berechtigungen, Java-Pakete und alles, was nur genannt wird. Der Dienst nimmt nichts anderes an.
public struct SharedFingerprint: Codable, Equatable, Sendable {
    public var format: Int
    public var engine: String
    public var engineVersion: String?
    public var scripting: String?
    public var graphics: Fingerprint.Graphics
    public var interfaces: [String]
    public var imported: [String: [String]]
    public var openxrExtensions: [String]
    public var middleware: [String]
    public var features: [String]

    public init(_ fp: Fingerprint) {
        format = fp.format
        engine = fp.engine.rawValue
        engineVersion = fp.engineVersion
        scripting = fp.scripting
        graphics = fp.graphics
        interfaces = fp.interfaces.map(\.rawValue)
        imported = fp.imported
        openxrExtensions = fp.openxrExtensions
        middleware = fp.middleware
        features = fp.features
    }
}
