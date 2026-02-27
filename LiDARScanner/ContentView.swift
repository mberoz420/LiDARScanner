import SwiftUI

struct ContentView: View {
    @StateObject private var versionTracker = VersionTracker()
    @StateObject private var updateChecker = UpdateChecker()
    @State private var showSettings = false
    @State private var showMultiRoom = false
    @State private var showTextureOverlay = false

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

                    HStack(spacing: 8) {
                        Text("v\(versionTracker.fullVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Update status indicator
                        if let update = updateChecker.updateAvailable {
                            Button(action: { updateChecker.showUpdateAlert = true }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("v\(update.newVersion) Available")
                                }
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green)
                                .cornerRadius(12)
                            }
                        } else if updateChecker.isChecking {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Checking...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if let result = updateChecker.lastCheckResult {
                            switch result {
                            case .upToDate:
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Up to date")
                                        .foregroundColor(.secondary)
                                }
                                .font(.caption)
                            case .notConfigured:
                                Text("Set update URL in Settings")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            case .error(let msg):
                                Text(msg)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                            case .updateAvailable:
                                EmptyView()  // Handled above
                            }
                        }
                    }
                }

                Spacer()

                // Single room scan
                NavigationLink(destination: ScannerView()) {
                    HStack {
                        Image(systemName: "viewfinder")
                        Text("Scan Single Room")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 40)

                // Multi-room scan
                Button(action: { showMultiRoom = true }) {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                        Text("Multi-Room Scan")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.green)
                    .cornerRadius(12)
                }
                .padding(.horizontal, 40)

                // Add texture to existing scan
                Button(action: { showTextureOverlay = true }) {
                    HStack {
                        Image(systemName: "paintbrush")
                        Text("Add Texture to Scan")
                    }
                    .font(.subheadline)
                    .foregroundColor(.orange)
                }
                .padding(.top, 5)

                // Settings and Update buttons
                HStack(spacing: 20) {
                    Button(action: { showSettings = true }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Settings")
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }

                    // Check for updates button
                    Button(action: {
                        Task {
                            await updateChecker.forceCheckForUpdates()
                        }
                    }) {
                        HStack {
                            if updateChecker.isChecking {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Check Update")
                        }
                        .font(.subheadline)
                        .foregroundColor(updateChecker.updateAvailable != nil ? .green : .blue)
                    }
                    .disabled(updateChecker.isChecking)
                }
                .padding(.top, 10)

                Spacer()
                    .frame(height: 40)
            }
        }
        .sheet(isPresented: $versionTracker.shouldShowWhatsNew, onDismiss: {
            versionTracker.markAsSeen()
        }) {
            WhatsNewView(version: versionTracker.fullVersion)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showMultiRoom) {
            MultiRoomView()
        }
        .sheet(isPresented: $showTextureOverlay) {
            TextureOverlayView()
        }
        .checkForUpdates(using: updateChecker)
        .task {
            await updateChecker.checkForUpdates()
        }
    }
}

#Preview {
    ContentView()
}
