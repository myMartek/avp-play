import Foundation

/// Das Verzeichnis im Ordner für Downloads: welcher Ordner zu welchem Spiel gehört.
///
/// Die Ordner heißen nach der Kennung des Rezepts und der Nummer des Builds (`store-24882487241367228-526346`) –
/// daran findet das Programm sie wieder, ein Mensch aber kein Spiel. Umbenannt werden sie deshalb nicht; stattdessen
/// liegt daneben eine Textdatei, die es sagt. Sie wird neu geschrieben, wenn sich etwas geändert hat, und von
/// niemandem gelesen außer von Menschen.
public enum StoreIndex {
    public static let fileName = "AVP Play – Index.txt"

    public struct Entry: Sendable, Equatable {
        public var folder: String
        public var title: String
        public var detail: String
        public var bytes: Int64
        public init(folder: String, title: String, detail: String, bytes: Int64) {
            self.folder = folder
            self.title = title
            self.detail = detail
            self.bytes = bytes
        }
    }

    /// Ein Name, der als Datei- oder Ordnername taugt: ohne Schrägstrich, Doppelpunkt und Steuerzeichen, nicht endlos.
    public static func fileSafe(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.map { s -> Character in
            s.value < 0x20 || s == "/" || s == ":" || s == "\\" ? " " : Character(s)
        }).split(separator: " ").joined(separator: " ")
        let trimmed = String(cleaned.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "Game" : trimmed
    }

