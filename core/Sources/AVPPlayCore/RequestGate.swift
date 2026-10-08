import Foundation

/// Bremse für Abfragen an Metas Download-Seite: zwischen zwei Abrufen liegt mindestens `minInterval`.
/// Hintergrund: Ein Lauf mit rund 140 Abfragen in zehn Minuten hat ein Konto auf einem Zugangsweg
/// ausgesperrt (Schritt 0, F61). Die Bremse ersetzt nicht die zweite Regel – nie etwas durchprobieren.
public actor RequestGate {
    public let minInterval: Duration
    private var lastFinished: ContinuousClock.Instant?

    public init(minInterval: Duration = .seconds(5)) { self.minInterval = minInterval }

    /// Wie lange vor der nächsten Abfrage noch zu warten ist.
    public static func delay(lastFinished: ContinuousClock.Instant?, now: ContinuousClock.Instant,
                             minInterval: Duration) -> Duration {
        guard let lastFinished else { return .zero }
        let elapsed = now - lastFinished
        return elapsed >= minInterval ? .zero : minInterval - elapsed
    }

    public func waitForTurn() async throws {
        let wait = RequestGate.delay(lastFinished: lastFinished, now: .now, minInterval: minInterval)
        if wait > .zero { try await Task.sleep(for: wait) }
    }

    public func requestFinished() { lastFinished = .now }
}
