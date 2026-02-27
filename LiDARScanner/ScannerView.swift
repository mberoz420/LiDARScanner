import SwiftUI
import ARKit
import RealityKit

struct ScannerView: View {
    @StateObject private var meshManager = MeshManager()
    @State private var showExport = false
    @State private var capturedScan: CapturedScan?

    var body: some View {
        ZStack {
            ARViewContainer(meshManager: meshManager)
                .edgesIgnoringSafeArea(.all)

            VStack {
                // Stats overlay
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meshManager.scanStatus)
                            .font(.caption)
                            .fontWeight(.medium)
                        if meshManager.isScanning {
                            Text("Vertices: \(meshManager.vertexCount)")
                                .font(.caption2)
                            Text("Updates: \(meshManager.meshUpdateCount)")
                                .font(.caption2)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(8)

                    Spacer()
                }
                .padding()

                Spacer()

                // Controls
                HStack(spacing: 20) {
                    Button(action: toggleScanning) {
                        Text(meshManager.isScanning ? "Stop Scan" : "Start Scan")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 140, height: 50)
                            .background(meshManager.isScanning ? Color.red : Color.green)
                            .cornerRadius(25)
                    }

                    if capturedScan != nil && !meshManager.isScanning {
                        Button(action: { showExport = true }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.blue)
                                .cornerRadius(25)
                        }
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

        // Run session
        arView.session.run(config)

        // Connect mesh manager
        Task { @MainActor in
            meshManager.setup(arView: arView)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
