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

    /// Was die Toolchain über ein Target weiß: seine Art (`unity`, `ue4`, …), oder `nil`, wenn sie es nicht kennt.
    /// Gefragt wird die Tabelle der Toolchain selbst; sie braucht dafür die Spieldateien nicht.
    public func targetKind(_ target: String) -> String? {
        guard !target.isEmpty, target.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
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
                    if getattr(k, 'value', None) == 'kind' and isinstance(v, ast.Constant):
                        print(v.value)
""", root.appendingPathComponent("visionos/targets.py").path, target]
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
