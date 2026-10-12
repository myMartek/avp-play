import Foundation

/// Ein eigener Spielserver des Nutzers: wo er zu erreichen ist und wie er in der Liste heißt.
public struct GameServer: Codable, Sendable, Equatable, Identifiable {
    /// `host:port`, schon in der Schreibweise, in der das Spiel ihn führt.
    public var address: String
    public var name: String
    public var id: String { address }

    public init(address: String, name: String) {
        self.address = address
        self.name = name
    }
}

/// Was ein Rezept sagt, wenn sein Spiel eine Liste eigener Server versteht: wohin die Liste auf dem Gerät gehört
/// und welchen Port ein Server hat, bei dem keiner genannt ist. Was das Spiel mit der Liste tut, ist Sache der
/// Toolchain (bei Counter-Strike: Favoriten, Admin-Zugang, Schnellmenü – siehe `kl_xashservers.c` im Fork).
public struct ServerListSupport: Codable, Sendable, Equatable {
    /// Zielordner unterhalb von `Documents/` im Datencontainer der App.
    public var dest: String
    public var file: String
    public var defaultPort: Int?
    /// Server, die jeder Spieler in der Liste hat, ohne sie einzutragen. Der Nutzer kann sie nicht entfernen,
    /// wohl aber ein Admin-Passwort dazu hinterlegen.
    public var builtin: [GameServer]?
}

public enum GameServerError: Error, CustomStringConvertible, Equatable {
    case notSupported(String)
    case badAddress(String)
    case badPassword
    case keychain(String)

    public var description: String {
        switch self {
        case .notSupported(let title):
            return L("\(title) has no list of servers.", "\(title) kennt keine Serverliste.")
        case .badAddress(let text):
            return L("“\(text)” is not a server address. Use a host name or an IP address, optionally with a port: play.example.org or 203.0.113.7:27015.",
                     "„\(text)“ ist keine Serveradresse. Erwartet wird ein Hostname oder eine IP-Adresse, auf Wunsch mit Port: play.example.org oder 203.0.113.7:27015.")
        case .badPassword:
            return L("An admin password may be up to 64 characters long and must not contain spaces, quotation marks or backslashes – the game sends it as a single word.",
                     "Ein Admin-Passwort darf bis zu 64 Zeichen lang sein und keine Leerzeichen, Anführungszeichen oder Rückstriche enthalten – das Spiel schickt es als ein einzelnes Wort.")
        case .keychain(let why):
            return L("The keychain did not take the admin password: \(why)", "Der Schlüsselbund hat das Admin-Passwort nicht angenommen: \(why)")
        }
    }
}

/// Die Serverlisten auf diesem Mac: Adressen und Namen als Datei je Spiel, die Admin-Passwörter im Schlüsselbund.
///
/// Ein Admin-Passwort ist ein Zugang, auch wenn es nur der zu einem Spielserver ist: Es steht deshalb in keiner
/// Datei dieses Programms, in keinem Auftrag und in keinem Protokoll. Auf das Gerät muss es trotzdem – das Spiel
/// schickt es dem Server –, und dort liegt es in der kleinen Liste im Datenbereich des Spiels.
public struct GameServerStore: Sendable {
    public static let keychainService = "avpplay-server"
    public let directory: URL
    public var service: String

    public init(directory: URL = DataLocation.base.appendingPathComponent("servers", isDirectory: true),
                service: String = GameServerStore.keychainService) {
        self.directory = directory
        self.service = service
    }

    func url(for recipe: Recipe) -> URL { directory.appendingPathComponent("\(recipe.id).json") }

    public func load(recipe: Recipe) -> [GameServer] {
        guard let data = try? Data(contentsOf: url(for: recipe)) else { return [] }
        return (try? JSONDecoder().decode([GameServer].self, from: data)) ?? []
    }

