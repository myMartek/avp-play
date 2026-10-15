import Foundation

/// Womit eine Installation signiert wurde und bis wann sie sich öffnen lässt. visionOS startet eine App nur,
/// solange ihr Bereitstellungsprofil gilt: sieben Tage bei einem kostenlosen Team, ein Jahr bei einem bezahlten.
public struct SigningRecord: Codable, Sendable, Equatable {
    public var team: String
    public var free: Bool
    public var installed: Date
    /// Ablauf des Profils, das in der gebauten App steckt; `nil`, wenn es sich nicht lesen ließ.
    public var expires: Date?
    /// Unter welcher Kennung die App installiert wurde; fehlt bei Installationen vor dieser Angabe.
    public var bundleId: String?
    /// Wann der Hintergrunddienst zuletzt versucht hat, die Signatur zu erneuern, ohne dass sie länger gilt –
    /// und was dabei herauskam. Eine gelungene Erneuerung schreibt einen frischen Eintrag ohne diese Angaben.
    public var renewalTried: Date?
    public var renewalNote: String?

    public init(team: String, free: Bool, installed: Date, expires: Date?, bundleId: String? = nil) {
        self.team = team
        self.free = free
        self.installed = installed
        self.expires = expires
        self.bundleId = bundleId
    }

    /// Ab wann die App an die Erneuerung erinnert: zwei Tage vorher bei sieben Tagen, dreißig bei einem Jahr.
    public var remindFrom: Date? {
        expires.map { $0.addingTimeInterval(-(free ? 2 : 30) * 86_400) }
    }

    /// Der Name, den die Toolchain der App auf dem Gerät gab, wenn er ausdrücklich bestimmt war
    /// (`KLEPTON_DISPLAY_OVERRIDE` bzw. `KLEPTON_DISPLAY_SUFFIX`) – damit eine Erneuerung ihn beibehält.
    public var displayName: String?
    public var displaySuffix: String?

    /// Die Kennung, für die der Eintrag gilt: die gemerkte, sonst – bei Einträgen von vor dieser Angabe – die, unter
    /// der ein Team dieser Art üblicherweise installiert (wie `Renewal.installedBundle`).
    public func resolvedBundleId(target: String) -> String {
        if let bundleId, !bundleId.isEmpty { return bundleId }
        return free ? Toolchain.bundleId(target: target, prefix: Toolchain.defaultBundlePrefix(freeTeam: team))
                    : Toolchain.defaultBundleId(target: target)
    }

    // MARK: Ablage
    //
    // Je Kennung ein Eintrag (`.signing/<Kennung>.json` im Ordner des Spiels): Eine Testkopie unter eigener Kennung
    // überschreibt die Signatur der eigentlichen Installation nicht. Daneben bleibt `.signing.json` der Eintrag der
    // eigentlichen („live“) Installation – so wie bisher, damit ältere Fassungen dieses Programms ihn weiter lesen.
    // Was ohne Kennung fragt (Erneuern, Spielstände, Server), bekommt diesen.

    /// Der Eintrag der eigentlichen Installation (bis 1.1.16 der einzige je Spiel).
    public static func url(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent(".signing.json")
    }

    /// Der Eintrag für eine Kennung; `nil`, wenn die Kennung als Dateiname nicht taugt.
    public static func url(store: ContentStore, recipe: Recipe, bundleId: String) -> URL? {
        guard isSafeBundleId(bundleId) else { return nil }
        return store.directory(for: recipe).appendingPathComponent(".signing", isDirectory: true)
            .appendingPathComponent("\(bundleId).json")
    }