    static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    public static func text(_ entries: [Entry]) -> String {
        let rows = entries.sorted { a, b in
            let order = a.title.localizedCaseInsensitiveCompare(b.title)
            return order == .orderedSame ? a.folder < b.folder : order == .orderedAscending
        }
        let head = (L("Game", "Spiel"), L("Folder", "Ordner"), L("What it is", "Was es ist"), L("Size", "Größe"))
        let w1 = max(head.0.count, rows.map(\.title.count).max() ?? 0), w2 = max(head.1.count, rows.map(\.folder.count).max() ?? 0)
        let w3 = max(head.2.count, rows.map(\.detail.count).max() ?? 0)
        var lines = [L("AVP Play – which folder belongs to which game", "AVP Play – welcher Ordner zu welchem Spiel gehört"),
                     L("AVP Play writes this file itself and rewrites it when something changes. Editing it changes nothing.",
                       "AVP Play schreibt diese Datei selbst und erneuert sie, wenn sich etwas ändert. Sie zu bearbeiten ändert nichts."),
                     "",
                     pad(head.0, to: w1) + "  " + pad(head.1, to: w2) + "  " + pad(head.2, to: w3) + "  " + head.3]
        lines.append(String(repeating: "-", count: w1 + w2 + w3 + 6 + 10))
        for row in rows {
            lines.append(pad(row.title, to: w1) + "  " + pad(row.folder, to: w2) + "  " + pad(row.detail, to: w3) + "  " + Installer.gigabytes(row.bytes))
        }
        if rows.isEmpty { lines.append(L("Nothing has been downloaded yet.", "Noch ist nichts heruntergeladen.")) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Schreibt das Verzeichnis, wenn es anders aussähe als das vorhandene. Sagt, ob geschrieben wurde.
    @discardableResult
    public static func write(root: URL, entries: [Entry]) -> Bool {
        guard StoreLocation.isAvailable(root), FileManager.default.fileExists(atPath: root.path) else { return false }
        let url = root.appendingPathComponent(fileName)
        let wanted = text(entries)
        if (try? String(contentsOf: url, encoding: .utf8)) == wanted { return false }
        return (try? Data(wanted.utf8).write(to: url, options: .atomic)) != nil
    }
}

/// Die Liste der eigenen Spiele als Text – zum Weitergeben, etwa an das Projekt, damit es sieht, welche Spiele
/// jemand hat und welche davon noch nicht laufen. Darin steht nichts über das Konto, den Mac oder das Headset;
/// anfangen lässt sich mit der Liste nichts außer sie zu lesen.
public enum GameList {
    public struct Entry: Sendable, Equatable {
        public var title: String
        /// Die Kennung im Meta-Store; leer bei Spielen von anderswo.
        public var storeId: String
        public var version: String
        /// Geprüft, von Nutzern bestätigt, ungetestet, inkompatibel – im Wortlaut der App.
        public var label: String
        public var downloaded: Bool
        /// `nil`: unbekannt, weil das Headset nicht erreichbar war.
        public var installed: Bool?
        public init(title: String, storeId: String, version: String, label: String, downloaded: Bool, installed: Bool?) {
            self.title = title
            self.storeId = storeId
            self.version = version
            self.label = label
            self.downloaded = downloaded
            self.installed = installed
        }
    }

    static func yesNo(_ value: Bool?) -> String {
        switch value {
        case true?: return L("yes", "ja")
        case false?: return L("no", "nein")
        case nil: return L("unknown", "unbekannt")
        }
    }

    static func section(_ title: String, _ entries: [Entry], empty: String) -> [String] {
        var lines = ["", "## \(title) (\(entries.count))", ""]
        guard !entries.isEmpty else { return lines + [empty] }
        lines.append([L("Game", "Spiel"), L("Store ID", "Store-Kennung"), "Version", L("Label", "Kennzeichen"),
                      L("Downloaded", "Heruntergeladen"), L("On the Vision Pro", "Auf der Vision Pro")].joined(separator: "\t"))
        for e in entries.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) {
            // Ein Tabulator im Namen verschöbe die Spalten.
            let title = e.title.replacingOccurrences(of: "\t", with: " ")
            lines.append([title, e.storeId.isEmpty ? "–" : e.storeId, e.version.isEmpty ? "–" : e.version, e.label,
                          yesNo(e.downloaded), yesNo(e.installed)].joined(separator: "\t"))
        }
        return lines
    }

    /// Eine einzelne Liste – das, was die Übersicht gerade zeigt, etwa nur die Favoriten oder nur das Installierte.
    /// - Parameter title: was die Liste enthält, in Worten („Favourites, installed“).
    public static func text(title: String, entries: [Entry], appVersion: String, toolchain: String, made: String) -> String {
        (head(appVersion: appVersion, toolchain: toolchain, made: made)
            + section(title, entries, empty: L("No game matches.", "Kein Spiel passt."))).joined(separator: "\n") + "\n"
    }

    /// - Parameter made: der Tag, als Text; steht nur in der Kopfzeile.
    public static func text(downloaded: [Entry], owned: [Entry], favourites: [Entry], appVersion: String, toolchain: String, made: String) -> String {
        var lines = head(appVersion: appVersion, toolchain: toolchain, made: made)
        lines += section(L("Downloaded to this Mac", "Auf diesen Mac heruntergeladen"), downloaded,
                         empty: L("Nothing has been downloaded yet.", "Noch ist nichts heruntergeladen."))
        lines += section(L("In my Meta account, as far as the app has asked", "In meinem Meta-Konto, soweit die App gefragt hat"), owned,
                         empty: L("The app has not found any game in the Meta account yet.", "Die App hat im Meta-Konto noch kein Spiel gefunden."))
        lines += section(L("Favourites", "Favoriten"), favourites, empty: L("No favourites.", "Keine Favoriten."))
        return lines.joined(separator: "\n") + "\n"
    }

    static func head(appVersion: String, toolchain: String, made: String) -> [String] {
        return [L("AVP Play – my games", "AVP Play – meine Spiele"),
                     L("Made on \(made) with AVP Play \(appVersion)\(toolchain.isEmpty ? "" : ", toolchain \(toolchain)"). Columns are separated by tabs, so the list can be pasted into a spreadsheet.",
                       "Erstellt am \(made) mit AVP Play \(appVersion)\(toolchain.isEmpty ? "" : ", Toolchain \(toolchain)"). Die Spalten sind durch Tabulatoren getrennt; die Liste lässt sich so in eine Tabelle einfügen."),
                     L("This is only a list. It contains nothing about an account or a device and no game files.",
                       "Das ist nur eine Liste. Sie enthält nichts über ein Konto oder ein Gerät und keine Spieldateien.")]
    }
}
