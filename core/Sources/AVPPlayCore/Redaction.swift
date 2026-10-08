import Foundation

/// Entfernt Zugangsdaten aus Text, bevor er angezeigt oder protokolliert wird.
public enum Redaction {
    private static let patterns: [NSRegularExpression] = [
        // Meta-Tokens (Präfix OCA oder FRL, danach lang und alphanumerisch)
        try! NSRegularExpression(pattern: #"(OCA|FRL)[A-Za-z0-9_|.\-]{16,}"#),
        try! NSRegularExpression(pattern: #"(?i)(access_token=)[^&"\s]+"#),
        try! NSRegularExpression(pattern: #"(?i)(authorization:\s*bearer\s+)\S+"#),
    ]

    /// Nimmt heraus, was auf eine Person oder ihr Gerät zeigt, bevor ein Text weitergegeben wird (etwa in
    /// einer Fehlermeldung an das Projekt): den Benutzerordner, den Benutzernamen, Gerätekennungen und die
    /// genannten weiteren Angaben wie die Team-ID. Zugangsdaten entfernt zusätzlich `redact`.
    public static func anonymize(_ text: String, user: String = NSUserName(),
                                 home: String = NSHomeDirectory(), alsoHide: [String] = []) -> String {
        var out = redact(text)
        if !home.isEmpty, home != "/" { out = out.replacingOccurrences(of: home, with: "~") }
        out = out.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "~", options: .regularExpression)
        // Gerätekennungen (UDID) und die Kennungen, die devicectl vergibt
        out = out.replacingOccurrences(of: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"#, with: "<device>", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
                                       with: "<id>", options: .regularExpression)
        for secret in alsoHide where secret.count >= 4 { out = out.replacingOccurrences(of: secret, with: "<hidden>") }
        if user.count >= 3 {
            out = out.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: user) + "\\b", with: "<user>",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    public static func redact(_ text: String) -> String {
        var out = text
        for (i, re) in patterns.enumerated() {
            let template = i == 0 ? "<REDACTED>" : "$1<REDACTED>"
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
