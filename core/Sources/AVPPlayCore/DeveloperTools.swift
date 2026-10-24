import Foundation

/// Apples Entwicklerwerkzeuge (`xcrun`, `python3`, `git` unter `/usr/bin`) sind auf einem Mac ohne Xcode nur
/// Platzhalter: Wer sie aufruft, bekommt von macOS den Dialog „Entwicklerwerkzeuge installieren?“. Deshalb wird
/// vorher gefragt, ob es sie gibt – mit `xcode-select -p`, das nur Auskunft gibt und nichts anbietet.
public enum DeveloperTools {
    /// Der gewählte Entwicklerordner (Xcode oder die Kommandozeilenwerkzeuge); `nil`, wenn es keinen gibt.
    public static func directory() -> String? {
        guard let out = try? Toolchain.capture(["/usr/bin/xcode-select", "-p"]) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
    }

    public static var present: Bool { directory() != nil }

    /// Die älteste Hauptversion von Xcode, mit der die Toolchain gebaut und geprüft wird. Ältere Compiler geben an
    /// Stellen auf, die Xcode 27 ohne Weiteres prüft (avp-play#81: Xcode 26.5 an einem SwiftUI-Ausdruck).
    public static let minimumXcodeMajor = 27

    /// Die Hauptversion aus der ersten Zeile von `xcodebuild -version` („Xcode 26.5“ → 26).
    public static func xcodeMajor(fromVersionLine line: String) -> Int? {
        let words = line.split(separator: " ")
        guard words.count >= 2, words[0] == "Xcode" else { return nil }
        return majorVersion(String(words[1]))
    }

    static func majorVersion(_ version: String) -> Int? {
        version.split(separator: ".").first.flatMap { Int($0) }
    }

    /// Ein Xcode-Programm, das auf diesem Mac liegt, aber nicht gewählt ist.
    public struct OtherXcode: Equatable, Sendable {
        public var name: String
        public var version: String
        /// Der Entwicklerordner, den `xcode-select -s` erwartet.
        public var developer: String

        /// Der Befehl, der dieses Xcode wählt.
        public var selectCommand: String { "sudo xcode-select -s \"\(developer)\"" }
    }

    /// Die Xcode-Programme in `folder`, die mindestens `minimumXcodeMajor` sind und nicht `chosen` – das neueste
    /// zuerst. So lässt sich sagen, dass ein neues Xcode schon da ist und nur gewählt werden muss.
    public static func newerXcodes(in folder: URL = URL(fileURLWithPath: "/Applications"), chosen: String?) -> [OtherXcode] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let chosenPath = chosen.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        var found: [OtherXcode] = []
        for app in entries where app.pathExtension == "app" && app.lastPathComponent.hasPrefix("Xcode") {
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let version = info["CFBundleShortVersionString"] as? String,
                  let major = majorVersion(version), major >= minimumXcodeMajor else { continue }
            let developer = app.appendingPathComponent("Contents/Developer").path
            if URL(fileURLWithPath: developer).resolvingSymlinksInPath().path == chosenPath { continue }
            found.append(OtherXcode(name: app.deletingPathExtension().lastPathComponent, version: version, developer: developer))
        }
        return found.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
}
