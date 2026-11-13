import Foundation

/// AVP Play Remote, die Fernbedienung für die Vision Pro. Sie kommt nicht aus einem Store: AVP Play lädt den
/// Quellcode der neuesten Veröffentlichung von GitHub, baut ihn mit dem Apple-Team des Nutzers und installiert die
/// App wie ein Spiel – unter dem Präfix der Spiele, damit sie bei einem kostenlosen Team zu dessen Apps zählt.
///
/// Ein Auftrag dafür trägt ein Rezept ohne Dateien (`recipe(release:)`); `CompanionInstaller` führt ihn statt des
/// üblichen `Installer` aus.
public enum CompanionApp {
    public static let recipeId = "avp-play-remote"
    public static let title = "AVP Play Remote"
    public static let repository = "myMartek/avp-play-remote"
    /// Der letzte Teil der Kennung, unter der die App installiert wird; davor steht das Präfix der Spiele.
    public static let target = "avpplayremote"
    public static let page = URL(string: "https://github.com/myMartek/avp-play-remote")!
    static let latestFeed = URL(string: "https://api.github.com/repos/myMartek/avp-play-remote/releases/latest")!

    public static func bundleId(prefix: String) -> String { Toolchain.bundleId(target: target, prefix: prefix) }

    public static func isCompanion(_ recipe: Recipe) -> Bool { recipe.id == recipeId }

    /// Eine veröffentlichte Fassung: ihr Git-Tag und die Versionsnummer darin.
    public struct Release: Sendable, Equatable {
        public var tag: String
        public var version: String
        public var page: URL?

        public init(tag: String, version: String, page: URL?) {
            self.tag = tag; self.version = version; self.page = page
        }
    }

