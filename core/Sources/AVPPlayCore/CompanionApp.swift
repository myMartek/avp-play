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
/// ihn mit Xcode und bringt die App aufs Gerät. Die übrigen Schritte haben hier nichts zu tun.
public struct CompanionInstaller: Sendable {
    public let recipe: Recipe
    public let request: InstallRequest
    let control = DeviceControl()
    let report: @Sendable (String) -> Void
    let directory: URL

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
        case .account, .stage, .unlock: break
        }
    }

    /// Das Xcode-Projekt im entpackten Quellcode: GitHub packt alles in einen Ordner „<Projekt>-<Tag>“.
    func project() -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent("AVPPlayRemote.xcodeproj") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func fetch() async throws {
        guard CompanionApp.isSafeTag(tag) else { throw CompanionError.noRelease(tag) }
        if project() != nil {
            report(L("Source code of version \(tag) is already on this Mac.", "Quellcode der Fassung \(tag) liegt schon auf diesem Mac."))
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
    }

    func build() throws {
        guard let team = request.team, team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw InstallError.teamMissing
        }
        guard let project = project() else { throw CompanionError.sourceMissing }
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
        if SigningProfiles.removeStale(team: team, bundleId: bundle, fresherThan: SigningProfiles.renewBelow(free: free)) > 0 {
            report(L("Signing: a new profile is requested from Apple, so that the app opens for the full time again.",
                     "Signatur: Bei Apple wird ein neues Profil angefordert, damit die App wieder die volle Zeit gilt."))
        }
        try SigningWarmUp.run(team: team, note: report)

        let started = Date()
        let derived = directory.appendingPathComponent("build", isDirectory: true)
        let log = directory.appendingPathComponent("last-build.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        report(L("Building with Xcode …", "Wird mit Xcode gebaut …"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        p.arguments = ["build", "-project", project.path, "-scheme", "AVPPlayRemote", "-configuration", "Release",
                       "-destination", "generic/platform=visionOS", "-derivedDataPath", derived.path, "-allowProvisioningUpdates",
                       "DEVELOPMENT_TEAM=\(team)", "PRODUCT_BUNDLE_IDENTIFIER=\(bundle)", "CODE_SIGN_STYLE=Automatic"]
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
