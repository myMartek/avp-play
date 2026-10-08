import Foundation

/// Was der Nutzer über die Pflichtdateien hinaus haben möchte bzw. besitzt.
public struct FetchSelection: Sendable, Equatable {
    /// Gewählte Sprachvarianten (z. B. "de-DE"); gilt für Dateien mit `locale`.
    public var locales: Set<String> = []
    /// Einzeln gewählte wählbare Dateien.
    public var optionalNames: Set<String> = []
    /// Vom Store bestätigte Käufe. Nur für diese werden Zusatzdateien eingeplant.
    public var ownedSKUs: Set<String> = []
    /// Beschränkt den Plan auf diese Dateinamen (für gezielte Abrufe und Tests).
    public var only: Set<String>? = nil

    public init(locales: Set<String> = [], optionalNames: Set<String> = [], ownedSKUs: Set<String> = [],
                only: Set<String>? = nil) {
        self.locales = locales
        self.optionalNames = optionalNames
        self.ownedSKUs = ownedSKUs
        self.only = only
    }
}

public struct PlannedFetch: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case download
        case resume(from: Int64)
        /// Liegt bereits vollständig vor.
        case keep
        /// Muss der Nutzer selbst bereitstellen; wird nie geladen.
        case needsUser
    }
    public let file: RecipeFile
    public let action: Action
}

public enum FetchPlan {
    /// Die Dateien, die für diese Auswahl gebraucht werden. Zusatzdateien eines Spiels, dessen Store nur
    /// Gekauftes ausliefert, kommen ausschließlich über bestätigte SKUs hinein – es wird nie eine Datei
    /// eingeplant, nur um zu sehen, ob Meta sie herausgibt.
    public static func wantedFiles(recipe: Recipe, selection: FetchSelection) -> [RecipeFile] {
        var wanted = recipe.files.filter { file in
            if file.required { return true }
            if selection.optionalNames.contains(file.name) { return true }
            if let locale = file.locale, selection.locales.contains(locale) { return true }
            return false
        }
        if let addons = recipe.addons, addons.kind == .deliveredAssets {
            wanted += (addons.items ?? [])
                .filter { selection.ownedSKUs.contains($0.sku) }
                .map { $0.asFile(dest: addons.dest) }
        }
        if let only = selection.only { wanted = wanted.filter { only.contains($0.name) } }
        return wanted
    }

    public static func plan(recipe: Recipe, selection: FetchSelection,
                            state: (RecipeFile) -> ContentStore.FileState) -> [PlannedFetch] {
        wantedFiles(recipe: recipe, selection: selection).map { file in
            switch state(file) {
            case .missing where file.source?.kind == .user, .partial where file.source?.kind == .user:
                return PlannedFetch(file: file, action: .needsUser)
            case .missing:
                return PlannedFetch(file: file, action: .download)
            case .present(let size):
                // Stimmt eine bekannte Größe nicht, ist die Datei unbrauchbar und wird neu geladen.
                if let expected = file.size, expected != size { return PlannedFetch(file: file, action: .download) }
                return PlannedFetch(file: file, action: .keep)
            case .partial(let size):
                if let expected = file.size, size >= expected { return PlannedFetch(file: file, action: .download) }
                return PlannedFetch(file: file, action: .resume(from: size))
            }
        }
    }
}