    /// Liest GitHubs „neueste Veröffentlichung“. Das Tag wird Teil einer Adresse und eines Ordnernamens: nur
    /// Buchstaben, Ziffern, Punkt, Bindestrich, Unterstrich.
    public static func parseLatest(_ data: Data) -> Release? {
        struct Answer: Decodable { let tag_name: String; let html_url: String?; let draft: Bool?; let prerelease: Bool? }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data), a.draft != true, a.prerelease != true,
              isSafeTag(a.tag_name) else { return nil }
        let version = a.tag_name.hasPrefix("v") ? String(a.tag_name.dropFirst()) : a.tag_name
        guard version.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil else { return nil }
        return Release(tag: a.tag_name, version: version, page: a.html_url.flatMap(URL.init(string:)))
    }

    static func isSafeTag(_ tag: String) -> Bool {
        (1...40).contains(tag.count) && !tag.hasPrefix(".") && !tag.contains("..")
            && tag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// Die neueste Veröffentlichung auf GitHub.
    public static func latestRelease() async throws -> Release {
        var request = URLRequest(url: latestFeed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CompanionError.noRelease(status == 404 ? L("none published yet", "noch keine veröffentlicht") : "HTTP \(status)")
        }
        guard let release = parseLatest(data) else { throw CompanionError.noRelease(L("unreadable answer", "unlesbare Antwort")) }
        return release
    }

    /// Der Quellcode einer Fassung als Archiv, wie GitHub ihn zu jedem Tag bereithält.
    public static func sourceURL(tag: String) -> URL {
        URL(string: "https://codeload.github.com/\(repository)/tar.gz/refs/tags/\(tag)")!
    }

    /// Das Rezept eines Auftrags: keine Dateien, kein Store; die Fassung steht als Tag in `versionName`.
    public static func recipe(release: Release) -> Recipe {
        Recipe(schema: Recipe.supportedSchema, id: recipeId, title: title, package: "", versionName: release.tag, versionCode: 0,
               store: .init(appId: nil), toolchain: .init(target: target, minCommit: ""), files: [],
               status: .init(playability: "verified", download: "github"))
    }

    /// Wo AVP Play Quellcode, Bau und Signatur-Eintrag der App ablegt.
    public static var directory: URL { DataLocation.base.appendingPathComponent("companion", isDirectory: true) }

    /// Womit die App zuletzt installiert wurde und bis wann sie sich öffnen lässt.
    public static func signing() -> SigningRecord? { SigningRecord.read(directory.appendingPathComponent("signing.json")) }

    // MARK: Die Fassung mit „Auf dieser Brille“

    /// Welche Fassung der App AVP Play zuletzt gebaut und installiert hat.
    public struct Variant: Codable, Sendable, Equatable {
        public var bundleId: String
        public var tag: String
        /// Mit dem Teil, der Spiele allein auf der Brille installiert.
        public var standalone: Bool
        /// Die Toolchain, aus der ihr Übersetzer stammt („<Nummer>-<Commit>“). Die App baut Spiele nur mit der
        /// Laufzeit-Vorlage derselben Toolchain; nach einer neuen Toolchain muss sie neu gebaut werden.
        public var toolchain: String?

        public init(bundleId: String, tag: String, standalone: Bool, toolchain: String? = nil) {
            self.bundleId = bundleId; self.tag = tag; self.standalone = standalone; self.toolchain = toolchain
        }
    }

    static func variantFile(in directory: URL) -> URL { directory.appendingPathComponent("variant.json") }

    public static func variant(directory: URL = CompanionApp.directory) -> Variant? {
        (try? Data(contentsOf: variantFile(in: directory))).flatMap { try? JSONDecoder().decode(Variant.self, from: $0) }
    }

    /// Wie eine Toolchain in dieser Sache heißt: wie in den Namen ihrer Vorlagen.
    public static func toolchainStamp(_ toolchain: Toolchain) -> String { "\(toolchain.version())-\(toolchain.commit())" }

    /// Die fertigen Bibliotheken dieser Fassung, wie `Standalone/Vendor/libs.json` im Quellcode sie nennt: der Name
    /// der Datei am Release und ihre Prüfsumme.
    struct Libraries: Decodable, Equatable {
        var asset: String
        var sha256: String

        var isSane: Bool {
            Recipe.isSafeName(asset) && asset.hasSuffix(".zip") && sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
        }
    }

    static func librariesURL(tag: String, asset: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(asset)")!
    }

    /// Warum die installierte App neu gebaut werden sollte, obwohl ihre Fassung die neueste ist: Die Übergabe ist an,
    /// aber die App ist ohne den Teil dafür gebaut – oder für eine andere Toolchain als die, deren Vorlage sie bekommt.
    public static func rebuildReason(variant: Variant?, bundleId: String, handover: CompanionHandover.Plan?, freeTeam: Bool) -> String? {
        guard let handover, !freeTeam, let root = handover.toolchain, let toolchain = try? Toolchain(root: root),
              CompanionHandover.canBuildTemplate(toolchain) else { return nil }
        guard let variant, variant.bundleId == bundleId, variant.standalone else {
            return L("The installed app cannot install games by itself yet. “Install Again” builds it with that part.",
                     "Die installierte App kann Spiele noch nicht allein installieren. „Erneut installieren“ baut sie mit diesem Teil.")
        }
        let now = toolchainStamp(toolchain)
        guard variant.toolchain == now else {
            return L("The installed app was built for toolchain \(variant.toolchain ?? "?"); games are now built with \(now). “Install Again” builds it for the new one.",
                     "Die installierte App wurde für Toolchain \(variant.toolchain ?? "?") gebaut; Spiele werden jetzt mit \(now) gebaut. „Erneut installieren“ baut sie für die neue.")
        }
        return nil
    }

    // MARK: Stand auf dem Gerät

    public enum State: Sendable, Equatable {
        /// Kein Gerät erreichbar.
        case unknown
        case notInstalled
        case current(version: String)
        case updatable(installed: String, latest: String)
    }

    /// - Parameter latest: die neueste Fassung auf GitHub; ohne sie gilt eine installierte als aktuell.
    public static func state(apps: [InstalledApp]?, bundleId: String, latest: Release?) -> State {
        guard let apps else { return .unknown }
        guard let app = apps.first(where: { $0.bundleIdentifier == bundleId }) else { return .notInstalled }
        let installed = app.version ?? "?"
        if let latest, Updater.isNewer(latest.version, than: installed) { return .updatable(installed: installed, latest: latest.version) }
        return .current(version: installed)
    }
}