    static func isSafeBundleId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && !id.hasPrefix(".") && !id.contains("..")
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
    }

    /// Der Eintrag der eigentlichen Installation. Ein Eintrag aus der Zeit vor der Ablage je Kennung wird dabei
    /// auch unter seiner Kennung abgelegt (`migrate`).
    public static func load(store: ContentStore, recipe: Recipe) -> SigningRecord? {
        guard let record = read(url(store: store, recipe: recipe)) else { return nil }
        migrate(record, store: store, recipe: recipe)
        return record
    }

    /// Der Eintrag für eine Kennung; ohne Kennung der der eigentlichen Installation. Fehlt der eigene Eintrag, gilt
    /// der der eigentlichen Installation, sofern er dieselbe Kennung hat (ein Eintrag von vor der Ablage je Kennung).
    /// Liegen beide vor, gilt der jüngere: Eine ältere Fassung dieses Programms schreibt nur `.signing.json`, und
    /// der Eintrag unter der Kennung wäre dann veraltet. Er wird dabei aufgefrischt (`migrate`).
    public static func load(store: ContentStore, recipe: Recipe, bundleId: String?) -> SigningRecord? {
        guard let bundleId else { return load(store: store, recipe: recipe) }
        let own = url(store: store, recipe: recipe, bundleId: bundleId).flatMap(read)
        guard let live = read(url(store: store, recipe: recipe)), live.resolvedBundleId(target: recipe.toolchain.target) == bundleId,
              own.map({ live.installed > $0.installed }) ?? true else { return own }
        migrate(live, store: store, recipe: recipe)
        return live
    }

    /// Legt einen Eintrag der eigentlichen Installation unter seiner Kennung ab, wenn dort noch keiner liegt oder
    /// nur ein älterer – als Kopie, in einem Zug geschrieben; `.signing.json` bleibt, wie es ist.
    static func migrate(_ live: SigningRecord, store: ContentStore, recipe: Recipe) {
        let bundle = live.resolvedBundleId(target: recipe.toolchain.target)
        guard let target = url(store: store, recipe: recipe, bundleId: bundle) else { return }
        if let existing = read(target), existing.installed >= live.installed { return }
        var copy = live
        copy.bundleId = bundle
        copy.persist(to: target)
    }

    /// Speichert den Eintrag unter seiner Kennung und – ist er der der eigentlichen Installation – auch als diesen.
    /// - Parameter live: `nil` heißt: `isLive` entscheidet. Eine Testkopie unter einer anderen Kennung lässt den
    ///   Eintrag der eigentlichen Installation so unberührt.
    public func save(store: ContentStore, recipe: Recipe, live: Bool? = nil) {
        let target = recipe.toolchain.target
        let bundle = resolvedBundleId(target: target)
        let isLive = live ?? isLive(current: Self.read(Self.url(store: store, recipe: recipe)), target: target)
        var own = self
        own.bundleId = bundle
        if let url = Self.url(store: store, recipe: recipe, bundleId: bundle) { own.persist(to: url) }
        if isLive { persist(to: Self.url(store: store, recipe: recipe)) }
    }

    /// Ob dieser Eintrag ohne ausdrückliche Angabe der der eigentlichen Installation wird: wenn der bisherige dieselbe
    /// Kennung hat – oder, gibt es noch keinen, wenn er die übliche Kennung seines Teams trägt. Eine Testkopie unter
    /// eigener Kennung (`--bundle-id`) wird es also auch dann nicht, wenn das Spiel selbst noch keinen Eintrag hat.
    func isLive(current: SigningRecord?, target: String) -> Bool {
        let bundle = resolvedBundleId(target: target)
        if let current { return current.resolvedBundleId(target: target) == bundle }
        var usual = self
        usual.bundleId = nil
        return usual.resolvedBundleId(target: target) == bundle
    }

    /// Wohin Fehler beim Ablegen eines Eintrags gehen; ohne Angabe auf die Fehlerausgabe (wie `SigningWarmUp.run`).
    nonisolated(unsafe) static var note: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    /// Schreibt den Eintrag; schlägt das fehl, geht der Grund an `note` – die Installation selbst ist dann gelungen.
    func persist(to url: URL) {
        do {
            try write(to: url)
        } catch {
            Self.note(L("Could not save the signing record \(url.path): \(error.localizedDescription)",
                        "Signatur-Eintrag \(url.path) ließ sich nicht speichern: \(error.localizedDescription)"))
        }
    }

    static func read(_ url: URL) -> SigningRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SigningRecord.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Das Ablaufdatum aus einem Bereitstellungsprofil (`embedded.mobileprovision`): eine signierte Hülle um
    /// eine Property-Liste, die `security cms -D` auspackt.
    public static func expiry(ofProfileAt url: URL) -> Date? {
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? Toolchain.capture(["/usr/bin/security", "cms", "-D", "-i", url.path]) else { return nil }
        return expiry(inDecodedProfile: Data(text.utf8))
    }

    static func expiry(inDecodedProfile data: Data) -> Date? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }
}

