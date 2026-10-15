import XCTest
@testable import AVPPlayCore

/// 2D-Apps (Spotify, WhatsApp) früh erkennen, ohne ein echtes Spiel für eine zu halten (GitHub-Meldung 20).
final class FlatAppTests: XCTestCase {
    /// Ein Manifest in der Form, die `AXML.decode` liefert, mit den angegebenen Zeilen in `<application>`.
    func manifest(_ body: String...) -> String {
        """
        <?xml version="1.0" encoding="utf-8" standalone="no"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.app">
            <application android:label="App">
        \(body.joined(separator: "\n"))
            </application>
        </manifest>
        """
    }

    let launcher = """
        <activity android:name=".Main">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        """

    // MARK: 2D-Apps

    func testAPanelAppWithoutVRMarkersOrVRLibrariesIsFlat() {
        // Wie Spotify: eigene native Bibliotheken, aber nichts von OpenXR, OVR oder einer Engine.
        let entries = ["AndroidManifest.xml", "classes.dex", "classes2.dex", "lib/arm64-v8a/liborbit-jni-spotify.so",
                       "lib/arm64-v8a/libc++_shared.so", "lib/arm64-v8a/libsqlcipher.so", "lib/armeabi-v7a/liborbit-jni-spotify.so"]
        XCTAssertEqual(FlatApp.verdict(manifest: manifest(launcher), entries: entries), .flat)
    }

    func testAPureJavaAppWithoutVRMarkersIsFlat() {
        XCTAssertEqual(FlatApp.verdict(manifest: manifest(launcher), entries: ["AndroidManifest.xml", "classes.dex"]), .flat)
    }

    func testTheMessageIsTheAgreedOneAndCountsAsUnsupported() {
        let before = L10n.language
        defer { L10n.language = before }
        L10n.language = .en
        XCTAssertEqual(InstallError.notAVRGame.description, "This is a 2D app, not a VR game. AVP Play only supports immersive games.")
        L10n.language = .de
        XCTAssertEqual(InstallError.notAVRGame.description, "Das ist eine 2D-App, kein VR-Spiel. AVP Play unterstützt nur immersive Spiele.")
        XCTAssertEqual(FailureKind.of(InstallError.notAVRGame), .unsupported)
    }

    // MARK: Echte Spiele

    func testEachVRManifestMarkerAloneMakesItAGame() {
        let markers = [
            #"<category android:name="com.oculus.intent.category.VR"/>"#,
            #"<category android:name="org.khronos.openxr.intent.category.IMMERSIVE_HMD"/>"#,
            #"<meta-data android:name="com.oculus.vr.focusaware" android:value="true"/>"#,
            #"<uses-feature android:name="android.hardware.vr.headtracking" android:required="true" android:version="1"/>"#,
            #"<uses-permission android:name="org.khronos.openxr.permission.OPENXR"/>"#,
            #"<meta-data android:name="com.samsung.android.vr.application.mode" android:value="vr_only"/>"#,
        ]
        for marker in markers {
            XCTAssertEqual(FlatApp.verdict(manifest: manifest(launcher, marker), entries: ["classes.dex"]), .immersive, marker)
        }
    }

