import SwiftUI
import ARKit
import RealityKit

struct ScannerView: View {
    @StateObject private var meshManager = MeshManager()
    @State private var showExport = false
    @State private var showModeSelector = false
    @State private var capturedScan: CapturedScan?

    var body: some View {
        ZStack {
            ARViewContainer(meshManager: meshManager)
                .edgesIgnoringSafeArea(.all)

            VStack {
                // Top bar with stats and mode
                HStack {
                    // Stats overlay
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: meshManager.currentMode.icon)
                                .foregroundColor(meshManager.currentMode.color)
                            Text(meshManager.currentMode.rawValue)
                                .font(.caption)
                                .fontWeight(.bold)
                        }
                        Text(meshManager.scanStatus)
                            .font(.caption2)
                        if meshManager.isScanning {
                            Text("Vertices: \(meshManager.vertexCount)")
                                .font(.caption2)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(8)

                    Spacer()

                    // Camera toggle for organic mode
                    if meshManager.currentMode == .organic && meshManager.faceTrackingAvailable {
                        Button(action: { meshManager.toggleCamera() }) {
                            Image(systemName: meshManager.usingFrontCamera ? "camera.rotate" : "camera.rotate.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(22)
                        }
                    }
                }
                .padding()

                Spacer()

                // Controls
                HStack(spacing: 16) {
                    // Mode selector button
                    Button(action: { showModeSelector = true }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(Color.gray.opacity(0.8))
                            .cornerRadius(25)
                    }
                    .disabled(meshManager.isScanning)

                    // Start/Stop button
                    Button(action: toggleScanning) {
                        Text(meshManager.isScanning ? "Stop" : "Start")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 100, height: 50)
                            .background(meshManager.isScanning ? Color.red : Color.green)
                            .cornerRadius(25)
                    }

                    // Export button
                    if capturedScan != nil && !meshManager.isScanning {
                        Button(action: { showExport = true }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.blue)
                                .cornerRadius(25)
                        }
                    } else {
                        // Placeholder to keep layout balanced
                        Color.clear.frame(width: 50, height: 50)
                    }
                }
                .padding(.bottom, 50)
            }
        }
        .navigationTitle("Scanner")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) {
            if let scan = capturedScan {
                ExportView(scan: scan)
            }
        }
        .sheet(isPresented: $showModeSelector) {
            ModeSelectorView(selectedMode: $meshManager.currentMode)
        }
    }

    private func toggleScanning() {
        if meshManager.isScanning {
            capturedScan = meshManager.stopScanning()
        } else {
            capturedScan = nil
            meshManager.startScanning()
        }
    }
}

struct ModeSelectorView: View {
    @Binding var selectedMode: ScanMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ScanMode.allCases) { mode in
                    Button(action: {
                        selectedMode = mode
                        dismiss()
                    }) {
                        HStack(spacing: 16) {
                            Image(systemName: mode.icon)
                                .font(.title2)
                                .foregroundColor(mode.color)
                                .frame(width: 40)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.rawValue)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if mode == selectedMode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Scan Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let meshManager: MeshManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Configure AR session with mesh reconstruction
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]

        arView.session.run(config)

        Task { @MainActor in
            meshManager.setup(arView: arView)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