    public func save(_ servers: [GameServer], recipe: Recipe) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: url(for: recipe), options: .atomic)
    }

    /// `host` oder `host:port` in der Schreibweise des Spiels (`host:port`, klein); `nil`, wenn es keine Adresse ist.
    public static func normalize(_ text: String, defaultPort: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let host = parts.first, !host.isEmpty, host.count <= 80,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              host.first != "-", host.first != ".", host.last != "." else { return nil }
        let port = parts.count == 2 ? Int(parts[1]) : defaultPort
        guard let port, (1...65535).contains(port) else { return nil }
        return "\(host):\(port)"
    }

    /// Taugt der Text als Admin-Passwort? Ein Wort aus druckbaren ASCII-Zeichen, ohne Anführungszeichen und Rückstrich.
    public static func isUsablePassword(_ text: String) -> Bool {
        (1...64).contains(text.count)
            && text.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f && $0 != "\"" && $0 != "'" && $0 != "\\" }
    }

    /// Ein Name in der Liste: eine Zeile, höchstens 60 Zeichen.
    public static func cleanName(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(Character.init))
            .trimmingCharacters(in: .whitespaces).prefix(60).description
    }

    /// Die fest eingebauten Server des Rezepts, in der Schreibweise des Spiels.
    public static func builtin(recipe: Recipe) -> [GameServer] {
        guard let support = recipe.servers else { return [] }
        return (support.builtin ?? []).compactMap { server in
            normalize(server.address, defaultPort: support.defaultPort ?? 27015).map { GameServer(address: $0, name: server.name) }
        }
    }

    /// Alle Server, die das Spiel bekommt: die eingebauten, dann die des Nutzers (ohne Doppelte).
    public func all(recipe: Recipe) -> [GameServer] {
        let fixed = GameServerStore.builtin(recipe: recipe)
        return fixed + load(recipe: recipe).filter { own in !fixed.contains { $0.address == own.address } }
    }

    /// Fügt einen Server hinzu oder ändert seinen Namen. Die Adresse wird dabei vereinheitlicht. Ein eingebauter
    /// Server ist schon da; er wird nicht noch einmal geführt.
    @discardableResult
    public func add(address: String, name: String, recipe: Recipe) throws -> GameServer {
        guard let support = recipe.servers else { throw GameServerError.notSupported(recipe.title) }
        guard let normal = GameServerStore.normalize(address, defaultPort: support.defaultPort ?? 27015) else {
            throw GameServerError.badAddress(address)
        }
        if let fixed = GameServerStore.builtin(recipe: recipe).first(where: { $0.address == normal }) { return fixed }
        var list = load(recipe: recipe)
        let clean = GameServerStore.cleanName(name)
        let server = GameServer(address: normal, name: clean.isEmpty ? normal : clean)
        if let i = list.firstIndex(where: { $0.address == normal }) { list[i] = server } else { list.append(server) }
        try save(list, recipe: recipe)
        return server
    }

    /// Nimmt einen Server aus der Liste und sein Admin-Passwort aus dem Schlüsselbund.
    public func remove(address: String, recipe: Recipe) throws {
        var list = load(recipe: recipe)
        list.removeAll { $0.address == address }
        try save(list, recipe: recipe)
        try? setAdminPassword(nil, address: address, recipe: recipe)
    }

    // MARK: Schlüsselbund

    /// Der Name des Eintrags im Schlüsselbund: Spiel und Adresse, auf unverfängliche Zeichen beschränkt.
    static func account(recipe: Recipe, address: String) -> String {
        "\(recipe.id)-\(address)".map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") ? $0 : "_" }
            .prefix(120).map(String.init).joined()
    }

    public func adminPassword(address: String, recipe: Recipe) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", GameServerStore.account(recipe: recipe, address: address), "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return GameServerStore.isUsablePassword(text) ? text : nil
    }

    public func hasAdminPassword(address: String, recipe: Recipe) -> Bool { adminPassword(address: address, recipe: recipe) != nil }

    /// Legt das Admin-Passwort ab, ersetzt es oder – mit `nil` – löscht es. Es geht über die Standardeingabe an
    /// `security -i`, steht also in keinem Prozessargument, und wird danach zurückgelesen.
    public func setAdminPassword(_ password: String?, address: String, recipe: Recipe) throws {
        let account = GameServerStore.account(recipe: recipe, address: address)
        guard let password else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["delete-generic-password", "-s", service, "-a", account]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            return
        }
        guard GameServerStore.isUsablePassword(password) else { throw GameServerError.badPassword }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        input.fileHandleForWriting.write(Data("add-generic-password -U -s \(service) -a \(account) -w \(password)\n".utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0, adminPassword(address: address, recipe: recipe) == password else {
            throw GameServerError.keychain(L("the entry could not be read back", "der Eintrag ließ sich nicht zurücklesen"))
        }
    }

    // MARK: Für das Gerät

    /// Die Liste, wie das Spiel sie liest: je Server eine Zeile `server <Adresse> <Name>`, und wo ein
    /// Admin-Passwort hinterlegt ist, eine Zeile `admin <Adresse> <Passwort>`.
    public func deviceFile(recipe: Recipe, password: (String) -> String?) -> String {
        var lines = ["# avpplay-servers v1"]
        for server in all(recipe: recipe) {
            lines.append("server \(server.address) \(server.name)")
            if let secret = password(server.address) { lines.append("admin \(server.address) \(secret)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func deviceFile(recipe: Recipe) -> String {
        deviceFile(recipe: recipe) { adminPassword(address: $0, recipe: recipe) }
    }

    /// Bringt die Liste aufs Gerät, in den Datenbereich des installierten Spiels. Gilt ab dem nächsten Start des
    /// Spiels. Eine leere Liste wird nur übertragen, wenn dort schon eine liegt (um sie zu leeren).
    /// - Returns: ob übertragen wurde
    @discardableResult
    public func push(recipe: Recipe, device: Device, bundle: String, control: DeviceControl = DeviceControl()) throws -> Bool {
        guard let support = recipe.servers else { throw GameServerError.notSupported(recipe.title) }
        let folder = support.dest.isEmpty ? "Documents" : "Documents/\(support.dest)"
        let contents = Data(deviceFile(recipe: recipe).utf8)
        if all(recipe: recipe).isEmpty {
            let there = (try? control.files(device: device, bundle: bundle, subdirectory: folder)) ?? []
            guard there.contains(where: { !$0.isDirectory && $0.relativePath == support.file }) else { return false }
        }
        // Die Datei enthält Passwörter: nur für diesen Nutzer lesbar, und nach dem Kopieren wieder weg.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-servers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(support.file)
        guard FileManager.default.createFile(atPath: file.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try control.copy(file, to: device, bundle: bundle, destination: "\(folder)/\(support.file)")
        return true
    }
}
