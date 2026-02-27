import SwiftUI
import ARKit
import RealityKit

struct TextureOverlayView: View {
    @StateObject private var textureManager = TextureOverlayManager()
    @State private var showFilePicker = false
    @State private var showExport = false
    @State private var texturedScan: CapturedScan?
    @State private var sourceFile: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if !textureManager.isLoaded {
                    // Load scan screen
                    VStack(spacing: 30) {
                        Spacer()

                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.orange)

                        Text("Add Texture to Existing Scan")
                            .font(.headline)

                        Text("Load a previously saved scan (without texture) and add color by rescanning the same area.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)

                        VStack(spacing: 12) {
                            Button(action: { showFilePicker = true }) {
                                HStack {
                                    Image(systemName: "folder")
                                    Text("Load from Files")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal, 40)

                            Text("Supported: PLY, OBJ files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                } else if textureManager.isCapturing {
                    // Capture screen
                    ZStack {
                        TextureARViewContainer(textureManager: textureManager)
                            .edgesIgnoringSafeArea(.all)

                        VStack {
                            // Progress overlay
                            VStack(spacing: 8) {
                                Text("Capturing Texture...")
                                    .font(.headline)

                                ProgressView(value: textureManager.captureProgress)
                                    .progressViewStyle(.linear)
                                    .frame(width: 200)

                                Text("\(textureManager.verticesColored) / \(textureManager.totalVertices) vertices")
                                    .font(.caption)

                                Text(textureManager.status)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .padding()

                            Spacer()

                            // Stop button
                            Button(action: stopCapture) {
                                Text("Done Capturing")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(width: 200, height: 50)
                                    .background(Color.green)
                                    .cornerRadius(25)
                            }
                            .padding(.bottom, 50)
                        }
                    }
                } else {
                    // Ready to capture / finished screen
                    VStack(spacing: 20) {
                        Spacer()

                        if let scan = texturedScan {
                            // Finished
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.green)

                            Text("Texture Capture Complete!")
                                .font(.headline)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Vertices colored: \(textureManager.verticesColored)")
                                Text("Total vertices: \(textureManager.totalVertices)")
                                Text("Coverage: \(Int(textureManager.captureProgress * 100))%")
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                            Button(action: { showExport = true }) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export Textured Scan")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal, 40)

                        } else {
                            // Ready to capture
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 60))
                                .foregroundColor(.blue)

                            Text("Ready to Capture Texture")
                                .font(.headline)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Scan loaded: \(textureManager.totalVertices) vertices")
                                Text(textureManager.status)
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                            Text("Point your camera at the same surfaces you scanned before. Move slowly to capture colors.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)

                            Button(action: startCapture) {
                                HStack {
                                    Image(systemName: "paintbrush.fill")
                                    Text("Start Texture Capture")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal, 40)
                        }

                        Spacer()

                        Button(action: reset) {
                            Text("Start Over")
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom)
                    }
                }
            }
            .navigationTitle("Add Texture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.data, .threeDContent],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showExport) {
                if let scan = texturedScan {
                    ExportView(scan: scan)
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                sourceFile = url
                textureManager.status = "Loading \(url.lastPathComponent)..."

                Task {
                    let success = await textureManager.loadScanFromFile(url)
                    if success {
                        textureManager.status = "Loaded \(textureManager.totalVertices) vertices"
                    }
                }
            }
        case .failure(let error):
            textureManager.status = "Error: \(error.localizedDescription)"
        }
    }

    private func startCapture() {
        textureManager.startCapture()
    }

    private func stopCapture() {
        textureManager.stopCapture()
        texturedScan = textureManager.getTexturedScan()
    }

    private func reset() {
        textureManager.reset()
        texturedScan = nil
        sourceFile = nil
    }
}

struct TextureARViewContainer: UIViewRepresentable {
    let textureManager: TextureOverlayManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        Task { @MainActor in
            textureManager.setup(arView: arView)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

#Preview {
    TextureOverlayView()
}
