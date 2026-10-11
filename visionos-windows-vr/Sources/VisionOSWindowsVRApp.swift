import SwiftUI

@main
struct VisionOSWindowsVRApp: App {
    @State private var launcherModel = LauncherModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: launcherModel)
        }
        .windowStyle(.automatic)

        WindowsVRCompositorScene(model: launcherModel)
    }
}
