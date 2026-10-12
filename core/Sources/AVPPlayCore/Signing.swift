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

    public static func url(store: ContentStore, recipe: Recipe) -> URL {
        store.directory(for: recipe).appendingPathComponent(".signing.json")
    }

    public static func load(store: ContentStore, recipe: Recipe) -> SigningRecord? {
        guard let data = try? Data(contentsOf: url(store: store, recipe: recipe)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SigningRecord.self, from: data)
    }

    public func save(store: ContentStore, recipe: Recipe) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url(store: store, recipe: recipe), options: .atomic)
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

    @discardableResult
    public static func run(team: String, timeout: TimeInterval = 120) throws -> Outcome {
        let ids = identities(team: team,
                             validIdentities: run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).out,
                             certificates: run(["/usr/bin/security", "find-certificate", "-a", "-c", "Apple Development", "-Z", "-p"]).out,
                             subject: { run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-startdate", "-nameopt", "RFC2253"], input: $0).out })
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
