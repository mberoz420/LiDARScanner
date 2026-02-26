import SwiftUI
import ARKit
import RealityKit

struct ScannerView: View {
    @State private var isScanning = false
    @State private var scanStatus = "Point camera at an object"

    var body: some View {
        ZStack {
            ARViewContainer(isScanning: $isScanning, scanStatus: $scanStatus)
                .edgesIgnoringSafeArea(.all)

            VStack {
                Spacer()

                Text(scanStatus)
                    .font(.headline)
                    .padding()
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)

                Button(action: {
                    isScanning.toggle()
                    scanStatus = isScanning ? "Scanning..." : "Scan paused"
                }) {
                    Text(isScanning ? "Stop Scan" : "Start Scan")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 150, height: 50)
                        .background(isScanning ? Color.red : Color.green)
                        .cornerRadius(25)
                }
                .padding(.bottom, 50)
            }
        }
        .navigationTitle("Scanner")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ARViewContainer: UIViewRepresentable {
    @Binding var isScanning: Bool
    @Binding var scanStatus: String

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            scanStatus = "LiDAR ready"
        } else {
            scanStatus = "LiDAR not available"
        }
        config.planeDetection = [.horizontal, .vertical]

        arView.session.run(config)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
