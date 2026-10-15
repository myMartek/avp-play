import Foundation

/// Neuere Fassungen geprüfter Spiele aus dem Meta-Store.
///
/// Ein Rezept ist an genau einen Build gebunden – den, der auf einer Vision Pro geprüft wurde. Der Store liefert
/// inzwischen oft einen neueren. Der wird angeboten, aber nicht untergeschoben: Der Nutzer wählt je Spiel, ob er
/// die geprüfte Fassung will oder die neueste, und die neueste ist als ungeprüft gekennzeichnet. Ihr Rezept
/// entsteht aus dem geprüften: derselbe Eintrag in der Toolchain, dieselben Ordner, dieselbe Freischaltung der
/// Zusatzinhalte – nur die Dateien sind die des neuen Builds, wie Metas Werkzeug sie nennt, ohne Größen und
/// Prüfsummen.
public enum StoreUpdate {
    /// Gibt es im Store einen neueren Build als den des Rezepts, und darf er angeboten werden?
    public static func isOffered(_ build: CatalogBuild?, for recipe: Recipe) -> Bool {
        guard let build, recipe.store.appId != nil, recipe.store.pinned != true else { return false }
        return build.versionCode > recipe.versionCode
    }

    /// Die Datei, in der das Rezept der neuesten Fassung eines Spiels liegt (im Ordner der Entwürfe).
    public static func url(drafts: URL, recipeId: String) -> URL {
        drafts.appendingPathComponent("latest-\(recipeId).json")
    }

    /// Die Datei, in der das Rezept einer bestimmten, vom Nutzer gewählten Store-Fassung liegt.
    public static func url(drafts: URL, recipeId: String, versionCode: Int) -> URL {
        drafts.appendingPathComponent("version-\(recipeId)-\(versionCode).json")
    }

