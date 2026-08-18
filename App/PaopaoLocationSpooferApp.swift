import SwiftUI

@main
struct PaopaoLocationSpooferApp: App {
    init() {
        RuntimeLogger.info("APP", "Lifecycle", "========== App Launched ==========")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
