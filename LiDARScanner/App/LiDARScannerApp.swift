import SwiftUI

@main
struct LiDARScannerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}

/// Global application state
class AppState: ObservableObject {
    @Published var currentScan: ScannedObject?
    @Published var identificationResults: [IdentificationResult] = []
    @Published var downloadedCADFiles: [CADFile] = []
    @Published var isScanning = false
    @Published var isProcessing = false
}