/// Die Bereitstellungsprofile, die Xcode auf diesem Mac zwischenspeichert.
///
/// Am Gerät beobachtet (kostenloses Team, Xcode 27.1, 2026-10-11): Solange für eine App ein Profil im
/// Zwischenspeicher liegt, nimmt ein neuer Bau genau dieses – mit demselben Ablaufdatum. Ein Spiel „neu zu
/// installieren“ verlängert also nichts. Fehlt das Profil im Zwischenspeicher, holt `xcodebuild` eines bei Apple,
/// und Apple stellt dabei ein neues aus, das wieder die volle Zeit gilt. Deshalb wird vor einem Bau, der eine
/// Signatur erneuern soll, das zwischengespeicherte Profil genau dieser einen App entfernt – nichts sonst.
public enum SigningProfiles {
    public static var cacheDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true),
                home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles", isDirectory: true)]
    }

    struct Profile: Equatable {
        var applicationIdentifier: String
        var expires: Date?
        var managed: Bool
    }

    /// Packt ein Profil aus (eine signierte Hülle um eine Property-Liste).
    static func decode(_ url: URL) -> Data? {
        guard let text = try? Toolchain.capture(["/usr/bin/security", "cms", "-D", "-i", url.path]), !text.isEmpty else { return nil }
        return Data(text.utf8)
    }

    static func describe(_ decoded: Data) -> Profile? {
        guard let plist = try? PropertyListSerialization.propertyList(from: decoded, format: nil) as? [String: Any],
              let id = (plist["Entitlements"] as? [String: Any])?["application-identifier"] as? String else { return nil }
        return Profile(applicationIdentifier: id, expires: plist["ExpirationDate"] as? Date, managed: plist["IsXcodeManaged"] as? Bool ?? false)
    }

    /// Entfernt die von Xcode verwalteten, zwischengespeicherten Profile genau einer App, sofern sie nicht mehr
    /// länger als `fresherThan` gelten – ein Profil, das eben erst ausgestellt wurde, bleibt, damit nicht jeder Bau
    /// ein neues anfordert. Profile, die jemand von Hand angelegt hat, werden nie angefasst.
    /// - Returns: wie viele Dateien entfernt wurden
    @discardableResult
    public static func removeStale(team: String, bundleId: String, fresherThan: TimeInterval, now: Date = Date(),
                                   directories: [URL] = SigningProfiles.cacheDirectories) -> Int {
        removeStale(team: team, bundleId: bundleId, fresherThan: fresherThan, now: now, directories: directories, decode: decode)
    }

    static func removeStale(team: String, bundleId: String, fresherThan: TimeInterval, now: Date, directories: [URL],
                            decode: (URL) -> Data?) -> Int {
        guard team.count == 10, !bundleId.isEmpty else { return 0 }
        let wanted = "\(team).\(bundleId)"
        var removed = 0
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["mobileprovision", "provisionprofile"].contains(file.pathExtension) {
                guard let data = decode(file), let profile = describe(data), profile.managed,
                      profile.applicationIdentifier == wanted else { continue }
                if let expires = profile.expires, expires.timeIntervalSince(now) > fresherThan { continue }
                if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        return removed
    }

    /// Ab welcher Restlaufzeit ein Bau ein neues Profil anfordern soll: bei einem kostenlosen Team, sobald das alte
    /// einen Tag alt ist (sieben Tage sind kurz, und wer neu installiert, will die volle Woche); bei einem bezahlten
    /// erst im letzten Monat.
    public static func renewBelow(free: Bool) -> TimeInterval { (free ? 6 : 30) * 86_400 }
}

/// Eine einzelne Signatur vor dem Bau. Ein Signierschlüssel, den die Xcode-App aus dem App Store angelegt hat,
/// lässt macOS nachfragen, bevor `codesign` ihn benutzen darf – und der Bau signiert die App und Dutzende
/// eingebettete Bibliotheken gleichzeitig, sodass jedes wartende `codesign` sein eigenes Passwortfenster zeigt.
/// Eine Probe-Signatur vorher macht daraus höchstens ein Fenster; „Immer erlauben“ gilt dann für den ganzen Bau.
/// (Beobachtung und Vorgehen aus dem Projekt Glovebox, docs/SIGNING-PROMPTS.md, MIT-Lizenz.)
public enum SigningWarmUp {
    public enum Outcome: Equatable, Sendable {
        /// Es gibt auf diesem Mac noch keinen Schlüssel für das Team; Xcode legt beim Bau einen an, und der fragt nicht.
        case noKeyYet
        case signed
    }