    /// Das Rezept der neuesten Fassung, angeordnet wie das geprüfte.
    ///
    /// Jede Datei des neuen Builds nimmt den Platz ihres Gegenstücks ein: bei gleichem Namen dessen Rolle und
    /// Ziel, sonst die der geprüften Dateien gleicher Endung, sonst den Ordner, in dem eine Quest weitere Dateien
    /// ablegt. Was das geprüfte Rezept aus anderen Quellen als dem Store bezieht, bleibt, wie es ist.
    ///
    /// Zusatzinhalte, die der Store nur an Käufer ausliefert (Beat Sabers Songs), sind keine Dateien des Spiels:
    /// Der neue Build führt jeden davon unter einer neuen Kennung, und Meta gibt nur heraus, was gekauft ist. Sie
    /// bleiben deshalb Zusatzinhalte – jeder bekannte unter der Kennung des neuen Builds –, und was der neue Build
    /// darüber hinaus nennt (Songs, die es beim geprüften noch nicht gab), bleibt weg: Zu welchem Kauf eine solche
    /// Datei gehört, steht nur in den Spieldaten, und als Pflichtdatei hielte sie jeden Auftrag an der ersten
    /// nicht gekauften an.
    public static func make(tested: Recipe, build: CatalogBuild, files: [ListedFile]) throws -> Recipe {
        guard let apk = files.first(where: { $0.kind == "APK" }) else { throw ListingError.nothingListed }
        let fromStore = tested.files.filter { $0.source == nil }
        let delivered = tested.addons?.kind == .deliveredAssets
        let addonNames = delivered ? Set((tested.addons?.items ?? []).map(\.name)) : []
        // Hat das geprüfte Spiel neben APK und OBB eigene Dateien aus dem Store, kann eine unbekannte auch eine
        // davon sein; sonst ist sie ein Zusatzinhalt, den das geprüfte Rezept noch nicht kennt.
        let hasLooseContent = fromStore.contains { $0.role != "apk" && $0.role != "main-obb" }
        func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
        func like(_ old: RecipeFile, name: String, id: String) -> RecipeFile {
            var file = old
            file.name = name
            file.id = id
            file.size = nil
            file.sha256 = nil
            return file
        }

        var list: [RecipeFile] = []
        if let old = fromStore.first(where: { $0.role == "apk" }) {
            list.append(like(old, name: apk.name, id: apk.id))
        } else {
            list.append(RecipeFile(name: apk.name, role: "apk", id: apk.id, size: nil, sha256: nil, required: true, dest: "",
                                   localName: "\(tested.toolchain.target).apk", locale: nil, source: nil))
        }
        var seen: Set<String> = [apk.name]
        let oldMain = fromStore.first { $0.role == "main-obb" }
        let fallback = tested.package.isEmpty ? DraftRecipe.packageFolderPlaceholder : DraftRecipe.packageFolder(package: tested.package)
        for file in files where file.kind != "APK" {
            if delivered, file.kind == "ASSET", addonNames.contains(file.name) || !hasLooseContent { continue }
            guard seen.insert(file.name).inserted else { continue }
            if file.kind == "OBB", let oldMain {
                list.append(like(oldMain, name: file.name, id: file.id))
                continue
            }
            if let same = fromStore.first(where: { $0.name == file.name && $0.role != "apk" }) {
                list.append(like(same, name: file.name, id: file.id))
                continue
            }
            // Das häufigste Gegenstück gleicher Endung: bei 124 Kursdateien und einer Liste ist die Liste die Ausnahme.
            let peers = fromStore.filter { $0.role != "apk" && $0.role != "main-obb" && ext($0.name) == ext(file.name) }
            var counts: [String: (count: Int, sample: RecipeFile)] = [:]
            for peer in peers {
                let key = "\(peer.role)|\(peer.dest ?? "-")|\(peer.required)|\(peer.locale ?? "-")"
                counts[key] = ((counts[key]?.count ?? 0) + 1, counts[key]?.sample ?? peer)
            }
            if let common = counts.values.max(by: { $0.count < $1.count })?.sample, common.locale == nil {
                var entry = like(common, name: file.name, id: file.id)
                entry.localName = nil
                list.append(entry)
            } else {
                list.append(RecipeFile(name: file.name, role: file.kind == "OBB" ? "main-obb" : "content-bundle", id: file.id,
                                       size: nil, sha256: nil, required: true,
                                       dest: file.kind == "OBB" ? DraftRecipe.obbPlaceholder : fallback,
                                       localName: nil, locale: nil, source: nil))
            }
        }
        list += tested.files.filter { $0.source != nil && seen.insert($0.name).inserted }

        var recipe = tested
        recipe.versionName = build.version
        recipe.versionCode = build.versionCode
        recipe.files = list
        // The asset-file list names IDs and exact sizes of the tested build; the new build's are not known.
        recipe.assetFiles = nil
        if delivered {
            var ids: [String: String] = [:]
            for file in files where file.kind == "ASSET" && ids[file.name] == nil { ids[file.name] = file.id }
            recipe.addons?.items = (tested.addons?.items ?? []).compactMap { item in
                guard let id = ids[item.name] else { return nil }
                var moved = item
                moved.id = id
                moved.size = nil
                moved.sha256 = nil
                return moved
            }
        }
        // Die gewählte Fassung muss nicht die neuere sein: Wer eine ältere wählt, bekommt denselben Hinweis ohne das Wort.
        let (enAge, deAge) = build.versionCode > tested.versionCode ? ("this newer one", "diese neuere") : ("this one", "diese")
        recipe.status = .init(playability: "untested", download: "listed", notes: [
            LocalizedText(en: "Version \(build.version) from the Meta Store. The project tested \(tested.versionName); \(enAge) has not been tested with AVP Play. It may not start, and add-on content may stay locked. You can go back to the tested version at any time.",
                          de: "Fassung \(build.version) aus dem Meta-Store. Geprüft hat das Projekt \(tested.versionName); \(deAge) ist mit AVP Play nicht getestet. Sie startet vielleicht nicht, und Zusatzinhalte bleiben vielleicht gesperrt. Zur geprüften Fassung kommst du jederzeit zurück.")
        ])
        try recipe.validate()
        return recipe
    }

    // MARK: Die Wahl des Nutzers

    /// Für welche Spiele die neueste Fassung statt der geprüften gewählt ist. Eine kleine Datei bei den Daten des
    /// Programms, damit App, Kommandozeile und der Dienst, der Signaturen erneuert, dasselbe Rezept nehmen.
    public struct Choices: Codable, Sendable, Equatable {
        /// Spiele, für die „die neueste aus dem Store“ gewählt ist (die Wahl aus der Zeit vor der Liste der Fassungen).
        public var latest: Set<String>
        /// Spiele, für die eine bestimmte Fassung gewählt ist: Kennung des Rezepts → Versionscode. Geht `latest` vor.
        public var versions: [String: Int]
        /// Spiele, für die eine andere Kaufquelle gewählt ist als die des mitgelieferten Rezepts: Kennung → Quelle.
        /// Ohne Eintrag gilt die des Rezepts (Meta). Die Wahl der Fassung oben gilt nur für diese.
        public var sources: [String: Recipe.Source]
        public init(latest: Set<String> = [], versions: [String: Int] = [:], sources: [String: Recipe.Source] = [:]) {
            self.latest = latest
            self.versions = versions
            self.sources = sources
        }