public enum CompanionError: Error, CustomStringConvertible, Equatable {
    case noRelease(String)
    case download(String)
    case sourceMissing
    case buildFailed(log: URL, hint: String)

    public var description: String {
        switch self {
        case .noRelease(let why):
            return L("The newest version of AVP Play Remote could not be found on GitHub: \(why).",
                     "Die neueste Fassung von AVP Play Remote ließ sich auf GitHub nicht finden: \(why).")
        case .download(let why):
            return L("The source code of AVP Play Remote could not be downloaded: \(why)",
                     "Der Quellcode von AVP Play Remote ließ sich nicht laden: \(why)")
        case .sourceMissing:
            return L("The downloaded source code contains no Xcode project.", "Der geladene Quellcode enthält kein Xcode-Projekt.")
        case .buildFailed(let log, let hint):
            return L("Building AVP Play Remote failed: \(hint) (full log: \(log.path))",
                     "Der Bau von AVP Play Remote ist gescheitert: \(hint) (vollständiges Protokoll: \(log.path))")
        }
    }
}

/// Führt einen Auftrag für AVP Play Remote aus: „Dateien laden“ holt den Quellcode, „Bauen und installieren“ baut
/// ihn mit Xcode und bringt die App aufs Gerät, und „Daten aufs Gerät kopieren“ übergibt ihr, wenn der Nutzer das
/// eingeschaltet hat, was sie braucht, um Spiele allein zu installieren. Die übrigen Schritte haben hier nichts zu tun.
public struct CompanionInstaller: Sendable {
    public let recipe: Recipe
    public let request: InstallRequest
    let control = DeviceControl()
    let report: @Sendable (String) -> Void
    let directory: URL
    /// Zum Entwickeln: ein Ordner mit dem Quellcode der App statt des Archivs von GitHub (`avpplay remote install
    /// --from`). Liegen darin die fertigen Bibliotheken, gelten sie; geladen wird dann nichts.
    public var localSource: URL?

    public init(recipe: Recipe, request: InstallRequest, directory: URL = CompanionApp.directory,
                report: @escaping @Sendable (String) -> Void) {
        self.recipe = recipe
        self.request = request
        self.directory = directory
        self.report = report
    }

    var tag: String { recipe.versionName }
    var sourceFolder: URL { directory.appendingPathComponent("source-\(tag)", isDirectory: true) }

    public func perform(_ step: InstallStep) async throws {
        switch step {
        case .fetch: try await fetch()
        case .build:
            // Wie bei den Spielen: Bauen und aufs Gerät bringen darf zur selben Zeit nur ein Programm.
            var lock = ProcessLock.acquire(ProcessLock.installURL)
            while lock == nil {
                try await Task.sleep(for: .seconds(2))
                lock = ProcessLock.acquire(ProcessLock.installURL)
            }
            defer { lock?.release() }
            try build()
        case .stage:
            // Die Übergabe baut beim ersten Mal die Laufzeit-Vorlage in der Toolchain: auch das nie zugleich mit einem Bau.
            guard request.handover != nil else { break }
            var lock = ProcessLock.acquire(ProcessLock.installURL)
            while lock == nil {
                try await Task.sleep(for: .seconds(2))
                lock = ProcessLock.acquire(ProcessLock.installURL)
            }
            defer { lock?.release() }
            try handOver()
        case .account, .unlock: break
        }
    }

