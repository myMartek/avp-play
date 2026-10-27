import Foundation

/// Ein Laborlauf: ein Spiel auf diesem Mac, ohne Brille und ohne dass jemand zusieht. Die Toolchain baut ihre
/// Mac-Fassung, spielt ein Eingabeskript ab (Aufrufe ins Spiel, Controller-Drücke, Posen) und legt Protokoll,
/// Bilder, Bildzeiten und eine Zusammenfassung in einen Ordner (`tools/lab_run.sh` des Forks, moonshot s1-headless).
///
/// Dafür braucht der Mac die Mac-Fassungen von ANGLE und MoltenVK, die kein Toolchain-Paket mitbringt (sie sind nur
/// für Laborläufe da und groß): das Laborpaket, einmal installiert unter `lab-mac` im Datenordner.
public enum LabRun {
    /// Wo das Laborpaket liegt.
    public static var packFolder: URL { DataLocation.base.appendingPathComponent("lab-mac", isDirectory: true) }

    /// Die Dateien, ohne die ein Laborlauf kein Bild hat. ANGLE lädt den Rest selbst aus demselben Ordner.
    static let angleFiles = ["libEGL.dylib", "libGLESv2.dylib"]
    static let angleDependencies = ["libthird_party_abseil-cpp_absl.dylib", "libchrome_zlib.dylib", "libdawn_proc.dylib",
                                    "libdawn_native.dylib", "libdawn_platform.dylib", "libc++_chrome.dylib"]
    static let moltenVK = "libMoltenVK.dylib"

    /// Ist das Laborpaket da?
    public static func packInstalled(at folder: URL = packFolder) -> Bool {
        (angleFiles + angleDependencies + [moltenVK]).allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Kann diese Toolchain Laborläufe? Erst Stände mit `tools/lab_run.sh`.
    public static func supported(by toolchain: Toolchain) -> Bool {
        FileManager.default.fileExists(atPath: toolchain.root.appendingPathComponent("tools/lab_run.sh").path)
    }

    // MARK: Das Laborpaket

    /// Baut das Laborpaket aus einem Arbeitsverzeichnis des Forks, in dem ANGLE für den Mac gebaut ist
    /// (`vendor/out/Debug`) und MoltenVK für den Mac (`vendor-moltenvk/out/macos`). Die Bibliotheken werden ohne
    /// Symbole kopiert und neu signiert: aus rund 130 MB werden so etwa 50, gepackt etwa 20.
    public static func pack(checkout: URL, to directory: URL) throws -> URL {
        let fm = FileManager.default
        let angle = checkout.appendingPathComponent("vendor/out/Debug", isDirectory: true)
        let mvk = checkout.appendingPathComponent("vendor-moltenvk/out/macos", isDirectory: true)
        let sources = (angleFiles + angleDependencies).map { angle.appendingPathComponent($0) } + [mvk.appendingPathComponent(moltenVK)]
        for source in sources where !fm.fileExists(atPath: source.path) {
            throw PackageError.missingPrebuilt(source.path)
        }
        let stage = fm.temporaryDirectory.appendingPathComponent("avpplay-labpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        for source in sources {
            let copy = stage.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: copy)
            _ = try ToolchainPackager.run(["/usr/bin/strip", "-x", "-S", copy.path])
            _ = try ToolchainPackager.run(["/usr/bin/codesign", "-f", "-s", "-", copy.path])
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("klepton-lab-mac.tar.gz")
        try? fm.removeItem(at: archive)
        _ = try ToolchainPackager.run(["/usr/bin/tar", "-czf", archive.path, "-C", stage.path, "."])
        return archive
    }

    /// Prüft ein Laborpaket und legt es an seinen Platz. Ein vorhandenes wird erst ersetzt, wenn das neue
    /// vollständig ist.
    public static func install(archive: URL, to folder: URL = packFolder) throws {
        let fm = FileManager.default
        let fresh = folder.deletingLastPathComponent().appendingPathComponent(".lab-mac-new", isDirectory: true)
        try? fm.removeItem(at: fresh)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        _ = try ToolchainPackager.run(["/usr/bin/tar", "-xzf", archive.path, "-C", fresh.path])
        // Nur Bibliotheken, flach im Ordner: ein Archiv mit anderem Inhalt ist kein Laborpaket.
        let names = try fm.contentsOfDirectory(atPath: fresh.path).filter { !$0.hasPrefix(".") }
        guard packInstalled(at: fresh), names.allSatisfy({ $0.hasSuffix(".dylib") }) else {
            try? fm.removeItem(at: fresh)
            throw LabError.notALabPack(archive.path)
        }
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: fresh, to: folder)
    }

    // MARK: Der Lauf

    public struct Settings: Equatable, Sendable {
        /// Das Eingabeskript; ohne eines läuft das Spiel nur und wird aufgezeichnet.
        public var script: URL?
        /// Bilder, die das Spiel rechnen darf, und jedes wievielte als PNG bleibt.
        public var frames = 4000
        public var every = 250
        /// Sekunden für ein Unreal-Spiel, das Bilder nicht zählt (`KL_UE4_WAIT`).
        public var seconds: Int?
        /// Gespeicherten Stand aus einem früheren Lauf in diesem Ordner weiterverwenden.
        public var keepFiles = false
        public init() {}
    }

