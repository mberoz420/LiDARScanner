import SwiftUI

struct ContentView: View {
    @StateObject private var versionTracker = VersionTracker()

    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()

                // App icon
                Image(systemName: "cube.transparent")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)

                VStack(spacing: 8) {
                    Text("LiDAR Scanner")
                        .font(.largeTitle)
                        .bold()

                    Text("3D scanning with texture capture")
                        .foregroundColor(.gray)

                    Text("v\(versionTracker.fullVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                NavigationLink(destination: ScannerView()) {
                    HStack {
                        Image(systemName: "viewfinder")
                        Text("Start Scanning")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 40)

                Spacer()
                    .frame(height: 60)
            }
        }
        .sheet(isPresented: $versionTracker.shouldShowWhatsNew, onDismiss: {
            versionTracker.markAsSeen()
        }) {
            WhatsNewView(version: versionTracker.fullVersion)
        }
    }
}

#Preview {
    ContentView()
}