    /// Die Übergabe nach dem Installieren. Nimmt die Remote keine an, ist der Auftrag deshalb nicht gescheitert: Die
    /// App ist installiert, und es wird gesagt.
    func handOver() throws {
        guard let plan = request.handover else { return }
        let device = try control.pick(udid: request.device)
        let bundle = request.bundleId ?? CompanionApp.bundleId(prefix: Toolchain.defaultBundlePrefix())
        // Hat AVP Play die App selbst mit dem Teil dafür gebaut, braucht es ihr Kennzeichen nicht: Gleich nach der
        // Installation, bevor sie je geöffnet wurde, gibt es das noch nicht.
        let own = CompanionApp.variant(directory: directory).map { $0.standalone && $0.bundleId == bundle } ?? false
        do {
            try CompanionHandover.deliver(plan, cache: directory.appendingPathComponent("templates", isDirectory: true), trusted: own,
                                          list: { try control.files(device: device, bundle: bundle, subdirectory: $0) },
                                          copy: { try control.copy($0, to: device, bundle: bundle, destination: $1) },
                                          report: report)
            report(L("AVP Play Remote takes it over at its next start.", "AVP Play Remote übernimmt es beim nächsten Start."))
        } catch CompanionHandover.HandoverError.notCapable {
            report(CompanionHandover.HandoverError.notCapable.description)
        }
    }

    /// Das Xcode-Projekt im entpackten Quellcode: GitHub packt alles in einen Ordner „<Projekt>-<Tag>“.
    func project() -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent("AVPPlayRemote.xcodeproj") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Die Fassung mit „Auf dieser Brille“

    static let standaloneProjectName = "AVPPlayRemoteStandalone.xcodeproj"
    static let libraryNames = ["libidevice_ffi.a", "probe_sign.o"]

    /// Der Ordner des Quellcodes (in dem die Projekte liegen).
    func sourceRoot() -> URL? { project()?.deletingLastPathComponent() }

    func librariesFolder(_ root: URL) -> URL { root.appendingPathComponent("Standalone/Vendor/lib/xros", isDirectory: true) }

