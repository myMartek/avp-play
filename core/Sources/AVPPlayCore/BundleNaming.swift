import Foundation

/// Die Kennungen, unter denen die Spiele auf dem Gerät installiert werden: ein Präfix und der Name des Targets.
extension Toolchain {
    /// Das Präfix ohne eigene Vorgabe: der Benutzername am Mac und die feste Endung der Toolchain.
    /// `defaultBundleId(target:)` ist dieses Präfix mit angehängtem Target.
    public static func defaultBundlePrefix(user: String = NSUserName()) -> String {
        let scope = user.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(scope.isEmpty ? "user" : scope).dev.klepton.target"
    }

    /// Die Kennung eines Targets unter einem Präfix; ohne Präfix die übliche.
    public static func bundleId(target: String, prefix: String?) -> String {
        guard let prefix, !prefix.isEmpty else { return defaultBundleId(target: target) }
        return "\(prefix).\(target)"
    }

    /// Was die Toolchain zusätzlich erfahren muss, wenn ein Spiel als Versuch gebaut wird: Name und Titel. Alles
    /// andere liest sie am entpackten APK ab. Für ein Target ihrer Tabelle ist das leer.
    public static func genericEnvironment(recipe: Recipe) -> [String: String] {
        guard DraftRecipe.isGeneric(recipe.toolchain.target) else { return [:] }
        return ["KLEPTON_GENERIC_TARGET": recipe.toolchain.target, "KLEPTON_GENERIC_DISPLAY": String(recipe.title.prefix(60))]
    }

    /// Wo das Spiel seine Haupt-Datendatei sucht, relativ zum Datenordner der App – gefragt bei der Toolchain,
    /// die es am entpackten APK erkennt (Versuch) oder aus ihrer Tabelle weiß. `nil`, wenn sie das Target nicht kennt.
    public func obbDestination(recipe: Recipe) -> String? {
        guard let obb = rowValue(recipe: recipe, key: "obb"), Recipe.isSafeRelativePath(obb) else { return nil }
        return "android-files/\(obb)"
    }

    /// Der Android-Paketname des Spiels: der des Rezepts, und wo der fehlt (ein Entwurf zu einem Spiel, dessen
    /// Paketnamen der Katalog nicht kennt), der aus dem entpackten APK. `nil`, solange es nicht entpackt ist.
    public func packageName(recipe: Recipe) -> String? {
        if !recipe.package.isEmpty { return recipe.package }
        let target = recipe.toolchain.target
        guard Recipe.isSafeName(target) else { return nil }
        let manifest = root.appendingPathComponent(target).appendingPathComponent("AndroidManifest.xml")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8),
              let tag = text.range(of: "<manifest"), let end = text.range(of: ">", range: tag.upperBound..<text.endIndex),
              let key = text.range(of: " package=\"", range: tag.upperBound..<end.lowerBound),
              let close = text.range(of: "\"", range: key.upperBound..<end.lowerBound) else { return nil }
        let name = String(text[key.upperBound..<close.lowerBound])
        // Nur was als Ordnername taugt: Buchstaben, Ziffern, Punkt, Unterstrich.
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }),
              !name.contains("..") else { return nil }
        return name
    }

    /// Der Name der Bibliothek, bei der die Toolchain die App startet (`libmain`, `libUE4`, …) – auch für ein
    /// Spiel, das als Versuch gebaut wird: dann liest sie ihn am entpackten APK ab.
    public func entryLibrary(recipe: Recipe) -> String? {
        guard let entry = rowValue(recipe: recipe, key: "entry"), Recipe.isSafeName(entry) else { return nil }
        return entry
    }

    /// Bei einem Versuch: der Name der Einstiegsbibliothek, wenn das entpackte APK sie nicht enthält. Dann ist die
    /// App kein Programm einer Spiel-Engine und keine NativeActivity, sondern für Androids Java-Laufzeit
    /// geschrieben – die gibt es auf der Vision Pro nicht, und die Toolchain kann nichts starten. `nil`, wenn
    /// alles da ist, das Spiel einen eigenen Eintrag hat oder sich die Frage nicht beantworten lässt.
    public func missingEntryLibrary(recipe: Recipe) -> String? {
        let target = recipe.toolchain.target
        guard DraftRecipe.isGeneric(target), Recipe.isSafeName(target), let entry = entryLibrary(recipe: recipe) else { return nil }
        let libs = root.appendingPathComponent(target).appendingPathComponent("lib/arm64-v8a", isDirectory: true)
        guard FileManager.default.fileExists(atPath: libs.deletingLastPathComponent().deletingLastPathComponent().path) else { return nil }
        return FileManager.default.fileExists(atPath: libs.appendingPathComponent("\(entry).so").path) ? nil : entry
    }

    /// Ein Wert aus der Zeile der Toolchain für das Target des Rezepts, gefragt bei ihr selbst.
    private func rowValue(recipe: Recipe, key: String) -> String? {
        guard DeveloperTools.present else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [root.appendingPathComponent("visionos/targets.py").path, recipe.toolchain.target, key]
        p.currentDirectoryURL = root.appendingPathComponent("visionos")
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "USER": NSUserName()]
        env.merge(Toolchain.genericEnvironment(recipe: recipe)) { _, new in new }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !value.isEmpty else { return nil }
        return value
    }

    /// Was die Toolchain über ein Target weiß: seine Art (`unity`, `ue4`, …), oder `nil`, wenn sie es nicht kennt.
    /// Gefragt wird die Tabelle der Toolchain selbst; sie braucht dafür die Spieldateien nicht.
    public func targetKind(_ target: String) -> String? { targetValue(target, key: "kind") }

    /// Ein Eintrag aus der Zeile, die die Toolchain für ein Target führt (nur einfache Texte); `nil`, wenn sie das
    /// Target nicht kennt oder der Eintrag leer ist.
    public func targetValue(_ target: String, key: String) -> String? {
        guard !target.isEmpty, key.allSatisfy({ $0.isASCII && $0.isLetter }), target.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        // Python kommt mit Xcode; ohne es ist `/usr/bin/python3` nur der Platzhalter, der zum Installieren auffordert.
        guard DeveloperTools.present else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", """
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], 'id', '') == 'TARGETS':
        for key, value in zip(node.value.keys, node.value.values):
            if getattr(key, 'value', None) == sys.argv[2]:
                for k, v in zip(value.keys, value.values):
                    if getattr(k, 'value', None) == sys.argv[3] and isinstance(v, ast.Constant) and isinstance(v.value, str):
                        print(v.value)
""", root.appendingPathComponent("visionos/targets.py").path, target, key]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let kind = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return kind.isEmpty ? nil : kind
    }

    /// Taugt der Text als Präfix einer Bundle-ID? Mindestens zwei Abschnitte aus Buchstaben, Ziffern und
    /// Bindestrichen (ASCII), durch Punkte getrennt, kein Abschnitt leer, höchstens 100 Zeichen.
    public static func isValidBundlePrefix(_ text: String) -> Bool {
        guard text.count <= 100 else { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { s in
                s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "-")
            }
        }
    }
}
