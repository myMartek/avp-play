import Combine
import SwiftUI
import XCTest

/// Das Gemerkte im Modell der App (`AppModel.derived`) wird verworfen, wenn `objectWillChange` meldet – auch bei
/// Einstellungen, die als `@AppStorage` im Modell stehen. Das prüft dieser Test: ändert sich, wie SwiftUI das hält,
/// müssten die Einstellungen das Gemerkte selbst verwerfen.
@MainActor
private final class StorageModel: ObservableObject {
    static let key = "avpplay-test-appstorage-\(UUID().uuidString)"
    @AppStorage(StorageModel.key) var flag = false
}

final class AppStorageObservationTests: XCTestCase {
    @MainActor
    func testAppStorageInsideObservableObjectAnnouncesChanges() {
        let model = StorageModel()
        defer { UserDefaults.standard.removeObject(forKey: StorageModel.key) }
        var announced = 0
        let watch = model.objectWillChange.sink { _ in announced += 1 }
        defer { watch.cancel() }

        model.flag.toggle()
        XCTAssertGreaterThan(announced, 0, "Setzen über die Eigenschaft")

        // Direkt in UserDefaults gesetzt, wie es Teile der App (und `defaults write`) tun.
        announced = 0
        UserDefaults.standard.set(!model.flag, forKey: StorageModel.key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(announced, 0, "Setzen über UserDefaults")
    }
}
