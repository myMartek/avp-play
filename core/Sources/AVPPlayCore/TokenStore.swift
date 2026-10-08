import Foundation

public enum TokenError: Error, CustomStringConvertible {
    case notFound(account: String)
    case malformed
    case badAccountName
    case keychain(String)

    public var description: String {
        switch self {
        case .notFound(let a):
            return L("No Meta token is stored in the keychain for the account '\(a)'.",
                     "Für das Konto '\(a)' ist kein Meta-Token im Schlüsselbund hinterlegt.")
        case .malformed: return L("The Meta token has an unexpected form.", "Der Meta-Token hat eine unerwartete Form.")
        case .badAccountName:
            return L("The account name may only contain letters, digits, '-' and '_'.",
                     "Der Kontoname darf nur aus Buchstaben, Ziffern, '-' und '_' bestehen.")
        case .keychain(let why): return L("The keychain didn't accept the entry: \(why)", "Der Schlüsselbund hat den Eintrag nicht angenommen: \(why)")
        }
    }
}

/// Liest den Meta-Token aus dem macOS-Schlüsselbund.
///
/// Solange es nur das Kommandozeilenwerkzeug gibt, geht der Zugriff über `/usr/bin/security`: Die Einträge
/// wurden damit angelegt, und ein bei jedem Build neu signiertes Entwicklungsprogramm würde sonst bei jedem
/// Lauf eine Freigabe im Schlüsselbund auslösen. Der Token kommt über eine Pipe zurück, nie über Argumente.
/// Die spätere Mac-App legt ihre Einträge selbst an und liest sie direkt.
public struct TokenStore: Sendable {
    public static let defaultService = "avpplay-meta"
    /// Der Eintrag aus der Zeit vor dem Namen „AVP Play“.
    static let legacyService = "questinstaller-meta"

    public var service: String
    public init(service: String = TokenStore.defaultService) { self.service = service }

    /// Liest den Token. Liegt er noch unter dem früheren Namen, zieht er dabei um: unter dem neuen Namen
    /// ablegen, zurücklesen, erst dann den alten Eintrag löschen.
    public func read(account: String = "default") throws -> String {
        do {
            return try read(service: service, account: account)
        } catch TokenError.notFound where service == TokenStore.defaultService {
            return try adoptLegacy(from: TokenStore.legacyService, account: account)
        }
    }

    func adoptLegacy(from legacy: String, account: String) throws -> String {
        guard let token = try? read(service: legacy, account: account) else { throw TokenError.notFound(account: account) }
        try write(token: token, account: account)
        _ = try? TokenStore(service: legacy).delete(account: account)
        return token
    }

    private func read(service: String, account: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TokenError.notFound(account: account) }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Ein Token ist eine einzelne Zeile aus Buchstaben und Ziffern. Alles andere wird nicht verschickt.
        guard TokenStore.isPlausible(token) else { throw TokenError.malformed }
        return token
    }

    public static func isPlausible(_ token: String) -> Bool {
        token.count >= 32 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func isSafeAccount(_ account: String) -> Bool {
        !account.isEmpty && account.count <= 64
            && account.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Legt den Token ab oder ersetzt ihn. Er geht über die Standardeingabe an `security -i`, steht also in
    /// keinem Prozessargument; und er wird nie über die verdeckte Abfrage von `security` eingelesen, die bei
    /// 128 Zeichen abschneidet. Danach wird zurückgelesen: abgelegt ist nur, was unverkürzt wieder herauskommt.
    public func write(token: String, account: String = "default") throws {
        guard TokenStore.isPlausible(token) else { throw TokenError.malformed }
        guard TokenStore.isSafeAccount(account), TokenStore.isSafeAccount(service) else { throw TokenError.badAccountName }
        try TokenStore.security(interactive: "add-generic-password -U -s \(service) -a \(account) -w \(token)\n")
        guard (try? read(service: service, account: account)) == token else {
            throw TokenError.keychain(L("entry not readable or truncated after writing", "Eintrag nach dem Schreiben nicht lesbar oder verkürzt"))
        }
    }

    /// Löscht den Eintrag dieses Werkzeugs. Andere Einträge im Schlüsselbund werden nie angefasst.
    @discardableResult
    public func delete(account: String = "default") throws -> Bool {
        guard TokenStore.isSafeAccount(account), TokenStore.isSafeAccount(service) else { throw TokenError.badAccountName }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", service, "-a", account]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func security(interactive command: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        input.fileHandleForWriting.write(Data(command.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw TokenError.keychain(L("security exited with status \(p.terminationStatus)", "security endete mit Status \(p.terminationStatus)"))
        }
    }
}
