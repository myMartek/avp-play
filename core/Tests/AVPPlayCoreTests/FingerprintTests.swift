import XCTest
@testable import AVPPlayCore

final class FingerprintTests: XCTestCase {
    /// Baut eine kleine ELF-Datei (64 Bit, Little Endian) mit dynamischer Symboltabelle und `DT_NEEDED`-Einträgen.
    static func elf(imports: [String], exports: [String], needed: [String], extra: String = "") -> Data {
        var dynstr = Data([0])
        func add(_ s: String) -> Int { let o = dynstr.count; dynstr.append(contentsOf: Array(s.utf8) + [0]); return o }
        let neededOffsets = needed.map(add)
        let symbols = imports.map { (add($0), 0, 2) } + exports.map { (add($0), 7, 2) } // (name, shndx, kind FUNC)
        var dynsym = Data(count: 24) // Symbol 0 ist leer
        for (name, shndx, kind) in symbols {
            var entry = Data(count: 24)
            entry.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(name).littleEndian, Array.init))
            entry[4] = UInt8((1 << 4) | kind) // GLOBAL
            entry.replaceSubrange(6..<8, with: withUnsafeBytes(of: UInt16(shndx).littleEndian, Array.init))
            dynsym.append(entry)
        }
        var dynamic = Data()
        for o in neededOffsets {
            dynamic.append(contentsOf: withUnsafeBytes(of: UInt64(1).littleEndian, Array.init))
            dynamic.append(contentsOf: withUnsafeBytes(of: UInt64(o).littleEndian, Array.init))
        }
        dynamic.append(Data(count: 16)) // DT_NULL
        let rodata = Data(extra.utf8)

        var file = Data(count: 64)
        let dynstrOff = file.count; file.append(dynstr)
        let dynsymOff = file.count; file.append(dynsym)
        let dynamicOff = file.count; file.append(dynamic)
        let rodataOff = file.count; file.append(rodata)
        let shoff = file.count
        func section(type: UInt32, offset: Int, size: Int, link: UInt32, entsize: UInt64) -> Data {
            var h = Data(count: 64)
            h.replaceSubrange(4..<8, with: withUnsafeBytes(of: type.littleEndian, Array.init))
            h.replaceSubrange(24..<32, with: withUnsafeBytes(of: UInt64(offset).littleEndian, Array.init))
            h.replaceSubrange(32..<40, with: withUnsafeBytes(of: UInt64(size).littleEndian, Array.init))
            h.replaceSubrange(40..<44, with: withUnsafeBytes(of: link.littleEndian, Array.init))
            h.replaceSubrange(56..<64, with: withUnsafeBytes(of: entsize.littleEndian, Array.init))
            return h
        }
        file.append(Data(count: 64)) // Abschnitt 0
        file.append(section(type: 3, offset: dynstrOff, size: dynstr.count, link: 0, entsize: 0))     // 1 .dynstr
        file.append(section(type: 11, offset: dynsymOff, size: dynsym.count, link: 1, entsize: 24))   // 2 .dynsym
        file.append(section(type: 6, offset: dynamicOff, size: dynamic.count, link: 1, entsize: 16))  // 3 .dynamic
        file.append(section(type: 1, offset: rodataOff, size: rodata.count, link: 0, entsize: 0))     // 4 .rodata
        file.replaceSubrange(0..<6, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1])
        file.replaceSubrange(0x28..<0x30, with: withUnsafeBytes(of: UInt64(shoff).littleEndian, Array.init))
        file.replaceSubrange(0x3A..<0x3C, with: withUnsafeBytes(of: UInt16(64).littleEndian, Array.init))
        file.replaceSubrange(0x3C..<0x3E, with: withUnsafeBytes(of: UInt16(5).littleEndian, Array.init))
        return file
    }

    /// Ein kleiner Dex-Kopf mit Typnamen in der Stringtabelle.
    static func dex(_ strings: [String]) -> Data {
        var file = Data(count: 0x70)
        file.replaceSubrange(0..<8, with: Array("dex\n035\0".utf8))
        let table = file.count
        file.append(Data(count: 4 * strings.count))
        for (i, s) in strings.enumerated() {
            let o = file.count
            file.replaceSubrange((table + 4 * i)..<(table + 4 * i + 4), with: withUnsafeBytes(of: UInt32(o).littleEndian, Array.init))
            file.append(UInt8(s.utf16.count & 0x7F))
            file.append(contentsOf: Array(s.utf8) + [0])
        }
        file.replaceSubrange(0x38..<0x3C, with: withUnsafeBytes(of: UInt32(strings.count).littleEndian, Array.init))
        file.replaceSubrange(0x3C..<0x40, with: withUnsafeBytes(of: UInt32(table).littleEndian, Array.init))
        return file
    }

    func testELFSymbols() throws {
        let data = Self.elf(imports: ["ovr_User_GetLoggedInUser", "vkCreateInstance"], exports: ["Java_com_example_Game_init"],
                            needed: ["libvulkan.so", "libc.so"])
        let elf = try XCTUnwrap(ELFSymbols(data))
        XCTAssertEqual(elf.imports, ["ovr_User_GetLoggedInUser", "vkCreateInstance"])
        XCTAssertEqual(elf.exports, ["Java_com_example_Game_init"])
        XCTAssertEqual(elf.needed, ["libvulkan.so", "libc.so"])
        XCTAssertNil(ELFSymbols(Data("not an elf file at all, just text".utf8)))
        XCTAssertNil(ELFSymbols(data.prefix(80)), "abgeschnittene Datei")
    }

    func testFamiliesAndNames() {
        XCTAssertEqual(Fingerprint.Family.of("ovrp_GetVersion"), .ovrplugin)
        XCTAssertEqual(Fingerprint.Family.of("ovr_Room_Join"), .platform)
        XCTAssertEqual(Fingerprint.Family.of("vrapi_SubmitFrame2"), .vrapi)
        XCTAssertEqual(Fingerprint.Family.of("xrCreateSession"), .openxr)
        XCTAssertNil(Fingerprint.Family.of("xrDevice"), "Unitys eigener Name, keine OpenXR-Funktion")
        XCTAssertNil(Fingerprint.Family.of("ovr_lowercase"))
        XCTAssertTrue(NameScanner.isExtension("XR_FB_space_warp"))
        XCTAssertTrue(NameScanner.isExtension("XR_METAX1_room_entity_info"))
        XCTAssertFalse(NameScanner.isExtension("XR_ERROR_RUNTIME_FAILURE"))
        XCTAssertFalse(NameScanner.isExtension("XR_TYPE_INSTANCE"))
        XCTAssertTrue(NameScanner.isQuestExtension("XR_FB_space_warp"))
        XCTAssertFalse(NameScanner.isQuestExtension("XR_VARJO_quad_views"))
        XCTAssertTrue(NameScanner.isUnityVersion("2021.3.16f1"))
        XCTAssertTrue(NameScanner.isUnityVersion("6000.3.19f1"))
        XCTAssertFalse(NameScanner.isUnityVersion("1.2.3"))
        XCTAssertEqual(NameScanner.unrealVersion("UE4+Release-4.27"), "4.27")
        XCTAssertTrue(NameScanner.isClassPath("com/oculus/vrapi/VrApi"))
        XCTAssertFalse(NameScanner.isClassPath("com/oculus"))
        XCTAssertEqual(NameScanner.identifier("ovr_User_Get.isOk"), "ovr_User_Get")
    }

    func testScannerFindsNamesInBinaryData() {
        var data = Data([0, 1, 2])
        data.append(contentsOf: Array("ovrp_GetVersion2".utf8) + [0, 0xFF])
        data.append(contentsOf: Array("++UE4+Release-4.27".utf8) + [0])
        data.append(contentsOf: Array("XR_FB_space_warp".utf8) + [0x0A])
        data.append(contentsOf: Array("hello world".utf8))
        var tokens: [String] = []
        NameScanner.scan(data) { tokens.append($0) }
        XCTAssertEqual(tokens, ["ovrp_GetVersion2", "UE4+Release-4.27", "XR_FB_space_warp"])
    }

    func testManifest() {
        let text = """
        <manifest package="com.example.game">
            <uses-feature android:glEsVersion="0x00030002" android:required="true">
            <uses-feature android:name="oculus.software.handtracking" android:required="false">
            <uses-permission android:name="android.permission.INTERNET">
            <meta-data android:name="com.oculus.supportedDevices" android:value="quest2|quest3">
            <meta-data android:name="com.oculus.ossplash" android:value="true">
            <meta-data android:name="com.facebook.sdk.ApplicationId" android:value="secret">
        </manifest>
        """
        let m = Manifest(text)
        XCTAssertEqual(m.features, ["oculus.software.handtracking"])
        XCTAssertEqual(m.glesVersion, "0x00030002")
        XCTAssertEqual(m.permissions, ["android.permission.INTERNET"])
        XCTAssertEqual(m.metaData, ["com.oculus.ossplash", "com.oculus.supportedDevices=quest2|quest3"],
                       "nur Namen; Werte nur, wo sie Geräte nennen – nie Schlüssel von Diensten")
    }

    func testDexPackages() {
        let data = Self.dex(["Lcom/oculus/vrapi/VrApi;", "Ljava/lang/String;", "Lcom/example/game/Main$1;", "not a type", "Landroid/app/Activity;"])
        XCTAssertEqual(Set(DexStrings.packages(data)), ["com.oculus.vrapi", "com.example.game"])
    }

    func testFingerprintFromInput() {
        let unity = Self.elf(imports: [], exports: [], needed: ["libGLESv3.so"], extra: "\u{0}2021.3.16f1\u{0}2018.3.0a1\u{0}2018.3.0a1\u{0}")
        let il2cpp = Self.elf(imports: [], exports: [], needed: [], extra: "\u{0}ovr_Room_Join\u{0}ovr_User_GetLoggedInUser\u{0}")
        let plugin = Self.elf(imports: ["ovrp_GetVersion", "ovrp_BeginFrame4"], exports: [], needed: ["libOVRPlugin.so"],
                              extra: "\u{0}XR_FB_space_warp\u{0}XR_VARJO_quad_views\u{0}com/unity/oculus/OculusUnity\u{0}")
        let provider = Self.elf(imports: ["vrapi_SubmitFrame2"], exports: ["ovrp_GetVersion"], needed: [], extra: "ovrp_Hidden")
        var input = Fingerprint.Input(manifest: "<manifest package=\"com.example\">\n<uses-permission android:name=\"android.permission.INTERNET\">\n",
                                      entries: ["lib/arm64-v8a/libunity.so", "lib/arm64-v8a/libil2cpp.so", "lib/arm64-v8a/libOculusXRPlugin.so",
                                                "lib/arm64-v8a/libOVRPlugin.so", "lib/arm64-v8a/libfmod.so", "lib/armeabi-v7a/libunity.so"])
        input.package = "com.example"
        input.libraries = [("libunity.so", unity), ("libil2cpp.so", il2cpp), ("libOculusXRPlugin.so", plugin),
                           ("libOVRPlugin.so", provider), ("libfmod.so", Data())]
        input.dex = [Self.dex(["Lcom/oculus/oculusplugin/Plugin;"])]
        let fp = Fingerprint.make(input)
        XCTAssertEqual(fp.engine, .unity)
        XCTAssertEqual(fp.scripting, "il2cpp")
        XCTAssertEqual(fp.engineVersion, "2021.3.16f1", "fertige Fassung vor der häufigeren Vorabfassung")
        XCTAssertEqual(fp.architectures, ["arm64-v8a", "armeabi-v7a"])
        XCTAssertEqual(fp.functions(.ovrplugin), ["ovrp_BeginFrame4", "ovrp_GetVersion"], "ohne ovrp_Hidden aus der Bibliothek, die OVRPlugin selbst ist")
        XCTAssertEqual(fp.imported(.ovrplugin), ["ovrp_BeginFrame4", "ovrp_GetVersion"])
        XCTAssertEqual(fp.functions(.platform), ["ovr_Room_Join", "ovr_User_GetLoggedInUser"])
        XCTAssertEqual(fp.imported(.platform), [])
        XCTAssertEqual(fp.interfaces, [.platform, .ovrplugin], "vrapi nur in der Bibliothek von OVRPlugin zählt nicht")
        XCTAssertEqual(fp.openxrExtensions, ["XR_FB_space_warp", "XR_VARJO_quad_views"])
        XCTAssertEqual(fp.jniClasses, ["com/unity/oculus/OculusUnity"])
        XCTAssertEqual(fp.middleware, ["FMOD", "Oculus XR Plugin"])
        XCTAssertTrue(fp.graphics.gles)
        XCTAssertFalse(fp.graphics.vulkan)
        XCTAssertEqual(fp.javaPackages, ["com.oculus.oculusplugin"])
        XCTAssertEqual(fp.permissions, ["android.permission.INTERNET"])
    }

    func testCoverageAndUnlockValue() {
        var a = Fingerprint(), b = Fingerprint()
        a.functions = ["platform": ["ovr_LeaderboardEntry_GetRank", "ovr_User_GetLoggedInUser"], "ovrplugin": ["ovrp_GetVersion"]]
        a.imported = ["platform": ["ovr_LeaderboardEntry_GetRank"]]
        a.interfaces = [.platform, .ovrplugin]
        a.openxrExtensions = ["XR_FB_space_warp", "XR_VARJO_quad_views"]
        b.functions = ["platform": ["ovr_LeaderboardEntry_GetRank"], "vrapi": ["vrapi_SubmitFrame2"]]
        b.imported = ["platform": ["ovr_LeaderboardEntry_GetRank"]]
        b.interfaces = [.platform, .vrapi]
        let runtime = RuntimeInterface(functions: ["platform": ["ovr_User_GetLoggedInUser"], "ovrplugin": ["ovrp_GetVersion"]],
                                       openxrExtensions: [])
        let ca = Coverage.of(a, runtime: runtime)
        XCTAssertEqual(ca.families["platform"]?.missing, ["ovr_LeaderboardEntry_GetRank"])
        XCTAssertEqual(ca.families["platform"]?.missingImported, ["ovr_LeaderboardEntry_GetRank"])
        XCTAssertEqual(ca.families["ovrplugin"]?.missing, [])
        XCTAssertEqual(ca.missingExtensions, ["XR_FB_space_warp"], "Varjo gibt es auf der Quest auch nicht")
        XCTAssertEqual(Coverage.of(b, runtime: runtime).unsupportedInterfaces, ["vrapi"])

        let matrix = CoverageMatrix(runtime: runtime, games: [("B", b), ("A", a)])
        XCTAssertEqual(matrix.rows.map(\.name), ["A", "B"])
        XCTAssertEqual(matrix.gaps.first?.name, "ovr_LeaderboardEntry_GetRank")
        XCTAssertEqual(matrix.gaps.first?.games, ["A", "B"])
        XCTAssertEqual(matrix.gaps.first?.importedBy, 2)
        XCTAssertEqual(matrix.platformAreas.first?.name, "Leaderboard")
        XCTAssertTrue(matrix.markdown().contains("| Leaderboard | 1 | 2 |"))
    }

    func testPlatformArea() {
        XCTAssertEqual(CoverageMatrix.platformArea("ovr_LeaderboardEntryArray_GetSize"), "Leaderboard")
        XCTAssertEqual(CoverageMatrix.platformArea("ovr_Message_GetCloudStorageData"), "CloudStorage")
        XCTAssertEqual(CoverageMatrix.platformArea("ovr_Achievements_Unlock"), "Achievement")
        XCTAssertEqual(CoverageMatrix.platformArea("ovr_Voip_Start"), "Voip")
        XCTAssertEqual(CoverageMatrix.platformArea("ovr_AppDownloadProgressResult_GetStatusCode"), "AppDownload")
        XCTAssertEqual(CoverageMatrix.platformArea("ovr_LeaderboardUpdateStatus_GetDidUpdate"), "LeaderboardUpdateStatus")
    }

    func testRuntimeScan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("klepton-scan-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("runtime/xr"), withIntermediateDirectories: true)
        try """
        static const char *const names[] = { "ovr_User_GetLoggedInUser", "ovrp_GetVersion" };
        // XR_FB_space_warp is offered; xrCreateSession too
        """.write(to: dir.appendingPathComponent("runtime/xr/kl_test.c"), atomically: true, encoding: .utf8)
        let runtime = try RuntimeInterface.scan(klepton: dir)
        XCTAssertEqual(runtime.functions(.platform), ["ovr_User_GetLoggedInUser"])
        XCTAssertEqual(runtime.functions(.ovrplugin), ["ovrp_GetVersion"])
        XCTAssertEqual(runtime.functions(.openxr), ["xrCreateSession"])
        XCTAssertEqual(runtime.openxrExtensions, ["XR_FB_space_warp"])
        XCTAssertThrowsError(try RuntimeInterface.scan(klepton: dir.appendingPathComponent("nothing")))
    }
}

