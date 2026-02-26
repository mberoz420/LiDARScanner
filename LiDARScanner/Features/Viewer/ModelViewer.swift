import SwiftUI
import SceneKit
import QuickLook

struct ModelViewer: View {
    let file: CADFile
    @State private var isLoading = true
    @State private var error: Error?
    @State private var showQuickLook = false
    @State private var quickLookURL: URL?

    var body: some View {
        ZStack {
            if let localURL = file.localFileURL {
                SceneKitView(url: localURL, isLoading: $isLoading)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "File Not Downloaded",
                    systemImage: "arrow.down.circle",
                    description: Text("Download the file to view it")
                )
            }

            if isLoading {
                ProgressView("Loading model...")
                    .padding()
                    .background(Color.secondary.opacity(0.5))
                    .cornerRadius(8)
            }

            if let error = error {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Failed to load model")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.secondary.opacity(0.5))
                .cornerRadius(8)
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let url = file.localFileURL {
                        ShareLink(item: url)

                        Button(action: { openInQuickLook(url: url) }) {
                            Label("Quick Look", systemImage: "eye")
                        }
                    }

                    if let sourceURL = file.sourceURL {
                        Link(destination: sourceURL) {
                            Label("View on \(file.source.rawValue)", systemImage: "safari")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .quickLookPreview($quickLookURL)
    }

    private func openInQuickLook(url: URL) {
        // USDZ files can be previewed directly
        if url.pathExtension.lowercased() == "usdz" {
            quickLookURL = url
        } else {
            // For other formats, try to convert or show in SceneKit
            quickLookURL = url
        }
    }
}

// MARK: - SceneKit View

struct SceneKitView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor.systemBackground
        scnView.autoenablesDefaultLighting = true
        scnView.allowsCameraControl = true
        scnView.showsStatistics = false

        // Set up default camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 2)

        let scene = SCNScene()
        scene.rootNode.addChildNode(cameraNode)
        scnView.scene = scene

        // Load model asynchronously
        loadModel(into: scene, view: scnView)

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func loadModel(into scene: SCNScene, view: SCNView) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let modelNode = try self.loadModelNode(from: url)

                // Center and scale the model
                let (min, max) = modelNode.boundingBox
                let center = SCNVector3(
                    (min.x + max.x) / 2,
                    (min.y + max.y) / 2,
                    (min.z + max.z) / 2
                )
                modelNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)

                // Scale to fit in view
                let size = max(max.x - min.x, max(max.y - min.y, max.z - min.z))
                if size > 0 {
                    let scale = 1.0 / size
                    modelNode.scale = SCNVector3(scale, scale, scale)
                }

                DispatchQueue.main.async {
                    scene.rootNode.addChildNode(modelNode)

                    // Add ambient light
                    let ambientLight = SCNNode()
                    ambientLight.light = SCNLight()
                    ambientLight.light?.type = .ambient
                    ambientLight.light?.intensity = 500
                    scene.rootNode.addChildNode(ambientLight)

                    // Add directional light
                    let directionalLight = SCNNode()
                    directionalLight.light = SCNLight()
                    directionalLight.light?.type = .directional
                    directionalLight.light?.intensity = 1000
                    directionalLight.position = SCNVector3(x: 1, y: 1, z: 1)
                    scene.rootNode.addChildNode(directionalLight)

                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    print("Failed to load model: \(error)")
                    self.isLoading = false
                }
            }
        }
    }

    private func loadModelNode(from url: URL) throws -> SCNNode {
        let fileExtension = url.pathExtension.lowercased()

        switch fileExtension {
        case "usdz", "usda", "usdc":
            let scene = try SCNScene(url: url)
            let containerNode = SCNNode()
            for child in scene.rootNode.childNodes {
                containerNode.addChildNode(child)
            }
            return containerNode

        case "obj":
            let scene = try SCNScene(url: url)
            let containerNode = SCNNode()
            for child in scene.rootNode.childNodes {
                containerNode.addChildNode(child)
            }
            return containerNode

        case "stl":
            return try loadSTL(from: url)

        case "dae":
            let scene = try SCNScene(url: url)
            let containerNode = SCNNode()
            for child in scene.rootNode.childNodes {
                containerNode.addChildNode(child)
            }
            return containerNode

        default:
            // Try to load as generic scene
            let scene = try SCNScene(url: url)
            let containerNode = SCNNode()
            for child in scene.rootNode.childNodes {
                containerNode.addChildNode(child)
            }
            return containerNode
        }
    }

    private func loadSTL(from url: URL) throws -> SCNNode {
        let data = try Data(contentsOf: url)

        // Check if binary or ASCII STL
        let isBinary = !data.prefix(5).elementsEqual("solid".utf8)

        if isBinary {
            return try loadBinarySTL(data: data)
        } else {
            return try loadASCIISTL(data: data)
        }
    }

    private func loadBinarySTL(data: Data) throws -> SCNNode {
        guard data.count > 84 else {
            throw ModelLoadError.invalidFormat
        }

        // Skip 80-byte header
        var offset = 80

        // Read triangle count
        let triangleCount = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []

        for i in 0..<Int(triangleCount) {
            // Normal (12 bytes)
            let normal = data.withUnsafeBytes { ptr -> SCNVector3 in
                let nx = ptr.load(fromByteOffset: offset, as: Float.self)
                let ny = ptr.load(fromByteOffset: offset + 4, as: Float.self)
                let nz = ptr.load(fromByteOffset: offset + 8, as: Float.self)
                return SCNVector3(nx, ny, nz)
            }
            offset += 12

            // 3 vertices (36 bytes)
            for j in 0..<3 {
                let vertex = data.withUnsafeBytes { ptr -> SCNVector3 in
                    let vx = ptr.load(fromByteOffset: offset, as: Float.self)
                    let vy = ptr.load(fromByteOffset: offset + 4, as: Float.self)
                    let vz = ptr.load(fromByteOffset: offset + 8, as: Float.self)
                    return SCNVector3(vx, vy, vz)
                }
                offset += 12

                vertices.append(vertex)
                normals.append(normal)
                indices.append(Int32(i * 3 + j))
            }

            // Attribute byte count (2 bytes)
            offset += 2
        }

        return createGeometryNode(vertices: vertices, normals: normals, indices: indices)
    }

    private func loadASCIISTL(data: Data) throws -> SCNNode {
        guard let string = String(data: data, encoding: .utf8) else {
            throw ModelLoadError.invalidFormat
        }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []

        var currentNormal = SCNVector3(0, 0, 1)
        var vertexIndex: Int32 = 0

        let lines = string.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            if parts.first == "facet" && parts.count >= 5 {
                // facet normal nx ny nz
                if let nx = Float(parts[2]),
                   let ny = Float(parts[3]),
                   let nz = Float(parts[4]) {
                    currentNormal = SCNVector3(nx, ny, nz)
                }
            } else if parts.first == "vertex" && parts.count >= 4 {
                // vertex x y z
                if let x = Float(parts[1]),
                   let y = Float(parts[2]),
                   let z = Float(parts[3]) {
                    vertices.append(SCNVector3(x, y, z))
                    normals.append(currentNormal)
                    indices.append(vertexIndex)
                    vertexIndex += 1
                }
            }
        }

        return createGeometryNode(vertices: vertices, normals: normals, indices: indices)
    }

    private func createGeometryNode(
        vertices: [SCNVector3],
        normals: [SCNVector3],
        indices: [Int32]
    ) -> SCNNode {
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

        // Add default material
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemBlue
        material.specular.contents = UIColor.white
        material.shininess = 0.5
        material.isDoubleSided = true
        geometry.materials = [material]

        return SCNNode(geometry: geometry)
    }
}

// MARK: - Model Load Error

enum ModelLoadError: LocalizedError {
    case invalidFormat
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid model file format."
        case .loadFailed:
            return "Failed to load model."
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ModelViewer(file: CADFile(
            name: "Sample Model",
            format: .stl,
            source: .local,
            sourceURL: URL(string: "https://example.com")!
        ))
    }
}
