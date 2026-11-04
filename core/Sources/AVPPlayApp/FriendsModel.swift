import SwiftUI
import AVPPlayCore

/// Freunde: die Kennung dieses Macs beim Freundedienst, die Freunde mit ihrem Stand, die Angebote (geteilte Baue) in
/// beide Richtungen, und die zwei Abläufe – teilen und einspielen. Protokoll: docs/friends.md. Aus, bis der Nutzer es
/// einschaltet: Mit dem Dienst bekommt dieser Mac eine Kennung beim Server, was AVP Play sonst nirgends hat.
@MainActor
final class FriendsModel: ObservableObject {
    static let enabledKey = "friendsEnabled"
    @AppStorage(FriendsModel.enabledKey) var enabled = false
    @AppStorage("friendName") var name = NSFullUserName()
    @AppStorage("friendsLastSeq") private var lastSeq = 0

    @Published private(set) var me: FriendMe?
    @Published private(set) var statuses: [String: FriendStatus] = [:]          // je Freund (Kennung)
    @Published private(set) var offers: [String: FriendOfferRecord] = [:]        // je Spiel: das letzte Angebot an uns
    @Published private(set) var results: [String: [String: FriendResult]] = [:]  // je Spiel, je Freund: ihre Antwort
    @Published private(set) var connected = false
    @Published var notice: String?
    @Published private(set) var working: String?                                 // was gerade läuft (teilen/einspielen)
    @Published private(set) var progress: Double?
    @Published private(set) var ascKeyPresent = AppStoreConnectKey.load() != nil
    /// Die Geräte sind schon im Konto eingetragen (von Hand): dann wird die Connect-API nicht gebraucht.
    @AppStorage("friendsDevicesRegisteredByHand") var devicesRegisteredByHand = false

    private weak var model: AppModel?
    private var identity: FriendIdentity?
    private var client: FriendsClient?
    private var eventsTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var lastStatusSent: FriendStatus?

    struct FriendOfferRecord: Codable, Equatable {
        var from: String
        var fromName: String
        var offer: FriendOffer
        var received: Int64
        var installed: Bool
    }

    private let defaults = UserDefaults.standard

    init() {
        statuses = Self.load("friendStatuses") ?? [:]
        offers = Self.load("friendOffers") ?? [:]
        results = Self.load("friendResults") ?? [:]
        if let data = defaults.data(forKey: "friendMe") { me = try? JSONDecoder().decode(FriendMe.self, from: data) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // MARK: Start

    func attach(_ model: AppModel) {
        self.model = model
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        guard client == nil else { return }
        do {
            let identity = try FriendIdentity.load() ?? FriendIdentity.create()
            self.identity = identity
            client = FriendsClient(identity: identity)
        } catch {
            notice = L("Friend keys could not be made: \(error.localizedDescription)", "Freunde-Schlüssel ließen sich nicht anlegen: \(error.localizedDescription)")
            return
        }
        Task { await bootstrap() }
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.publishStatus() }
        }
    }

    private func stop() {
        eventsTask?.cancel(); eventsTask = nil
        statusTimer?.invalidate(); statusTimer = nil
        client = nil; identity = nil
        connected = false
    }

    /// Anmelden (oder den Namen erneuern), den Stand holen, Posteingang leeren, Ereignisstrom öffnen.
    private func bootstrap() async {
        guard let identity, let client else { return }
        do {
            if me == nil || me?.id != identity.id {
                let (id, code) = try await FriendsClient.register(identity: identity, name: name)
                me = FriendMe(id: id, code: code, name: name, friends: [], incoming: [], outgoing: [])
            }
            try await refreshMe()
            await drainInbox()
            await publishStatus(force: true)
            notice = nil
        } catch {
            notice = "\(error.localizedDescription)"
        }
        _ = client
        startEvents()
    }

    func refreshMe() async throws {
        guard let client else { return }
        let fresh = try await client.me()
        me = fresh
        save(fresh, "friendMe")
        // Freunde, die gegangen sind, nehmen ihren Stand mit.
        for id in statuses.keys where !fresh.friends.contains(where: { $0.id == id }) { statuses.removeValue(forKey: id) }
        save(statuses, "friendStatuses")
    }