    /// Ein Unreal-Spiel aus dem Bestand (x3484270071659289) hat keine VR-Kategorie im Manifest – die Kategorie
    /// allein darf also nicht entscheiden.
    func testAnUnrealGameWithoutTheVRCategoryIsAGame() {
        let m = manifest(#"<category android:name="android.intent.category.INFO"/>"#,
                         #"<meta-data android:name="com.oculus.vr.focusaware" android:value="true"/>"#,
                         #"<uses-feature android:name="android.hardware.vr.headtracking" android:required="true"/>"#)
        let entries = ["lib/arm64-v8a/libUE4.so", "lib/arm64-v8a/libOVRPlugin.so", "lib/arm64-v8a/libvrapi.so"]
        XCTAssertEqual(FlatApp.verdict(manifest: m, entries: entries), .immersive)
    }

    /// Jede VR- oder Engine-Bibliothek, die in den APKs der bekannten Spiele vorkommt, macht allein schon ein Spiel –
    /// auch wenn das Manifest nichts davon sagt.
    func testEachLibraryFromKnownGamesAloneMakesItAGame() {
        let seen = ["libopenxr_loader.so", "libOVRPlugin.so", "libovrplatformloader.so", "libvrapi.so", "libOculusXRPlugin.so",
                    "libUnityOpenXR.so", "libunity.so", "libil2cpp.so", "libUE4.so", "libUnreal.so", "libMetaXRAudioUnity.so",
                    "libpxrplatformloader.so", "libvrintegrationloader.so", "libvrlink_scene.so", "libgodot_android.so", "libgvr.so"]
        for lib in seen {
            XCTAssertEqual(FlatApp.verdict(manifest: manifest(launcher), entries: ["classes.dex", "lib/arm64-v8a/\(lib)"]), .immersive, lib)
            XCTAssertEqual(FlatApp.verdict(manifest: manifest(launcher), entries: ["lib/armeabi-v7a/\(lib)"]), .immersive, "32-Bit \(lib)")
        }
    }

    /// Gegen echte APKs: `AVPPLAY_GAME_APKS=<Ordner>` (etwa der Ordner einer installierten Toolchain) – sonst
    /// übersprungen. Kein einziges darf als 2D-App gelten.
    func testNoRealGameApkIsFlat() throws {
        guard let path = ProcessInfo.processInfo.environment["AVPPLAY_GAME_APKS"] else { throw XCTSkip("AVPPLAY_GAME_APKS not set") }
        let apks = (FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "apk" }
        XCTAssertFalse(apks.isEmpty)
        for apk in apks {
            XCTAssertEqual(FlatApp.verdict(apk: apk), .immersive, apk.lastPathComponent)
        }
    }

    // MARK: Unklares gilt als Spiel

    func testAnUnreadableManifestCountsAsAGame() {
        XCTAssertEqual(FlatApp.verdict(manifest: nil, entries: ["classes.dex"]), .unknown)
        XCTAssertEqual(FlatApp.verdict(manifest: "", entries: ["classes.dex"]), .unknown)
        XCTAssertEqual(FlatApp.verdict(manifest: "kein Manifest", entries: []), .unknown)
    }

    func testAFileThatIsNotAnApkCountsAsAGame() throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("broken.apk")
        try Data("not a zip".utf8).write(to: file)
        XCTAssertEqual(FlatApp.verdict(apk: file), .unknown)
        XCTAssertEqual(FlatApp.verdict(apk: dir.appendingPathComponent("missing.apk")), .unknown)
    }

    // MARK: Ein APK im Bestand

    func testAFlatApkInATrialIsRefusedAndMarked() throws {
        let dir = try scratch()
        let store = ContentStore(root: dir.appendingPathComponent("store"))
        let trial = recipe(target: "x7250002038460582")
        try FileManager.default.createDirectory(at: store.directory(for: trial), withIntermediateDirectories: true)
        let apk = try makeApk(in: dir, name: "spotify.apk", category: "android.intent.category.LAUNCHER",
                              libs: ["liborbit-jni-spotify.so"])
        XCTAssertEqual(FlatApp.verdict(apk: apk), .flat)
        XCTAssertFalse(FlatApp.isMarked(store: store, recipe: trial))
        XCTAssertThrowsError(try FlatApp.refuse(apk: apk, recipe: trial, store: store)) {
            XCTAssertEqual($0 as? InstallError, .notAVRGame)
        }
        XCTAssertTrue(FlatApp.isMarked(store: store, recipe: trial), "die Bibliothek zeigt es an")
    }

    func testAVRApkInATrialPasses() throws {
        let dir = try scratch()
        let store = ContentStore(root: dir.appendingPathComponent("store"))
        let trial = recipe(target: "x2436558143118760")
        let apk = try makeApk(in: dir, name: "game.apk", category: "com.oculus.intent.category.VR", libs: ["libsomething.so"])
        XCTAssertEqual(FlatApp.verdict(apk: apk), .immersive)
        XCTAssertNoThrow(try FlatApp.refuse(apk: apk, recipe: trial, store: store))
        XCTAssertFalse(FlatApp.isMarked(store: store, recipe: trial))
    }

