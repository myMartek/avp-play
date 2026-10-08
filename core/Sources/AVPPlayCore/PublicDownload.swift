import Foundation

/// Download einer frei verfügbaren Datei (z. B. ein quelloffener Port auf GitHub). Hier wird nie ein Token
/// mitgeschickt; die Prüfsumme aus dem Rezept entscheidet anschließend, ob die Datei angenommen wird.
public enum PublicDownload {
    public static func fetch(_ url: URL, to destination: URL, resumeFrom offset: Int64 = 0) async throws -> MetaClient.DownloadOutcome {
        precondition(url.scheme == "https", L("public downloads only over https", "freie Downloads nur über https"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let delegate = DownloadDelegate(destination: destination, offset: offset, progress: nil, authorizedHost: nil)
        let session = URLSession(configuration: MetaClient.configuration(), delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<MetaClient.DownloadOutcome, Error>) in
                delegate.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}
