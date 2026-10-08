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