    /// Ein Spiel mit eigenem Rezept und Eintrag in der Toolchain wird nie geprüft, was immer sein APK sagt.
    func testAGameWithItsOwnRecipeIsNeverRefused() throws {
        let dir = try scratch()
        let store = ContentStore(root: dir.appendingPathComponent("store"))
        let known = recipe(target: "beatsaber140")
        try FileManager.default.createDirectory(at: store.directory(for: known), withIntermediateDirectories: true)
        let apk = try makeApk(in: dir, name: "flat.apk", category: "android.intent.category.LAUNCHER", libs: [])
        XCTAssertEqual(FlatApp.verdict(apk: apk), .flat)
        XCTAssertNoThrow(try FlatApp.refuse(apk: apk, recipe: known, store: store))
        XCTAssertFalse(FlatApp.isMarked(store: store, recipe: known))
    }

    // MARK: Hilfen

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-flat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func recipe(target: String) -> Recipe {
        Recipe(schema: 1, id: "store-1", title: "Some App", package: "com.example.app", versionName: "1.0", versionCode: 2,
               store: .init(appId: "1"), toolchain: .init(target: target, minCommit: ""), files: [], addons: nil,
               status: .init(playability: "untested", download: "unknown", notes: nil), icon: nil)
    }

    /// Ein kleines APK: binäres Manifest mit einer Aktivität in der angegebenen Kategorie, dazu leere Bibliotheken.
    func makeApk(in dir: URL, name: String, category: String, libs: [String]) throws -> URL {
        let content = dir.appendingPathComponent("content-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("lib/arm64-v8a"), withIntermediateDirectories: true)
        try binaryManifest(category: category).write(to: content.appendingPathComponent("AndroidManifest.xml"))
        try Data().write(to: content.appendingPathComponent("classes.dex"))
        for lib in libs { try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: content.appendingPathComponent("lib/arm64-v8a/\(lib)")) }
        let apk = dir.appendingPathComponent(name)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", apk.path, "."]
        zip.currentDirectoryURL = content
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return apk
    }

    /// `<manifest package="com.example.app"><application><activity><intent-filter><category name="…"/>` als AXML.
    func binaryManifest(category: String) -> Data {
        let strings = ["manifest", "package", "com.example.app", "application", "activity", "intent-filter", "category", "name", category]
        func index(_ s: String) -> UInt32 { UInt32(strings.firstIndex(of: s)!) }
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func chunk(_ type: Int, headerSize: Int, _ body: Data) -> Data { u16(type) + u16(headerSize) + u32(UInt32(8 + body.count)) + body }

        var offsets = Data(), pool = Data()
        for s in strings {
            offsets += u32(UInt32(pool.count))
            let bytes = Data(s.utf8)
            pool += Data([UInt8(s.count), UInt8(bytes.count)]) + bytes + Data([0])
        }
        while pool.count % 4 != 0 { pool.append(0) }
        let stringsStart = 28 + offsets.count
        let poolChunk = chunk(0x0001, headerSize: 28, u32(UInt32(strings.count)) + u32(0) + u32(0x100) + u32(UInt32(stringsStart)) + u32(0)
                                                      + offsets + pool)

        let none: UInt32 = 0xFFFF_FFFF
        func start(_ tag: String, _ attrs: [(String, String)] = []) -> Data {
            var body = u32(0) + u32(none) + u32(none) + u32(index(tag)) + u16(20) + u16(20) + u16(attrs.count) + u16(0) + u16(0) + u16(0)
            for (key, value) in attrs {
                body += u32(none) + u32(index(key)) + u32(index(value)) + u16(8) + Data([0, 0x03]) + u32(index(value))
            }
            return chunk(0x0102, headerSize: 16, body)
        }
        func end(_ tag: String) -> Data { chunk(0x0103, headerSize: 16, u32(0) + u32(none) + u32(none) + u32(index(tag))) }

        let tree = start("manifest", [("package", "com.example.app")]) + start("application") + start("activity")
            + start("intent-filter") + start("category", [("name", category)]) + end("category") + end("intent-filter")
            + end("activity") + end("application") + end("manifest")
        let body = poolChunk + tree
        return u16(0x0003) + u16(8) + u32(UInt32(8 + body.count)) + body
    }
}
