import Foundation

/// Die offenen Verlaufsdateien laufender Aufträge: je Auftrag eine, die offen bleibt, solange Zeilen kommen.
/// Angehängt wird ans Ende einer schon vorhandenen Datei (ein fortgesetzter Auftrag schreibt weiter). Geschlossen
/// wird jede genau einmal – `close` und `closeAll` dürfen beliebig oft gerufen werden, auch für Aufträge ohne
/// offene Datei. Nicht threadsicher: gedacht für einen einzigen Besitzer (die App ruft nur vom Hauptthread).
public final class JobLogFiles {
    private var handles: [String: FileHandle] = [:]

    public init() {}

    deinit { closeAll() }

    /// Die Aufträge, deren Datei gerade offen ist.
    public var open: Set<String> { Set(handles.keys) }

    /// Hängt eine Zeile an die Datei des Auftrags an; öffnet sie dafür, wenn sie noch nicht offen ist.
    public func write(_ line: String, id: String, to url: URL) {
        if handles[id] == nil {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                handles[id] = handle
            }
        }
        try? handles[id]?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Schließt die Datei eines Auftrags, falls sie offen ist.
    public func close(_ id: String) {
        try? handles.removeValue(forKey: id)?.close()
    }

    /// Schließt alle offenen Dateien, etwa beim Beenden des Programms.
    public func closeAll() {
        for id in Array(handles.keys) { close(id) }
    }
}