    /// Die SHA-1-Kennungen der gültigen „Apple Development“-Identitäten dieses Teams, die neueste zuerst.
    static func identities(team: String, validIdentities: String, certificates: String,
                           subject: (String) -> String) -> [String] {
        let valid = Set(matches(of: "\\b[0-9A-F]{40}\\b", in: validIdentities))
        var found: [(Date, String)] = []
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        for block in certificates.components(separatedBy: "-----END CERTIFICATE-----") where block.contains("BEGIN CERTIFICATE") {
            guard let sha = matches(of: "SHA-1 hash: ([0-9A-F]{40})", in: block, group: 1).last, valid.contains(sha),
                  let start = block.range(of: "-----BEGIN CERTIFICATE-----") else { continue }
            let text = subject(String(block[start.lowerBound...]) + "-----END CERTIFICATE-----\n")
            guard matches(of: "OU=([A-Z0-9]{10})", in: text, group: 1).first == team else { continue }
            let begins = matches(of: "notBefore=(.*)", in: text, group: 1).first
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
                .flatMap { parser.date(from: $0) } ?? .distantPast
            found.append((begins, sha))
        }
        return found.sorted { $0.0 > $1.0 }.map(\.1)
    }

    static func matches(of pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range(at: group), in: text).map { String(text[$0]) } }
    }

    static func run(_ argv: [String], input: String? = nil, timeout: TimeInterval? = nil) -> (status: Int32?, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return (nil, "", "") }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        var outData = Data(), errData = Data()
        let readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: readers) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        if let timeout, done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            readers.wait()
            return (nil, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
        }
        if timeout == nil { done.wait() }
        readers.wait()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    private static func identities(team: String) -> [String] {
        identities(team: team,
                   validIdentities: run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).out,
                   certificates: run(["/usr/bin/security", "find-certificate", "-a", "-c", "Apple Development", "-Z", "-p"]).out,
                   subject: { run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-startdate", "-nameopt", "RFC2253"], input: $0).out })
    }

    /// - Parameter note: bekommt eine Zeile, wenn vor der Probe etwas zu richten war (`AppleIntermediate`); ohne
    ///   Angabe geht sie auf die Fehlerausgabe.
    @discardableResult
    public static func run(team: String, timeout: TimeInterval = 120,
                           note: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) throws -> Outcome {
        var ids = identities(team: team)
        // Kein gültiger Schlüssel, aber einer, dem nur Apples Zwischenzertifikat fehlt: Das ist kein Mac ohne
        // Schlüssel. Erst das Zertifikat holen, dann noch einmal nachsehen.
        // Gelingt das nicht, geht es weiter wie bisher – mit dem Grund als Zeile, denn der Bau scheitert dann
        // voraussichtlich an derselben Stelle, an der er ohne diesen Versuch gescheitert wäre.
        if ids.isEmpty, let gap = AppleIntermediate.missing(team: team) {
            do {
                note(try AppleIntermediate.add(gap.generation, for: gap.leaf))
                ids = identities(team: team)
            } catch { note("\(error)") }
        }
        guard let identity = ids.first else { return .noKeyYet }
        // Eine schlichte Datei, kein Programm: Ein Programm für zwei Architekturen bekäme zwei Signaturen, und
        // ein einfaches „Erlauben“ deckt nur eine davon.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-signing-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("signing-check")
        try Data("AVP Play\n".utf8).write(to: file)
        let result = run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none", file.path], timeout: timeout)
        guard let status = result.status else { throw ToolchainError.signingBlocked(L("macOS is still waiting for an answer", "macOS wartet noch auf eine Antwort")) }
        guard status == 0 else {
            throw ToolchainError.signingBlocked(result.err.split(separator: "\n").last.map(String.init) ?? "codesign \(status)")
        }
        return .signed
    }
}
