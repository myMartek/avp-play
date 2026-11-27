import Foundation

/// Lädt Metas Werkzeug `ovr-platform-util` direkt von Metas eigenem Server, statt den Nutzer über Metas Seite und
/// den Ordner „Downloads“ zu schicken. Die Adresse ist die, auf die Metas Seite für macOS verweist; Meta nennt die
/// gleiche Form für Linux offen auf der Seite des Werkzeugs. Mitgeschickt wird nichts außer dieser öffentlichen
/// Kennung des Werkzeugs – kein Konto, kein Token. Gestartet wird die Datei erst, wenn `MetaTool.adopt` die
/// Signatur von Meta bestätigt hat; eine andere Datei würde dort abgewiesen.
public enum MetaToolFetch {
    /// Metas Kennung des Werkzeugs für macOS (öffentlich, steht in der Adresse selbst).
    static let appId = "1462426033810370"
    public static var url: URL {
        URL(string: "https://www.oculus.com/download_app/?id=\(appId)&access_token=OC%7C\(appId)%7C")!
    }

    /// Ungefähre Größe (Oktober 2026: 253 MB), solange der Server noch keine nennt.
    public static let expectedBytes: Int64 = 253_000_000

    public struct Progress: Sendable, Equatable {
        public var received: Int64
        public var total: Int64
        public init(received: Int64, total: Int64) {
            self.received = received
            self.total = total
        }
        public var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    public enum FetchError: Error, CustomStringConvertible {
        case http(Int)
        case tooSmall(Int64)
        case transport(String)

        public var description: String {
            switch self {
            case .http(let code):
                return L("Meta's server answered with status \(code). Try again later, or download the tool on Meta's page.",
                         "Metas Server antwortete mit Status \(code). Später noch einmal versuchen oder das Werkzeug auf Metas Seite laden.")
            case .tooSmall(let bytes):
                return L("The download from Meta was incomplete (\(bytes) bytes).", "Der Download von Meta war unvollständig (\(bytes) Bytes).")
            case .transport(let why):
                return L("The download from Meta stopped: \(why)", "Der Download von Meta brach ab: \(why)")
            }
        }
    }

    /// Lädt das Werkzeug in eine temporäre Datei, richtet es mit `MetaTool.adopt` ein (Signaturprüfung, eigene
    /// Kopie, ausführbar) und löscht die temporäre Datei wieder.
    @discardableResult
    public static func fetchAndAdopt(to destination: URL = MetaTool.installedURL,
                                     progress: @escaping @Sendable (Progress) -> Void) async throws -> MetaTool {
        let file = try await download(progress: progress)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        return try MetaTool.adopt(from: file, to: destination)
    }

    /// Nur der Download, in einen eigenen temporären Ordner (Datei `ovr-platform-util`).
    public static func download(progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("avpplay-metatool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("ovr-platform-util")
        let delegate = Delegate(target: target, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("AVPPlay", forHTTPHeaderField: "User-Agent")
        do {
            try await delegate.run(session.downloadTask(with: request))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? NSNumber)?.int64Value ?? 0
        // Das Werkzeug ist ein Programm von einigen hundert MB; ein paar KB wären eine Fehlerseite.
        guard size > 10_000_000 else {
            try? FileManager.default.removeItem(at: folder)
            throw FetchError.tooSmall(size)
        }
        return target
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let target: URL
        let progress: @Sendable (Progress) -> Void
        private var continuation: CheckedContinuation<Void, Error>?
        private var moveError: Error?
        private let lock = NSLock()

        init(target: URL, progress: @escaping @Sendable (Progress) -> Void) {
            self.target = target
            self.progress = progress
        }

        func run(_ task: URLSessionDownloadTask) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    lock.lock(); continuation = c; lock.unlock()
                    task.resume()
                }
            } onCancel: { task.cancel() }
        }

        private func finish(_ result: Result<Void, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(MetaToolFetch.expectedBytes, totalBytesWritten)
            progress(Progress(received: totalBytesWritten, total: total))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                moveError = FetchError.http(http.statusCode)
                return
            }
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
            } catch { moveError = error }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : FetchError.transport(error.localizedDescription)))
            } else if let moveError {
                finish(.failure(moveError))
            } else {
                finish(.success(()))
            }
        }
    }
}