final class PrognosisTests: XCTestCase {
    override func setUp() { L10n.language = .en }

    func fingerprint(engine: Fingerprint.Engine = .unreal, imported: [String: [String]], extensions: [String] = [],
                     interfaces: [Fingerprint.Family] = [.ovrplugin], architectures: [String] = ["arm64-v8a"]) -> Fingerprint {
        var fp = Fingerprint()
        fp.engine = engine
        fp.imported = imported
        fp.functions = imported
        fp.openxrExtensions = extensions
        fp.interfaces = interfaces
        fp.architectures = architectures
        fp.graphics.vulkan = true
        return fp
    }

    func testOutlooks() {
        let runtime = RuntimeInterface(functions: ["ovrplugin": ["ovrp_GetVersion", "ovrp_BeginFrame4"]], openxrExtensions: ["XR_FB_space_warp"])
        let verified = ReferenceFingerprint(id: "a", title: "A", fingerprint: fingerprint(imported: [
            "ovrplugin": ["ovrp_GetVersion", "ovrp_BeginFrame4", "ovrp_GetHandState"],
            "platform": ["ovr_Voip_Start"]]))
        let other = ReferenceFingerprint(id: "b", title: "B", fingerprint: fingerprint(engine: .unity, imported: [:]))

        // Wie A, nur was A auch braucht (ovrp_GetHandState fehlt der Runtime, aber A läuft damit).
        let twin = Prognosis.make(fingerprint(imported: ["ovrplugin": ["ovrp_GetVersion", "ovrp_GetHandState"]]), runtime: runtime, references: [verified, other])
        XCTAssertEqual(twin.outlook, .likely)
        XCTAssertEqual(twin.neighbours.first?.id, "a")
        XCTAssertEqual(twin.unusualFunctions, [])

        // Etwas Neues bei OVRPlugin und eine unbekannte Erweiterung: möglich, mit Namen.
        let odd = Prognosis.make(fingerprint(imported: ["ovrplugin": ["ovrp_GetVersion", "ovrp_NewThing"]],
                                             extensions: ["XR_FB_new_feature", "XR_VARJO_quad_views", "XR_FB_space_warp"]),
                                 runtime: runtime, references: [verified])
        XCTAssertEqual(odd.outlook, .possible)
        XCTAssertEqual(odd.unusualFunctions, ["ovrplugin:ovrp_NewThing"])
        XCTAssertEqual(odd.unusualExtensions, ["XR_FB_new_feature"])

        // Unbekannte Plattform-Funktionen ändern die Aussicht nicht, sie werden als Bereiche genannt.
        let online = Prognosis.make(fingerprint(imported: ["ovrplugin": ["ovrp_GetVersion"], "platform": ["ovr_LeaderboardEntryArray_GetSize", "ovr_Voip_Start"]]),
                                    runtime: runtime, references: [verified])
        XCTAssertEqual(online.outlook, .likely)
        XCTAssertEqual(online.missingPlatformAreas, ["Leaderboard"])
        XCTAssertTrue(online.summary.contains("Online features may be missing (Leaderboard)"))

        // Nur 32-Bit-Code, oder VrApi direkt, das niemand nachbildet: läuft nicht.
        let old = Prognosis.make(fingerprint(imported: [:], architectures: ["armeabi-v7a"]), runtime: runtime, references: [verified])
        XCTAssertEqual(old.outlook, .unlikely)
        let vrapi = Prognosis.make(fingerprint(imported: ["vrapi": ["vrapi_SubmitFrame2"]], interfaces: [.vrapi]), runtime: runtime, references: [verified])
        XCTAssertEqual(vrapi.outlook, .unlikely)
        XCTAssertTrue(vrapi.summary.hasPrefix("Will not run"))
    }

    func testReferenceKeepsOnlyWhatComparisonNeeds() {
        var fp = fingerprint(engine: .unity, imported: ["ovrplugin": ["ovrp_GetVersion"]], extensions: ["XR_FB_space_warp", "XR_VARJO_quad_views"])
        fp.engineVersion = "2021.3.16f1"
        fp.scripting = "il2cpp"
        fp.middleware = ["FMOD"]
        fp.functions["platform"] = ["ovr_User_GetLoggedInUser"] // nur genannt: gehört nicht in die Referenz
        let ref = ReferenceFingerprint(id: "x", title: "X", fingerprint: fp)
        XCTAssertEqual(ref.features, ["engine:unity", "gfx:vulkan", "mw:FMOD", "scripting:il2cpp", "unity:2021", "xr:ovrplugin"])
        XCTAssertEqual(ref.imported, ["ovrplugin": ["ovrp_GetVersion"]])
        XCTAssertEqual(ref.extensions, ["XR_FB_space_warp"])
    }
}