        // Eine Datei aus der Zeit vor `versions` nennt nur `latest`; sie gilt weiter.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            latest = try c.decodeIfPresent(Set<String>.self, forKey: .latest) ?? []
            versions = try c.decodeIfPresent([String: Int].self, forKey: .versions) ?? [:]
            sources = try c.decodeIfPresent([String: Recipe.Source].self, forKey: .sources) ?? [:]
        }

        /// Wählt für ein Spiel die Kaufquelle; die des mitgelieferten Rezepts braucht keinen Eintrag.
        public mutating func choose(source: Recipe.Source, for recipeId: String, shipped: Recipe.Source = .meta) {
            sources[recipeId] = source == shipped ? nil : source
        }

        /// Wählt für ein Spiel eine Fassung; `nil` heißt: die, die ohne Wahl gilt.
        public mutating func choose(_ versionCode: Int?, for recipeId: String) {
            latest.remove(recipeId)
            versions[recipeId] = versionCode
        }

        public static var url: URL { DataLocation.base.appendingPathComponent("store-updates.json") }

        public static func load(from url: URL = Choices.url) -> Choices {
            guard let data = try? Data(contentsOf: url), let choices = try? JSONDecoder().decode(Choices.self, from: data) else {
                return Choices()
            }
            return choices
        }

        public func save(to url: URL = Choices.url) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    /// Die Rezepte, mit denen gearbeitet wird: je Spiel das, das ohne Wahl gilt, oder – wo gewählt und vorhanden –
    /// das der gewählten Fassung.
    ///
    /// Gewählt werden kann eine weitere geprüfte Fassung (`variants`, eigene Rezepte des Projekts) oder eine
    /// Fassung aus dem Store, zu der ein Rezept nachgeschlagen wurde (`version-<Kennung>-<Code>.json` bei den
    /// Entwürfen, oder aus der Zeit davor `latest-<Kennung>.json` für „die neueste“). Ein nachgeschlagenes Rezept
    /// gilt nur, wenn es zum selben Spiel und zum selben Eintrag der Toolchain gehört; ein Spiel, das bei seiner
    /// Fassung bleiben soll, bleibt dabei. Was sich nicht auflösen lässt, fällt auf das Rezept ohne Wahl zurück.
    ///
    /// Ist für ein Spiel eine andere Kaufquelle gewählt (`sources`, Rezepte aus `recipes/sources`), gilt deren
    /// Rezept – eine Fassung lässt sich dort nicht wählen: Steam nennt keine früheren.
    public static func resolve(_ shipped: [Recipe], variants: [Recipe] = [], sources: [Recipe] = [], drafts: URL,
                               choices: Choices = .load()) -> [Recipe] {
        shipped.map { tested in
            if let wanted = choices.sources[tested.id], wanted != tested.source,
               let other = sources.first(where: { $0.id == tested.id && $0.source == wanted
                                                  && $0.toolchain.target == tested.toolchain.target }) {
                return other
            }
            guard tested.store.pinned != true else { return tested }
            func same(_ other: Recipe) -> Bool {
                other.id == tested.id && other.store.appId == tested.store.appId && other.toolchain.target == tested.toolchain.target
            }
            if let code = choices.versions[tested.id] {
                if code == tested.versionCode { return tested }
                if let verified = variants.first(where: { $0.id == tested.id && $0.versionCode == code }) { return verified }
                for file in [url(drafts: drafts, recipeId: tested.id, versionCode: code), url(drafts: drafts, recipeId: tested.id)] {
                    if let looked = try? RecipeStore(directory: drafts).load(url: file), same(looked), looked.versionCode == code {
                        return looked
                    }
                }
                return tested
            }
            guard choices.latest.contains(tested.id),
                  let newest = try? RecipeStore(directory: drafts).load(url: url(drafts: drafts, recipeId: tested.id)),
                  same(newest), newest.versionCode > tested.versionCode else { return tested }
            return newest
        }
    }
}
