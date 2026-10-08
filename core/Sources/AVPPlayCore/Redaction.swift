import Foundation

/// Entfernt Zugangsdaten aus Text, bevor er angezeigt oder protokolliert wird.
public enum Redaction {
    private static let patterns: [NSRegularExpression] = [
        // Meta-Tokens (Präfix OCA oder FRL, danach lang und alphanumerisch)
        try! NSRegularExpression(pattern: #"(OCA|FRL)[A-Za-z0-9_|.\-]{16,}"#),
        try! NSRegularExpression(pattern: #"(?i)(access_token=)[^&"\s]+"#),
        try! NSRegularExpression(pattern: #"(?i)(authorization:\s*bearer\s+)\S+"#),
    ]

    public static func redact(_ text: String) -> String {
        var out = text
        for (i, re) in patterns.enumerated() {
            let template = i == 0 ? "<REDACTED>" : "$1<REDACTED>"
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
