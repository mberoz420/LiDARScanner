import SwiftUI
import SceneKit
import ARKit
import RealityKit

/// Side-by-side comparison of scanned mesh and CAD model
struct ComparisonView: View {
    let scannedObject: ScannedObject
    let cadFile: CADFile

    @State private var viewMode: ViewMode = .sideBySide
    @State private var showDimensions = true
    @State private var showAROverlay = false

    enum ViewMode: String, CaseIterable {
        case sideBySide = "Side by Side"
        case overlay = "Overlay"
        case ar = "AR Preview"
    }

    var body: some View {
        VStack(spacing: 0) {
            // View mode picker
            Picker("View Mode", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            // Content based on mode
            switch viewMode {
            case .sideBySide:
                SideBySideView(
                    scannedObject: scannedObject,
                    cadFile: cadFile,
                    showDimensions: showDimensions
                )

            case .overlay:
                OverlayView(
                    scannedObject: scannedObject,
                    cadFile: cadFile
                )

            case .ar:
                ARPreviewView(
                    scannedObject: scannedObject,
                    cadFile: cadFile
                )
            }
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showDimensions) {
                    Image(systemName: "ruler")
                }
            }
        }
    }
}

// MARK: - Side by Side View

struct SideBySideView: View {
    let scannedObject: ScannedObject
    let cadFile: CADFile
    let showDimensions: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Scanned mesh
                VStack {
                    Text("Scanned")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let meshData = scannedObject.meshData {
                        MeshPreviewView(meshData: meshData)
                    } else {
                        ContentUnavailableView(
                            "No Mesh Data",
                            systemImage: "viewfinder.trianglebadge.exclamationmark"
                        )
                    }

                    if showDimensions {
                        DimensionLabel(metrics: scannedObject.metrics)
                    }
                }
                .frame(width: geometry.size.width / 2)

                Divider()

                // CAD model
                VStack {
                    Text("CAD Model")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let url = cadFile.localFileURL {
                        SceneKitView(url: url, isLoading: .constant(false))
                    } else {
                        ContentUnavailableView(
                            "Download Required",
                            systemImage: "arrow.down.circle"
                        )
                    }

                    if showDimensions, let dims = cadFile.dimensions {
                        Text(String(format: "%.1f × %.1f × %.1f mm",
                                   dims.x * 1000, dims.y * 1000, dims.z * 1000))
                            .font(.caption)
                            .padding(4)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .frame(width: geometry.size.width / 2)
            }
        }
    }
}

// MARK: - Overlay View

struct OverlayView: View {
    let scannedObject: ScannedObject
    let cadFile: CADFile
    @State private var opacity: Double = 0.5

    var body: some View {
        ZStack {
            // Background - scanned mesh
            if let meshData = scannedObject.meshData {
                MeshPreviewView(meshData: meshData)
            }

            // Overlay - CAD model
            if let url = cadFile.localFileURL {
                SceneKitView(url: url, isLoading: .constant(false))
                    .opacity(opacity)
            }

            // Opacity slider
            VStack {
                Spacer()

                HStack {
                    Text("Scan")
                        .font(.caption)
                    Slider(value: $opacity, in: 0...1)
                    Text("CAD")
                        .font(.caption)
                }
                .padding()
                .background(Color.black.opacity(0.6))
            }
        }
    }
}

// MARK: - AR Preview View

struct ARPreviewView: View {
    let scannedObject: ScannedObject
    let cadFile: CADFile

    var body: some View {
        ZStack {
            if LiDARCapture.isLiDARAvailable {
                ARViewContainerForPreview(cadFile: cadFile)
                    .ignoresSafeArea()

                VStack {
                    Spacer()

                    Text("Point camera at the scanned object to overlay CAD model")
                        .font(.caption)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    "AR Not Available",
                    systemImage: "arkit",
                    description: Text("LiDAR is required for AR preview")
                )
            }
        }
    }
}

struct ARViewContainerForPreview: UIViewRepresentable {
    let cadFile: CADFile

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        arView.session.run(config)

        // Load CAD model if available
        if let url = cadFile.localFileURL {
            loadModel(url: url, into: arView)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    private func loadModel(url: URL, into arView: ARView) {
        // For USDZ files, use RealityKit's native loading
        if url.pathExtension.lowercased() == "usdz" {
            Task {
                do {
                    let entity = try await Entity(contentsOf: url)

                    // Create anchor 0.5m in front of camera
                    let anchor = AnchorEntity(world: [0, 0, -0.5])
                    anchor.addChild(entity)

                    await MainActor.run {
                        arView.scene.addAnchor(anchor)
                    }
                } catch {
                    print("Failed to load model: \(error)")
                }
            }
        }
    }
}

// MARK: - Mesh Preview View

struct MeshPreviewView: UIViewRepresentable {
    let meshData: MeshData

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor.systemBackground
        scnView.autoenablesDefaultLighting = true
        scnView.allowsCameraControl = true

        let scene = SCNScene()

        // Create geometry from mesh data
        let geometry = createGeometry(from: meshData)
        let node = SCNNode(geometry: geometry)

        // Center the mesh
        let (min, max) = node.boundingBox
        let center = SCNVector3(
            (min.x + max.x) / 2,
            (min.y + max.y) / 2,
            (min.z + max.z) / 2
        )
        node.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)

        // Scale to fit
        let size = Swift.max(max.x - min.x, Swift.max(max.y - min.y, max.z - min.z))
        if size > 0 {
            let scale = 1.0 / size
            node.scale = SCNVector3(scale, scale, scale)
        }

        scene.rootNode.addChildNode(node)

        // Add camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 2)
        scene.rootNode.addChildNode(cameraNode)

        scnView.scene = scene

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func createGeometry(from meshData: MeshData) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        for i in stride(from: 0, to: meshData.vertices.count, by: 3) {
            vertices.append(SCNVector3(
                meshData.vertices[i],
                meshData.vertices[i + 1],
                meshData.vertices[i + 2]
            ))
        }

        var normals: [SCNVector3] = []
        for i in stride(from: 0, to: meshData.normals.count, by: 3) {
            normals.append(SCNVector3(
                meshData.normals[i],
                meshData.normals[i + 1],
                meshData.normals[i + 2]
            ))
        }

        let indices = meshData.indices.map { Int32($0) }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)

        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.8)
        material.isDoubleSided = true
        geometry.materials = [material]

        return geometry
    }
}

// MARK: - Dimension Label

struct DimensionLabel: View {
    let metrics: ObjectMetrics
    @AppStorage("measurementUnit") private var unit = "mm"

    var body: some View {
        Text(metrics.dimensionString(unit: unit))
            .font(.caption)
            .padding(4)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(4)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ComparisonView(
            scannedObject: ScannedObject(metrics: ObjectMetrics()),
            cadFile: CADFile(
                name: "Test",
                format: .stl,
                source: .local,
                sourceURL: URL(string: "https://example.com")!
            )
        )
    }
}
