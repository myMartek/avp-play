import Foundation

/// Was AVP Play für die Übergabe an AVP Play Remote im Schlüsselbund des Macs aufhebt: der Team-Schlüssel für
/// Apples Entwicklerkonto. Er liegt nie als Datei im Datenordner des Programms und verlässt den Schlüsselbund nur
/// für die Übergabe. (Die Kopplung mit der Brille macht die Remote auf der Brille selbst.)
///
/// Ein Eintrag ist ein Wort aus Base64-Zeichen: So nimmt `security` ihn auf demselben Weg an wie das Meta-Token.
public struct HandoverSecrets: Sendable {
    public static let appleKeyService = "avpplay-remote-apple-key"
    /// Größer ist kein Schlüssel.
    static let limit = 64 * 1024

    public var appleKeyService: String
    public var account: String

    public init(appleKeyService: String = HandoverSecrets.appleKeyService, account: String = "default") {
        self.appleKeyService = appleKeyService
        self.account = account
    }

    /// Der Team-Schlüssel für die App Store Connect API: zwei Kennungen und der Inhalt der Schlüsseldatei.
    public struct AppleKey: Codable, Sendable, Equatable {
        public var keyId: String
        public var issuerId: String
        /// Der Inhalt der Datei `AuthKey_<Kennung>.p8`.
        public var pem: String

        public init(keyId: String, issuerId: String, pem: String) {
            self.keyId = keyId
            self.issuerId = issuerId
            self.pem = pem
        }

        /// Kennungen, wie Apple sie vergibt, und eine Datei, die ein privater Schlüssel ist.
        public var isPlausible: Bool {
            keyId.count == 10 && keyId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && UUID(uuidString: issuerId) != nil
                && pem.contains("-----BEGIN PRIVATE KEY-----") && pem.contains("-----END PRIVATE KEY-----") && pem.utf8.count < HandoverSecrets.limit
        }
    }

    public enum SecretError: Error, CustomStringConvertible, Equatable {
        case badAppleKey
        case keychain(String)

        public var description: String {
            switch self {
            case .badAppleKey:
                return L("That is not a team key: it needs the key ID (10 characters), the issuer ID and the key file AuthKey_….p8 from App Store Connect.",
                         "Das ist kein Team-Schlüssel: Er braucht die Schlüssel-ID (10 Zeichen), die Issuer-ID und die Schlüsseldatei AuthKey_….p8 aus App Store Connect.")
            case .keychain(let why):
                return L("The keychain didn't accept the entry: \(why)", "Der Schlüsselbund hat den Eintrag nicht angenommen: \(why)")
            }
        }
    }

    // MARK: Team-Schlüssel

    public func appleKey() -> AppleKey? {
        guard let data = read(service: appleKeyService), let key = try? JSONDecoder().decode(AppleKey.self, from: data), key.isPlausible else { return nil }
        return key
    }

    public func setAppleKey(_ key: AppleKey?) throws {
        guard let key else { return delete(service: appleKeyService) }
        guard key.isPlausible else { throw SecretError.badAppleKey }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(try encoder.encode(key), service: appleKeyService)
    }

    // MARK: Schlüsselbund

    private func read(service: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func write(_ data: Data, service: String) throws {
        guard TokenStore.isSafeAccount(account), TokenStore.isSafeAccount(service), data.count < HandoverSecrets.limit else {
            throw SecretError.keychain(L("entry too large or badly named", "Eintrag zu groß oder falsch benannt"))
        }
        do {
            try TokenStore.security(interactive: "add-generic-password -U -s \(service) -a \(account) -w \(data.base64EncodedString())\n")
        } catch {
            throw SecretError.keychain("\(error)")
        }
        guard read(service: service) == data else {
            throw SecretError.keychain(L("entry not readable or truncated after writing", "Eintrag nach dem Schreiben nicht lesbar oder verkürzt"))
        }
    }

    private func delete(service: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", service, "-a", account]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }
}
