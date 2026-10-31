import CryptoKit
import Foundation
import IOKit

/// Die Antworten von Meta und Steam zu Besitz und Zusatzinhalten, verschlüsselt und an diesen Mac und das angemeldete
/// Konto gebunden. Nur diese Antworten gelten, wenn der Store nicht gefragt werden kann oder soll.
///
/// `ownership.json` und `.confirmed-purchases.json` liegen lesbar im Bestand und wandern mit, wenn jemand seine Spiele
/// weitergibt. Sie entscheiden deshalb nur, was angezeigt wird. Der Schlüssel eines Siegels entsteht aus drei Teilen,
/// von denen keiner im Bestand liegt: einem Geheimnis im Schlüsselbund, der Kennung des Macs und dem angemeldeten Konto.
/// Ein Siegel lässt sich also nicht auf einem anderen Mac oder mit einem anderen Konto öffnen und nicht von Hand anlegen.
/// Die Siegel liegen bei den Daten des Programms, nicht im Bestand.
///
/// Das ist ein Riegel gegen das Weitergeben, kein Kopierschutz: AVP Play ist quelloffen, und wer das Programm selbst
/// ändert, kommt daran vorbei. Die Kennung des Macs verlässt ihn nie, sie geht nur in den Schlüssel ein.
public struct OwnershipSeal: Sendable {
    public struct Answer: Codable, Sendable, Equatable {
        public var owned: Bool
        /// Die bestätigten Käufe im Spiel. `nil`: danach wurde noch nicht gefragt.
        public var skus: [String]?
        public var checked: Date
        public init(owned: Bool, skus: [String]? = nil, checked: Date = Date()) {
            self.owned = owned
            self.skus = skus
            self.checked = checked
        }
    }

    public static let service = "avpplay-seal"
    public static var defaultDirectory: URL { DataLocation.base.appendingPathComponent("seals", isDirectory: true) }

    let directory: URL
    let secret: Data
    let machine: String

    init(directory: URL, secret: Data, machine: String) {
        self.directory = directory
        self.secret = secret
        self.machine = machine
    }

    /// Für das angemeldete Meta-Konto: Dessen Token steht für das Konto. Ohne Anmeldung gibt es kein Siegel.
    public static func meta(account: String = "default") -> Bound? {
        guard let token = try? TokenStore().read(account: account) else { return nil }
        return here()?.bound(to: owner(metaToken: token))
    }

    /// Für das Steam-Konto, solange Valves Werkzeug eine Anmeldung dafür gemerkt hat.
    public static func steam(account: String, tool: SteamTool = SteamTool()) -> Bound? {
        guard SteamTool.isAccountName(account), tool.hasSession else { return nil }
        return here()?.bound(to: "steam:\(account)")
    }

    public func bound(to owner: String) -> Bound { Bound(seal: self, owner: owner) }

    /// Beim Abmelden: Die Antworten gehören zum Konto.
    public static func forgetAll(directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func owner(metaToken: String) -> String {
        "meta:" + SHA256.hash(data: Data(metaToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Ein Siegel mit dem Konto, dem es gilt.
    public struct Bound: Sendable {
        let seal: OwnershipSeal
        let owner: String

        func file(_ key: String) -> URL {
            let name = SHA256.hash(data: Data("\(owner)\n\(key)".utf8)).map { String(format: "%02x", $0) }.joined()
            return seal.directory.appendingPathComponent("\(name).seal")
        }

        private var symmetricKey: SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: seal.secret), salt: Data(seal.machine.utf8),
                                   info: Data("avpplay-seal-1\n\(owner)".utf8), outputByteCount: 32)
        }

        /// Die Antwort unter `key` (`OwnershipCache.key`). `nil`, wenn es keine gibt oder sie hier nicht zu öffnen ist –
        /// etwa weil sie von einem anderen Mac oder Konto stammt oder verändert wurde.
        public func read(key: String) -> Answer? {
            guard let data = try? Data(contentsOf: file(key)), let box = try? AES.GCM.SealedBox(combined: data),
                  let plain = try? AES.GCM.open(box, using: symmetricKey, authenticating: Data(key.utf8)) else { return nil }
            return try? JSONDecoder.iso.decode(Answer.self, from: plain)
        }

        /// Hält eine Antwort des Stores fest. Ohne neue Angabe zu den Käufen bleiben die bisher bestätigten.
        public func record(key: String, owned: Bool, skus: [String]? = nil, checked: Date = Date()) {
            let answer = Answer(owned: owned, skus: skus ?? read(key: key)?.skus, checked: checked)
            guard let plain = try? JSONEncoder.iso.encode(answer),
                  let box = try? AES.GCM.seal(plain, using: symmetricKey, authenticating: Data(key.utf8)), let data = box.combined else { return }
            try? FileManager.default.createDirectory(at: seal.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: file(key), options: .atomic)
        }
    }

    // MARK: Dieser Mac

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedSecret: Data?

    /// Das Siegel dieses Macs. `nil`, wenn der Schlüsselbund oder die Kennung des Macs nicht zu haben ist.
    static func here(directory: URL = defaultDirectory) -> OwnershipSeal? {
        guard let machine = machineID(), let secret = keychainSecret() else { return nil }
        return OwnershipSeal(directory: directory, secret: secret, machine: machine)
    }

    /// Das Geheimnis im Schlüsselbund, beim ersten Mal neu angelegt. Es liegt nirgends sonst.
    private static func keychainSecret() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let cachedSecret { return cachedSecret }
        let store = TokenStore(service: service)
        if let hex = try? store.read(), let data = Data(hex: hex) {
            cachedSecret = data
            return data
        }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard (try? store.write(token: fresh.map { String(format: "%02x", $0) }.joined())) != nil else { return nil }
        cachedSecret = fresh
        return fresh
    }

    /// Die Kennung dieses Macs, wie macOS sie aus der Hardware liest.
    static func machineID() -> String? {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard device != 0 else { return nil }
        defer { IOObjectRelease(device) }
        return IORegistryEntryCreateCFProperty(device, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count == 64 else { return nil }
        var bytes: [UInt8] = []
        var rest = Substring(hex)
        while !rest.isEmpty {
            guard let byte = UInt8(rest.prefix(2), radix: 16) else { return nil }
            bytes.append(byte)
            rest = rest.dropFirst(2)
        }
        self.init(bytes)
    }
}
