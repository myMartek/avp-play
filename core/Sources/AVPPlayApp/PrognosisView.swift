import AVPPlayCore
import SwiftUI

extension AppModel {
    /// Die Prognose für ein ungetestetes Spiel, sobald sein APK auf diesem Mac liegt. Rechnet im Hintergrund: den
    /// Fingerabdruck des APKs (zwischengespeichert neben ihm), die Namen der installierten Toolchain und die
    /// mitgelieferten Fingerabdrücke der geprüften Spiele.
    func loadPrognosis(_ game: Game) {
        guard prognoses[game.id] == nil, !prognosisRunning.contains(game.id),
              let apkFile = game.recipe.files.first(where: { $0.role == "apk" }),
              let toolchain = toolchain, let recipes = paths.recipes else { return }
        let apk = paths.store.url(for: apkFile, in: game.recipe)
        guard FileManager.default.fileExists(atPath: apk.path) else { return }
        prognosisRunning.insert(game.id)
        let root = toolchain.root
        let cached = runtimeInterfaces[root.path]
        Task.detached(priority: .utility) {
            let fingerprint = try? Fingerprint.cached(apk: apk)
            let result: (Prognosis, RuntimeInterface)? = {
                guard let fingerprint, let runtime = cached ?? (try? RuntimeInterface.scan(klepton: root)) else { return nil }
                let references = ReferenceFingerprint.bundled(recipes: recipes)
                guard !references.isEmpty else { return nil }
                return (Prognosis.make(fingerprint, runtime: runtime, references: references), runtime)
            }()
            await MainActor.run {
                self.prognosisRunning.remove(game.id)
                if let fingerprint { self.shareFingerprint(fingerprint, of: game.recipe) }
                guard let (prognosis, runtime) = result else { return }
                self.runtimeInterfaces[root.path] = runtime
                self.prognoses[game.id] = prognosis
            }
        }
    }
}

extension AppModel {
    /// Schickt den Fingerabdruck eines Builds einmal an den Katalogdienst – nur mit eingeschaltetem Teilen.
    func shareFingerprint(_ fingerprint: Fingerprint, of recipe: Recipe) {
        let key = "sharedFingerprints"
        guard shareFingerprints, onlineCatalog,
              let game = UsagePing.gameKey(appId: recipe.catalogAppId, recipe: recipe.id) else { return }
        let build = "\(game)@\(recipe.versionCode)"
        guard !(UserDefaults.standard.stringArray(forKey: key) ?? []).contains(build) else { return }
        let client = catalogClient, versionCode = Int64(recipe.versionCode)
        Task {
            guard (try? await client.share(SharedFingerprint(fingerprint), game: game, versionCode: versionCode)) != nil else { return }
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []) + [build], forKey: key)
        }
    }
}

/// Die Zeile im Kasten eines ungetesteten Spiels: die Aussicht, darunter auf Wunsch die Einzelheiten.
struct PrognosisRow: View {
    @EnvironmentObject var model: AppModel
    let game: Game

    var body: some View {
        Group {
            if let p = model.prognoses[game.id] {
                VStack(alignment: .leading, spacing: 6) {
                    Label(p.summary, systemImage: symbol(p.outlook))
                        .font(.callout)
                        .foregroundStyle(color(p.outlook))
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L("How this is estimated", "Wie das geschätzt wird")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("AVP Play compares the names of what the game uses (engine, graphics, VR interfaces, functions) with the toolchain and with the verified games. Only names are read from the game, nothing leaves this Mac. Server checks and anti-cheat cannot be seen this way.",
                                   "AVP Play vergleicht die Namen dessen, was das Spiel benutzt (Engine, Grafik, VR-Schnittstellen, Funktionen), mit der Toolchain und mit den geprüften Spielen. Aus dem Spiel werden nur Namen gelesen, nichts verlässt diesen Mac. Server-Prüfungen und Anti-Cheat lassen sich so nicht erkennen."))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(p.neighbours, id: \.id) { n in
                                Text(L("Similar: \(n.title) (\(Int((n.similarity * 100).rounded())) %)", "Ähnlich: \(n.title) (\(Int((n.similarity * 100).rounded())) %)"))
                            }
                            let unusual = p.unusualFunctions + p.unusualExtensions
                            if !unusual.isEmpty {
                                Text(L("Not known to the toolchain: \(unusual.prefix(8).joined(separator: ", "))\(unusual.count > 8 ? " …" : "")",
                                       "Der Toolchain unbekannt: \(unusual.prefix(8).joined(separator: ", "))\(unusual.count > 8 ? " …" : "")"))
                                    .textSelection(.enabled)
                            }
                        }
                        .font(.caption)
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            } else if model.prognosisRunning.contains(game.id) {
                HStack { ProgressView().controlSize(.small); Text(L("Comparing with the verified games …", "Wird mit den geprüften Spielen verglichen …")).font(.callout) }
            }
        }
        .onAppear { model.loadPrognosis(game) }
    }

    private func symbol(_ outlook: Prognosis.Outlook) -> String {
        switch outlook {
        case .likely: return "hand.thumbsup"
        case .possible: return "questionmark.diamond"
        case .unlikely: return "exclamationmark.triangle"
        }
    }

    private func color(_ outlook: Prognosis.Outlook) -> Color {
        switch outlook {
        case .likely: return .green
        case .possible: return .primary
        case .unlikely: return .orange
        }
    }
}