    func libraries(_ root: URL) -> CompanionApp.Libraries? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Standalone/Vendor/libs.json")),
              let libraries = try? JSONDecoder().decode(CompanionApp.Libraries.self, from: data), libraries.isSane else { return nil }
        return libraries
    }

    /// Die Toolchain, für die die Fassung mit „Auf dieser Brille“ gebaut wird – oder warum es die einfache Fassung
    /// wird. Gefragt ist sie nur mit eingeschalteter Übergabe.
    func standaloneToolchain() -> (toolchain: Toolchain?, why: String?) {
        guard let plan = request.handover else { return (nil, nil) }
        if let team = request.team, AppleTeams.isFree(team) {
            return (nil, L("A free Apple team cannot build the part that installs games on the headset.",
                           "Ein kostenloses Apple-Team kann den Teil, der Spiele auf der Brille installiert, nicht bauen."))
        }
        guard let root = sourceRoot(), FileManager.default.fileExists(atPath: root.appendingPathComponent(CompanionInstaller.standaloneProjectName).path),
              libraries(root) != nil else {
            return (nil, L("Version \(tag) of AVP Play Remote cannot install games by itself.", "Die Fassung \(tag) von AVP Play Remote kann Spiele nicht allein installieren."))
        }
        guard let path = plan.toolchain, let toolchain = try? Toolchain(root: path), CompanionHandover.canBuildTemplate(toolchain),
              FileManager.default.fileExists(atPath: toolchain.root.appendingPathComponent("tools/klepton_ld.c").path) else {
            return (nil, L("The installed toolchain cannot build a runtime template yet; a newer toolchain can.",
                           "Die installierte Toolchain kann noch keine Laufzeit-Vorlage bauen; eine neuere kann es."))
        }
        return (toolchain, nil)
    }

    /// Holt die fertigen Bibliotheken der Fassung vom Release und prüft sie gegen die Prüfsumme im Quellcode.
    func fetchLibraries() async throws {
        guard request.handover != nil, let root = sourceRoot(), let libraries = libraries(root) else { return }
        let files = FileManager.default
        let folder = librariesFolder(root)
        let marker = folder.appendingPathComponent(".\(libraries.sha256)")
        if files.fileExists(atPath: marker.path), CompanionInstaller.libraryNames.allSatisfy({ files.fileExists(atPath: folder.appendingPathComponent($0).path) }) { return }
        report(L("Downloading the prebuilt libraries of version \(tag) from GitHub …", "Die fertigen Bibliotheken der Fassung \(tag) werden von GitHub geladen …"))
        let temp: URL, response: URLResponse
        do {
            (temp, response) = try await URLSession.shared.download(from: CompanionApp.librariesURL(tag: tag, asset: libraries.asset))
        } catch {
            throw CompanionError.download(error.localizedDescription)
        }
        defer { try? files.removeItem(at: temp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CompanionError.download("\(libraries.asset): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard try Hashing.sha256(of: temp) == libraries.sha256.lowercased() else {
            throw CompanionError.download(L("\(libraries.asset) does not have the checksum the source code names", "\(libraries.asset) hat nicht die Prüfsumme, die der Quellcode nennt"))
        }
        // Nur die zwei erwarteten Dateien, erst daneben entpackt.
        let unpacking = root.appendingPathComponent("Standalone/Vendor/.unpacking", isDirectory: true)
        try? files.removeItem(at: unpacking)
        try files.createDirectory(at: unpacking, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: unpacking) }
        let result = SigningWarmUp.run(["/usr/bin/unzip", "-q", "-o", temp.path] + CompanionInstaller.libraryNames + ["-d", unpacking.path], timeout: 120)
        guard result.status == 0 else { throw CompanionError.download(result.err.isEmpty ? "unzip \(result.status.map(String.init) ?? "?")" : result.err) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in CompanionInstaller.libraryNames {
            let target = folder.appendingPathComponent(name)
            try? files.removeItem(at: target)
            try files.moveItem(at: unpacking.appendingPathComponent(name), to: target)
        }
        for old in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix(".") && old.count == 65 {
            try? files.removeItem(at: folder.appendingPathComponent(old))
        }
        files.createFile(atPath: marker.path, contents: nil)
        report(L("Libraries are ready.", "Bibliotheken liegen bereit."))
    }

    /// Baut den Übersetzer aus der Toolchain, mit dem Skript der App. Er gehört zu genau dieser Toolchain.
    func buildTranslator(_ toolchain: Toolchain, root: URL, log: URL) throws {
        report(L("Building the translator of toolchain \(toolchain.name) …", "Der Übersetzer der Toolchain \(toolchain.name) wird gebaut …"))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("tools/build-engine.sh").path, "translator", toolchain.root.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.currentDirectoryURL = root
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: librariesFolder(root).appendingPathComponent("libkleptonld.a").path) else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let hint = text.split(separator: "\n").last(where: { $0.contains("error") }).map { String($0.prefix(300)) } ?? "build-engine.sh \(p.terminationStatus)"
            throw CompanionError.buildFailed(log: log, hint: hint)
        }
    }

    func fetch() async throws {
        guard CompanionApp.isSafeTag(tag) else { throw CompanionError.noRelease(tag) }
        if let localSource {
            // Eine Kopie ohne Bauordner und Geschichte, an der Stelle, an der sonst das entpackte Archiv liegt.
            try? FileManager.default.removeItem(at: sourceFolder)
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            let result = SigningWarmUp.run(["/usr/bin/rsync", "-a", "--exclude", "build", "--exclude", ".git", "--exclude", "target",
                                            "--exclude", "fastlane", "--exclude", "vendor", localSource.path + "/",
                                            sourceFolder.appendingPathComponent("local").path + "/"], timeout: 300)
            guard result.status == 0, project() != nil else { throw CompanionError.sourceMissing }
            report(L("Source code taken from \(localSource.path).", "Quellcode aus \(localSource.path) genommen."))
            return
        }
        if project() != nil {
            report(L("Source code of version \(tag) is already on this Mac.", "Quellcode der Fassung \(tag) liegt schon auf diesem Mac."))
            try await fetchLibraries()
            return
        }
        let url = CompanionApp.sourceURL(tag: tag)
        report(L("Downloading the source code of version \(tag) from GitHub …", "Quellcode der Fassung \(tag) wird von GitHub geladen …"))
        let temp: URL, response: URLResponse
        do {
            (temp, response) = try await URLSession.shared.download(from: url)
        } catch {
            throw CompanionError.download(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CompanionError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        // Erst daneben entpacken, dann umbenennen: Ein abgebrochener Versuch hinterlässt keinen halben Ordner.
        let unpacking = directory.appendingPathComponent(".unpacking-\(tag)", isDirectory: true)
        try? FileManager.default.removeItem(at: unpacking)
        try FileManager.default.createDirectory(at: unpacking, withIntermediateDirectories: true)
        let result = SigningWarmUp.run(["/usr/bin/tar", "-xzf", temp.path, "-C", unpacking.path], timeout: 120)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: unpacking)
            throw CompanionError.download(result.err.isEmpty ? "tar \(result.status.map(String.init) ?? "?")" : result.err)
        }
        try? FileManager.default.removeItem(at: sourceFolder)
        try FileManager.default.moveItem(at: unpacking, to: sourceFolder)
        guard project() != nil else { throw CompanionError.sourceMissing }
        report(L("Source code is ready.", "Quellcode liegt bereit."))
        try await fetchLibraries()
    }

    func build() throws {
        guard let team = request.team, team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw InstallError.teamMissing
        }
        guard let plain = project() else { throw CompanionError.sourceMissing }
        // Mit eingeschalteter Übergabe: die Fassung, die Spiele allein auf der Brille installiert – wenn alles dafür da ist.
        let standalone = standaloneToolchain()
        if let why = standalone.why { report(why + L(" The app is built without that part.", " Die App wird ohne diesen Teil gebaut.")) }
        let project = standalone.toolchain == nil ? plain : plain.deletingLastPathComponent().appendingPathComponent(CompanionInstaller.standaloneProjectName)
        let device = try control.pick(udid: request.device)
        let bundle = request.bundleId ?? CompanionApp.bundleId(prefix: Toolchain.defaultBundlePrefix(freeTeam: AppleTeams.isFree(team) ? team : nil))
        report(L("Device: \(device.name) (visionOS \(device.osVersion)); app: \(bundle); version: \(tag)",
                 "Gerät: \(device.name) (visionOS \(device.osVersion)); App: \(bundle); Fassung: \(tag)"))
        let apps = try? control.apps(device: device)
        // Eine Installation beendet die laufende App – auch die Fernbedienung, mit der vielleicht gerade jemand steuert.
        if request.replaceRunning != true, let app = apps?.first(where: { $0.bundleIdentifier == bundle }),
           let running = try? control.runningExecutables(device: device), DeviceControl.isRunning(app, executables: running) {
            throw InstallError.appRunning(recipe.title)
        }
        let free = AppleTeams.isFree(team)
        if free, let apps, let there = Installer.freeTeamBlock(bundle: bundle, apps: apps) {
            throw InstallError.freeTeamFull(recipe.title, installed: there)
        }
        // Ein neuer Bau verlängert die Signatur nur mit einem neuen Profil (siehe `SigningProfiles`).
        let staleTunnel = standalone.toolchain == nil ? 0
            : SigningProfiles.removeStale(team: team, bundleId: bundle + ".Tunnel", fresherThan: SigningProfiles.renewBelow(free: free))
        if SigningProfiles.removeStale(team: team, bundleId: bundle, fresherThan: SigningProfiles.renewBelow(free: free)) + staleTunnel > 0 {
            report(L("Signing: a new profile is requested from Apple, so that the app opens for the full time again.",
                     "Signatur: Bei Apple wird ein neues Profil angefordert, damit die App wieder die volle Zeit gilt."))
        }
        try SigningWarmUp.run(team: team, note: report)

        let started = Date()
        // Jede Fassung in ihrem eigenen Bauordner: Sie haben verschiedene Teile.
        let derived = directory.appendingPathComponent(standalone.toolchain == nil ? "build" : "build-standalone", isDirectory: true)
        let log = directory.appendingPathComponent("last-build.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let toolchain = standalone.toolchain {
            try buildTranslator(toolchain, root: project.deletingLastPathComponent(), log: log)
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        report(L("Building with Xcode …", "Wird mit Xcode gebaut …"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        // Die Fassung mit dem Tunnel hat zwei Teile mit eigener Kennung; sie nimmt die Kennung der App als eigene
        // Einstellung und hängt für den Tunnel „.Tunnel“ an.
        let identity = standalone.toolchain.map { ["AVPPLAY_REMOTE_BUNDLE_ID=\(bundle)", "AVPPLAY_TRANSLATOR_TOOLCHAIN=\(CompanionApp.toolchainStamp($0))"] }
            ?? ["PRODUCT_BUNDLE_IDENTIFIER=\(bundle)"]
        p.arguments = ["build", "-project", project.path, "-scheme", "AVPPlayRemote", "-configuration", "Release",
                       "-destination", "generic/platform=visionOS", "-derivedDataPath", derived.path, "-allowProvisioningUpdates",
                       "DEVELOPMENT_TEAM=\(team)", "CODE_SIGN_STYLE=Automatic"] + identity
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.currentDirectoryURL = project.deletingLastPathComponent()
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard p.terminationStatus == 0, text.contains("BUILD SUCCEEDED") else {
            if let refusal = AppleMessages.refusal(in: text) { throw ToolchainError.refused(refusal, free: free, log: log) }
            let hint = text.split(separator: "\n").last(where: { $0.contains("error:") }).map { String($0.prefix(300)) }
                ?? "xcodebuild \(p.terminationStatus)"
            throw CompanionError.buildFailed(log: log, hint: hint)
        }
        let app = derived.appendingPathComponent("Build/Products/Release-xros/AVPPlayRemote.app")
        report(L("Installing on the Vision Pro …", "Wird auf der Vision Pro installiert …"))
        try control.install(app: app, device: device)
        report(String(format: L("Built and installed (%.0f s).", "Gebaut und installiert (%.0f s)."), Date().timeIntervalSince(started)))

        let record = SigningRecord(team: team, free: free, installed: Date(),
                                   expires: SigningRecord.expiry(ofProfileAt: app.appendingPathComponent("embedded.mobileprovision")),
                                   bundleId: bundle)
        record.persist(to: directory.appendingPathComponent("signing.json"))
        let variant = CompanionApp.Variant(bundleId: bundle, tag: tag, standalone: standalone.toolchain != nil,
                                           toolchain: standalone.toolchain.map(CompanionApp.toolchainStamp))
        try? JSONEncoder().encode(variant).write(to: CompanionApp.variantFile(in: directory), options: .atomic)
        if free {
            let until = record.expires.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
            report(until.map { L("Signed with a free Apple team: the app opens until \($0). Install it again before then to renew it.",
                                 "Mit einem kostenlosen Apple-Team signiert: Die App lässt sich bis \($0) öffnen. Installiere sie vorher erneut, um sie zu erneuern.") }
                   ?? L("Signed with a free Apple team: the app opens for seven days. Install it again before then to renew it.",
                        "Mit einem kostenlosen Apple-Team signiert: Die App lässt sich sieben Tage lang öffnen. Installiere sie vorher erneut, um sie zu erneuern."))
        }
        report(L("On the headset, open AVP Play Remote and allow it to find devices in the local network; it then finds this Mac and asks for the pairing code from “Remote Control”.",
                 "Öffne auf dem Headset AVP Play Remote und erlaube ihr, Geräte im lokalen Netz zu finden; sie findet dann diesen Mac und fragt nach dem Code aus „Fernbedienung“."))
    }
}
