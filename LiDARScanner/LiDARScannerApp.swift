import SwiftUI

@main
struct LiDARScannerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Sync Eva's brain on app launch
                    await EvaBrainManager.shared.sync()
                }
        }
    }
}