    /// Der Ordner eines Laufs: im Bestand des Spiels unter `lab/`, mit Datum und Uhrzeit.
    public static func outputFolder(store: ContentStore, recipe: Recipe, now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return store.directory(for: recipe).appendingPathComponent("lab", isDirectory: true)
            .appendingPathComponent(f.string(from: now), isDirectory: true)
    }

    /// Die Dateien des Spiels, die im Laborlauf dort liegen müssen, wo das Spiel sie sucht: alles aus dem Bestand mit
    /// einem Ziel unter `android-files/` (die `/sdcard` des Spiels), samt der Haupt-Datendatei, deren Ort die
    /// Toolchain kennt. Nur was im Bestand liegt; der Pfad ist relativ zu `android-files/`.
    public static func links(recipe: Recipe, store: ContentStore, toolchain: Toolchain) -> [(source: URL, relative: String)] {
        var obb: String?
        return recipe.files.compactMap { file in
            guard var dest = file.dest else { return nil }
            if dest == DraftRecipe.obbPlaceholder {
                if obb == nil { obb = toolchain.obbDestination(recipe: recipe) ?? "android-files/obb" }
                dest = obb!
            } else if DraftRecipe.needsPackage(dest) {
                guard let name = toolchain.packageName(recipe: recipe) else { return nil }
                dest = DraftRecipe.packageFolder(package: name)
            }
            let prefix = "android-files/"
            guard dest.hasPrefix(prefix) || dest == "android-files" else { return nil }
            let folder = dest == "android-files" ? "" : String(dest.dropFirst(prefix.count))
            let name = file.localName ?? file.name
            guard Recipe.isSafeName(name), folder.isEmpty || Recipe.isSafeRelativePath(folder) else { return nil }
            let source = store.url(for: file, in: recipe)
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            return (source, folder.isEmpty ? name : "\(folder)/\(name)")
        }
    }

    /// Befehl und Umgebung für `tools/lab_run.sh` in der Toolchain.
    public static func command(recipe: Recipe, store: ContentStore, toolchain: Toolchain, settings: Settings, output: URL,
                               pack: URL = packFolder, base: [String: String] = ProcessInfo.processInfo.environment)
        -> (arguments: [String], environment: [String: String]) {
        var arguments = [toolchain.root.appendingPathComponent("tools/lab_run.sh").path, recipe.toolchain.target,
                         settings.script?.path ?? "/dev/null", output.path,
                         "--frames", String(settings.frames), "--every", String(settings.every)]
        if settings.keepFiles { arguments.append("--keep-files") }
        for link in links(recipe: recipe, store: store, toolchain: toolchain) {
            arguments += ["--link", "\(link.source.path)=\(link.relative)"]
        }
        var env = base
        // Wie beim Bauen: nur, was macOS und Xcode mitbringen.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["KL_ANGLE_DIR"] = pack.path
        env["KL_MVK_DIR"] = pack.path
        if let seconds = settings.seconds { env["KL_UE4_WAIT"] = String(seconds) }
        env.merge(Toolchain.genericEnvironment(recipe: recipe)) { _, new in new }
        env.merge(TreeStore(store: store).toolchainEnvironment(recipe: recipe)) { _, new in new }
        return (arguments, env)
    }

    /// Führt den Lauf aus; jede Zeile der Ausgabe geht an `output`. Gibt den Rückgabewert des Skripts zurück.
    public static func run(recipe: Recipe, store: ContentStore, toolchain: Toolchain, settings: Settings,
                           folder: URL, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard supported(by: toolchain) else { throw LabError.toolchainTooOld(toolchain.name) }
        guard packInstalled() else { throw LabError.packMissing(packFolder.path) }
        try toolchain.prepare(recipe: recipe, store: store)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (arguments, environment) = command(recipe: recipe, store: store, toolchain: toolchain, settings: settings, output: folder)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = arguments
        p.currentDirectoryURL = toolchain.root
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        var pending = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                output(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { output(String(decoding: pending, as: UTF8.self)) }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

public enum LabError: Error, LocalizedError {
    case packMissing(String)
    case notALabPack(String)
    case toolchainTooOld(String)

    public var errorDescription: String? {
        switch self {
        case .packMissing(let p):
            return L("The lab pack (ANGLE and MoltenVK for the Mac) is not installed in \(p). Install it with: avpplay lab install <klepton-lab-mac.tar.gz>",
                     "Das Laborpaket (ANGLE und MoltenVK für den Mac) ist nicht in \(p) installiert. Installiere es mit: avpplay lab install <klepton-lab-mac.tar.gz>")
        case .notALabPack(let p):
            return L("\(p) is not a lab pack (ANGLE and MoltenVK for the Mac are missing from it).",
                     "\(p) ist kein Laborpaket (ANGLE und MoltenVK für den Mac fehlen darin).")
        case .toolchainTooOld(let name):
            return L("Toolchain \(name) cannot do lab runs yet (tools/lab_run.sh is missing). Name a newer one with --toolchain <folder>.",
                     "Toolchain \(name) kann noch keine Laborläufe (tools/lab_run.sh fehlt). Nenne eine neuere mit --toolchain <Ordner>.")
        }
    }
}