    private func startEvents() {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            var backoff: UInt64 = 2
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                do {
                    try await client.events { [weak self] event in
                        await MainActor.run {
                            guard let self else { return }
                            self.connected = true
                            switch event.type {
                            case "message": Task { await self.drainInbox() }
                            case "request", "friend": Task { try? await self.refreshMe() }
                            default: break
                            }
                        }
                    }
                    backoff = 2
                } catch {
                    await MainActor.run { self.connected = false }
                }
                await MainActor.run { self.connected = false }
                // Ohne Strom: Posteingang und Stand im Abstand holen, dann neu verbinden.
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 120)
                await self.drainInbox()
                try? await self.refreshMe()
            }
        }
    }

    // MARK: Freunde

    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return }
        name = trimmed
        Task { do { try await client?.setName(trimmed); try await refreshMe() } catch { notice = error.localizedDescription } }
    }

    func newCode() {
        Task { do { _ = try await client?.newCode(); try await refreshMe() } catch { notice = error.localizedDescription } }
    }

    func addFriend(code: String) {
        Task {
            do {
                guard let client else { return }
                let r = try await client.request(code: code)
                notice = r.state == "friends"
                    ? L("You and \(r.name) are friends now.", "Du und \(r.name) seid jetzt Freunde.")
                    : L("Request sent to \(r.name). It appears on their Mac under Settings › Friends.", "Anfrage an \(r.name) geschickt. Sie erscheint auf dem Mac dort unter Einstellungen › Freunde.")
                try await refreshMe()
                await publishStatus(force: true)
            } catch { notice = error.localizedDescription }
        }
    }

    func accept(_ peer: FriendPeer) {
        Task {
            do { try await client?.accept(peer.id); try await refreshMe(); await publishStatus(force: true) }
            catch { notice = error.localizedDescription }
        }
    }

    func remove(_ peer: FriendPeer) {
        Task {
            do { try await client?.unlink(peer.id); try await refreshMe() }
            catch { notice = error.localizedDescription }
        }
    }

    // MARK: Der eigene Stand

    /// Was dieser Mac den Freunden sagt: welches der teilbaren Spiele ihm gehört, welches Headset dran ist, ob er bauen
    /// und teilen kann. Geschickt, wenn es sich geändert hat (oder `force`).
    func publishStatus(force: Bool = false) async {
        guard let client, let model, let me, !me.friends.isEmpty else { return }
        var games: [String: FriendStatus.Game] = [:]
        for game in model.allGames where game.recipe.toolchain.target == Toolchain.spatialPersonasTarget {
            if model.owned(game) == .yes {
                let checked = OwnershipCache.key(for: game.recipe).flatMap { model.ownership[$0]?.checked } ?? Date()
                games[game.id] = .init(owned: true, checked: Int64(checked.timeIntervalSince1970))
            } else {
                games[game.id] = .init(owned: false, checked: Int64(Date().timeIntervalSince1970))
            }
        }
        let device = model.device.map { FriendStatus.Device(udid: $0.udid, name: $0.name, os: $0.osVersion) }
        let status = FriendStatus(app: model.appVersion, games: games, device: device, canShare: canShare)
        var comparable = status; comparable.sent = 0
        var last = lastStatusSent; last?.sent = 0
        guard force || comparable != last else { return }
        var failed = false
        for peer in me.friends {
            do { try await client.send(status, kind: .status, to: peer) } catch { failed = true }
        }
        if !failed { lastStatusSent = status }
    }

    /// Ob dieser Mac einen SharePlay-Bau für Freunde machen kann: bezahltes Team, eine Toolchain mit Export und Personas.
    var canShare: Bool {
        guard let model, model.teamValid, model.team?.free != true, let toolchain = model.toolchain else { return false }
        return toolchain.supportsIPAExport && toolchain.supportsSpatialPersonas
    }

    // MARK: Posteingang

    func drainInbox() async {
        guard let client else { return }
        do {
            let messages = try await client.inbox(after: Int64(lastSeq))
            for m in messages {
                process(m, client: client)
                lastSeq = Int(m.seq)
            }
            if let last = messages.last { try? await client.ack(upTo: last.seq) }
        } catch {
            if case FriendError.unreachable = error { return }
            notice = error.localizedDescription
        }
    }

    private func process(_ m: FriendInboxMessage, client: FriendsClient) {
        guard let friend = me?.friends.first(where: { $0.id == m.from }) else { return }   // nur Freunde
        switch m.kind {
        case .status:
            guard let status = try? client.open(m, as: FriendStatus.self) else { return }
            if let old = statuses[m.from], old.sent > status.sent { return }
            statuses[m.from] = status
            save(statuses, "friendStatuses")
        case .offer:
            guard let offer = try? client.open(m, as: FriendOffer.self) else { return }
            if let old = offers[offer.game], old.offer.sent > offer.sent { return }
            offers[offer.game] = FriendOfferRecord(from: m.from, fromName: friend.name, offer: offer, received: m.created, installed: false)
            save(offers, "friendOffers")
            notice = L("\(friend.name) shares a build of \(offer.game == "walkabout" ? "Walkabout Mini Golf" : offer.game) with you – see the game's page.",
                       "\(friend.name) teilt einen Bau von \(offer.game == "walkabout" ? "Walkabout Mini Golf" : offer.game) mit dir – siehe die Seite des Spiels.")
        case .result:
            guard let result = try? client.open(m, as: FriendResult.self) else { return }
            results[result.game, default: [:]][m.from] = result
            save(results, "friendResults")
        }
    }

    // MARK: Teilen (die Seite mit dem bezahlten Team)

    /// Die Freunde, die für dieses Spiel in Frage kommen: sie besitzen es und nennen ein Headset.
    func candidates(for game: Game) -> [(peer: FriendPeer, status: FriendStatus)] {
        (me?.friends ?? []).compactMap { peer in
            guard let status = statuses[peer.id], status.games[game.id]?.owned == true, status.device != nil else { return nil }
            return (peer, status)
        }
    }

    func share(_ game: Game, with peers: [FriendPeer], note: String) {
        guard working == nil, let model, let client else { return }
        guard let toolchain = model.toolchain(for: game) else { return }
        let team = model.teamId
        let bundleId = Toolchain.bundleId(target: game.recipe.toolchain.target, prefix: model.bundlePrefix)
        let targets = peers.compactMap { peer -> (FriendPeer, FriendStatus.Device)? in
            guard let device = statuses[peer.id]?.device else { return nil }
            return (peer, device)
        }
        guard !targets.isEmpty else { return }
        let recipe = game.recipe
        let store = model.paths.store
        let folder = DataLocation.base.appendingPathComponent("friends/share", isDirectory: true)
        let key = AppStoreConnectKey.load()
        let byHand = devicesRegisteredByHand
        working = L("Preparing …", "Wird vorbereitet …"); progress = nil
        Task {
            defer { working = nil; progress = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // 1. Die Headsets im Konto.
                if !byHand {
                    guard let key else {
                        let list = targets.map { "\($0.0.name): \($0.1.udid)" }.joined(separator: "\n")
                        throw FriendsModelError.devicesNotRegistered(list)
                    }
                    let asc = AppStoreConnect(key: key)
                    for (peer, device) in targets {
                        working = L("Registering \(peer.name)’s headset in your Apple account …", "Trage \(peer.name)s Headset in dein Apple-Konto ein …")
                        _ = try await asc.register(udid: device.udid, name: "AVP Play – \(peer.name) – \(device.name)")
                    }
                }
                // 2. Der Bau – nach derselben Vorbereitung wie vor einer Installation (APK und Bäume in der Toolchain).
                working = L("Building the game for export (a few minutes) …", "Baue das Spiel für den Export (einige Minuten) …")
                let log = folder.appendingPathComponent("\(recipe.id).export.log")
                let ipa: URL = try await Task.detached(priority: .userInitiated) {
                    try toolchain.prepare(recipe: recipe, store: store)
                    let extra = TreeStore(store: store).toolchainEnvironment(recipe: recipe)
                    return try toolchain.exportIPA(recipe: recipe, team: team, bundleId: bundleId, log: log, extraEnvironment: extra,
                                                   spatialPersonas: true,
                                                   outputDirectory: folder.appendingPathComponent("export-\(recipe.id)", isDirectory: true))
                }.value
                let info = try IPAPackage.unpack(ipa, into: folder.appendingPathComponent("check-\(recipe.id)", isDirectory: true))
                let provisioned = Set((IPAPackage.provisionedDevices(app: info.app) ?? []).map { $0.uppercased() })
                let missing = targets.filter { !provisioned.contains($0.1.udid.uppercased()) }
                if !provisioned.isEmpty, !missing.isEmpty {
                    throw FriendsModelError.profileLacks(missing.map(\.0.name).joined(separator: ", "))
                }
                // 3. Versiegeln und hochladen.
                working = L("Sealing and uploading (\(ByteCountFormatter.string(fromByteCount: (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int64) ?? 0, countStyle: .file))) …",
                            "Versiegeln und hochladen (\(ByteCountFormatter.string(fromByteCount: (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int64) ?? 0, countStyle: .file))) …")
                let blobKey = FriendBlobCipher.newKey()
                let sealed = folder.appendingPathComponent("\(recipe.id).blob")
                let sha = try FriendBlobCipher.seal(file: ipa, to: sealed, key: blobKey)
                let size = (try? FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int64) ?? 0
                let (blobId, expires) = try await client.upload(blob: sealed)
                try? FileManager.default.removeItem(at: sealed)
                // 4. Das Angebot an jeden.
                let offer = FriendOffer(game: game.id, blob: blobId, key: blobKey.base64EncodedString(), sha256: sha, size: size,
                                        bundleId: info.bundleId, stamp: info.build, appVersion: info.version, toolchain: toolchain.version(),
                                        spatialPersonas: true, note: note, sent: Int64(Date().timeIntervalSince1970), expires: expires)
                var sentTo: [String] = []
                for (peer, _) in targets {
                    working = L("Sending the offer to \(peer.name) …", "Schicke das Angebot an \(peer.name) …")
                    try await client.send(offer, kind: .offer, to: peer)
                    results[game.id, default: [:]][peer.id] = FriendResult(game: game.id, blob: blobId, state: .declined, detail: "pending")
                    sentTo.append(peer.name)
                }
                save(results, "friendResults")
                notice = L("Shared with \(sentTo.joined(separator: ", ")). Each of them sees the offer on Walkabout’s page and answers here when it is installed.",
                           "Geteilt mit \(sentTo.joined(separator: ", ")). Jeder sieht das Angebot auf Walkabouts Seite und meldet hier, wenn es eingespielt ist.")
            } catch let error as ToolchainError {
                notice = L("Sharing failed: \(FriendsModel.describe(error))", "Teilen fehlgeschlagen: \(FriendsModel.describe(error))")
            } catch {
                notice = L("Sharing failed: \(error.localizedDescription)", "Teilen fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    /// Ein Toolchain-Fehler mit dem, was im Protokoll steht, statt seiner Nummer.
    static func describe(_ error: ToolchainError) -> String {
        switch error {
        case .buildFailed(let log, let hint):
            return L("the build failed\(hint.isEmpty ? "" : ": " + hint) (log: \(log.path))", "der Bau ist fehlgeschlagen\(hint.isEmpty ? "" : ": " + hint) (Protokoll: \(log.path))")
        case .installFailed(let log, let hint):
            return L("installing failed\(hint.isEmpty ? "" : ": " + hint) (log: \(log.path))", "das Einspielen ist fehlgeschlagen\(hint.isEmpty ? "" : ": " + hint) (Protokoll: \(log.path))")
        case .refused(let refusal, _, let log):
            return L("Apple refused: \(refusal) (log: \(log.path))", "Apple hat abgelehnt: \(refusal) (Protokoll: \(log.path))")
        default:
            return "\(error)"
        }
    }

    // MARK: Einspielen (die Seite des Freunds)

    func offer(for game: Game) -> FriendOfferRecord? { offers[game.id] }

    func decline(_ game: Game) {
        guard let record = offers[game.id], let client, let peer = me?.friends.first(where: { $0.id == record.from }) else { return }
        offers.removeValue(forKey: game.id); save(offers, "friendOffers")
        Task { try? await client.send(FriendResult(game: game.id, blob: record.offer.blob, state: .declined, detail: ""), kind: .result, to: peer) }
    }

    /// Das Angebot einspielen: erst den Besitz noch einmal bei Meta bestätigen lassen, dann laden, öffnen, prüfen,
    /// installieren, die Dateien aus dem eigenen Kauf nachziehen.
    func install(_ game: Game) {
        guard working == nil, let model, let client, let record = offers[game.id] else { return }
        let peer = me?.friends.first(where: { $0.id == record.from })
        let offer = record.offer
        working = L("Asking \(AppModel.name(game.recipe.source)) whether you own the game …", "Frage \(AppModel.name(game.recipe.source)), ob dir das Spiel gehört …")
        Task {
            defer { working = nil; progress = nil }
            func report(_ state: FriendResult.State, _ detail: String) async {
                if let peer { try? await client.send(FriendResult(game: game.id, blob: offer.blob, state: state, detail: detail), kind: .result, to: peer) }
            }
            do {
                // 1. Der Besitz, frisch.
                guard let device = model.device else { throw FriendsModelError.noDevice }
                let owned = await confirmOwnership(game)
                guard owned == .yes else {
                    let why = owned == .no
                        ? L("\(AppModel.name(game.recipe.source)) says this account does not own the game. A shared build is only for players who own it.",
                            "\(AppModel.name(game.recipe.source)) sagt, dieses Konto besitzt das Spiel nicht. Ein geteilter Bau ist nur für Spieler, die es besitzen.")
                        : L("Could not confirm with \(AppModel.name(game.recipe.source)) that you own the game. Sign in under “Setup” and try again.",
                            "Konnte bei \(AppModel.name(game.recipe.source)) nicht bestätigen, dass dir das Spiel gehört. Melde dich unter „Einrichtung“ an und versuche es noch einmal.")
                    await report(.failed, "ownership not confirmed")
                    throw FriendsModelError.plain(why)
                }
                // 2. Laden und öffnen.
                let folder = DataLocation.base.appendingPathComponent("friends/receive", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let sealed = folder.appendingPathComponent("\(offer.blob).blob"), ipa = folder.appendingPathComponent("\(offer.blob).ipa")
                working = L("Downloading \(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file)) …", "Lade \(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file)) …")
                try await client.download(blob: offer.blob, to: sealed)
                working = L("Opening the package …", "Öffne das Paket …")
                guard let key = Data(base64Encoded: offer.key), key.count == 32 else { throw FriendError.malformed }
                let sha = try FriendBlobCipher.open(file: sealed, to: ipa, key: key)
                try? FileManager.default.removeItem(at: sealed)
                guard sha == offer.sha256.lowercased() else { throw FriendsModelError.plain(L("The package is not what was offered (checksum).", "Das Paket ist nicht das angebotene (Prüfsumme).")) }
                let info = try IPAPackage.unpack(ipa, into: folder.appendingPathComponent("app-\(game.id)", isDirectory: true))
                guard info.bundleId == offer.bundleId, info.build == offer.stamp else {
                    throw FriendsModelError.plain(L("The package names another app (\(info.bundleId) \(info.build)).", "Das Paket nennt eine andere App (\(info.bundleId) \(info.build))."))
                }
                if let provisioned = IPAPackage.provisionedDevices(app: info.app), !provisioned.map({ $0.uppercased() }).contains(device.udid.uppercased()) {
                    throw FriendsModelError.plain(L("This build is not made for your headset (\(device.name)): \(record.fromName) has to add it and share again.",
                                                    "Dieser Bau ist nicht für dein Headset (\(device.name)) gemacht: \(record.fromName) muss es aufnehmen und noch einmal teilen."))
                }
                // 3. Einspielen.
                working = L("Installing on \(device.name) …", "Installiere auf \(device.name) …")
                try await Task.detached { try DeviceControl().install(app: info.app, device: device) }.value
                try? FileManager.default.removeItem(at: ipa)
                // 4. Ab jetzt ist das Spiel unter dieser Kennung installiert; die Dateien kommen aus dem eigenen Kauf.
                model.setSharedInstall(game, bundleId: info.bundleId, stamp: info.build, from: record.fromName)
                offers[game.id]?.installed = true; save(offers, "friendOffers")
                model.enqueue(game, steps: InstallStep.addonSync)
                await report(.installed, "\(info.build)")
                notice = L("\(record.fromName)’s build is on \(device.name). The game’s files (about 15 GB for Walkabout) are being copied from your own purchase now – see “Jobs”. Do not start the game before that job has finished: without its files it opens to a black picture.",
                           "\(record.fromName)s Bau ist auf \(device.name). Die Dateien des Spiels (bei Walkabout etwa 15 GB) werden jetzt aus deinem eigenen Kauf kopiert – siehe „Aufträge“. Starte das Spiel erst, wenn dieser Auftrag fertig ist: Ohne seine Dateien bleibt das Bild schwarz.")
            } catch {
                notice = L("Installing failed: \(error.localizedDescription)", "Einspielen fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    /// Die Besitzfrage an den Store, frisch – wie vor jeder Installation. Wartet auf die Antwort.
    private func confirmOwnership(_ game: Game) async -> Owned {
        guard let model else { return .unknown }
        model.checkPurchase(game)
        for _ in 0..<120 {   // bis zu einer Minute
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !model.checkingPurchase.contains(game.id) { break }
        }
        return model.owned(game)
    }

    // MARK: Der Connect-Schlüssel

    func saveASCKey(issuerId: String, keyId: String, p8: URL) {
        do {
            let pem = try String(contentsOf: p8, encoding: .utf8)
            try AppStoreConnectKey(issuerId: issuerId.trimmingCharacters(in: .whitespaces), keyId: keyId.trimmingCharacters(in: .whitespaces), pem: pem).save()
            ascKeyPresent = true
            notice = L("App Store Connect key saved in the keychain.", "App-Store-Connect-Schlüssel im Schlüsselbund gespeichert.")
        } catch {
            notice = L("The key was not saved: \(error.localizedDescription)", "Der Schlüssel wurde nicht gespeichert: \(error.localizedDescription)")
        }
    }

    func forgetASCKey() {
        AppStoreConnectKey.forget()
        ascKeyPresent = false
    }
}

enum FriendsModelError: Error, LocalizedError {
    case devicesNotRegistered(String)
    case profileLacks(String)
    case noDevice
    case plain(String)

    var errorDescription: String? {
        switch self {
        case .devicesNotRegistered(let list):
            return L("the friends’ headsets are not in your Apple account yet. Either add an App Store Connect key under Settings › Friends, or register them at developer.apple.com/account/resources/devices and tick “registered by hand”:\n\(list)",
                     "die Headsets der Freunde sind noch nicht in deinem Apple-Konto. Entweder unter Einstellungen › Freunde einen App-Store-Connect-Schlüssel hinterlegen, oder sie unter developer.apple.com/account/resources/devices eintragen und „von Hand eingetragen“ anhaken:\n\(list)")
        case .profileLacks(let names):
            return L("the profile Xcode made does not cover the headset of \(names). Register it and share again.",
                     "das Profil von Xcode deckt das Headset von \(names) nicht ab. Trage es ein und teile noch einmal.")
        case .noDevice:
            return L("no Vision Pro is connected", "keine Vision Pro ist verbunden")
        case .plain(let text): return text
        }
    }
}
