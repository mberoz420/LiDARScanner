import Foundation
import ARKit
import RealityKit
import Combine

@MainActor
class MeshManager: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isScanning = false
    @Published var scanStatus = "Ready to scan"
    @Published var vertexCount = 0
    @Published var meshUpdateCount = 0
    @Published var lidarAvailable = false

    // MARK: - Properties
    private weak var arView: ARView?
    private var meshAnchors: [UUID: AnchorEntity] = [:]
    private var capturedScan: CapturedScan?
    private var lastMeshUpdateTime: Date = .distantPast
    private let meshUpdateInterval: TimeInterval = 0.3

    // Semi-transparent material for mesh overlay
    private lazy var meshMaterial: SimpleMaterial = {
        var material = SimpleMaterial()
        material.color = .init(tint: .systemBlue.withAlphaComponent(0.5))
        material.metallic = 0.0
        material.roughness = 0.8
        return material
    }()

    // MARK: - Setup
    func setup(arView: ARView) {
        self.arView = arView
        arView.session.delegate = self

        // Check LiDAR availability
        lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        if lidarAvailable {
            scanStatus = "LiDAR ready"
        } else {
            scanStatus = "LiDAR not available"
        }
    }

    // MARK: - Scanning Control
    func startScanning() {
        guard lidarAvailable else {
            scanStatus = "LiDAR not available on this device"
            return
        }

        // Clear previous scan
        clearMeshVisualization()
        capturedScan = CapturedScan(startTime: Date())
        meshUpdateCount = 0
        vertexCount = 0

        isScanning = true
        scanStatus = "Scanning... Move device slowly"
    }

    func stopScanning() -> CapturedScan? {
        isScanning = false
        capturedScan?.endTime = Date()
        scanStatus = "Scan complete - \(vertexCount) vertices"
        return capturedScan
    }

    func clearMeshVisualization() {
        for (_, anchor) in meshAnchors {
            anchor.removeFromParent()
        }
        meshAnchors.removeAll()
    }

    // MARK: - Mesh Processing
    private func processMeshAnchor(_ anchor: ARMeshAnchor) {
        guard isScanning else { return }

        // Throttle updates for performance
        let now = Date()
        guard now.timeIntervalSince(lastMeshUpdateTime) > meshUpdateInterval else { return }
        lastMeshUpdateTime = now

        // Extract geometry data
        let meshData = extractMeshData(from: anchor)

        // Update visualization
        updateMeshVisualization(for: anchor)

        // Store for export
        if let index = capturedScan?.meshes.firstIndex(where: { $0.identifier == anchor.identifier }) {
            capturedScan?.meshes[index] = meshData
        } else {
            capturedScan?.meshes.append(meshData)
        }

        vertexCount = capturedScan?.vertexCount ?? 0
        meshUpdateCount += 1
    }

    private func extractMeshData(from anchor: ARMeshAnchor) -> CapturedMeshData {
        let geometry = anchor.geometry

        // Extract vertices
        var vertices: [SIMD3<Float>] = []
        for i in 0..<geometry.vertices.count {
            vertices.append(geometry.vertex(at: i))
        }

        // Extract normals
        var normals: [SIMD3<Float>] = []
        for i in 0..<geometry.normals.count {
            normals.append(geometry.normal(at: i))
        }

        // Extract faces (triangles)
        var faces: [[UInt32]] = []
        for i in 0..<geometry.faces.count {
            let face = geometry.faceIndices(at: i)
            faces.append(face)
        }

        return CapturedMeshData(
            vertices: vertices,
            normals: normals,
            faces: faces,
            transform: anchor.transform,
            identifier: anchor.identifier
        )
    }

    private func updateMeshVisualization(for anchor: ARMeshAnchor) {
        guard let arView = arView else { return }

        // Generate MeshResource from ARMeshGeometry
        guard let meshResource = try? MeshResource.generate(from: anchor.geometry) else { return }

        if let existingAnchor = meshAnchors[anchor.identifier] {
            // Update existing mesh
            if let modelEntity = existingAnchor.children.first as? ModelEntity {
                modelEntity.model?.mesh = meshResource
            }
        } else {
            // Create new mesh entity
            let modelEntity = ModelEntity(mesh: meshResource, materials: [meshMaterial])

            let anchorEntity = AnchorEntity(world: anchor.transform)
            anchorEntity.addChild(modelEntity)
            arView.scene.addAnchor(anchorEntity)

            meshAnchors[anchor.identifier] = anchorEntity
        }
    }

    private func removeMeshVisualization(for anchorID: UUID) {
        if let anchor = meshAnchors.removeValue(forKey: anchorID) {
            anchor.removeFromParent()
        }
    }
}

// MARK: - ARSessionDelegate
extension MeshManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    processMeshAnchor(meshAnchor)
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    processMeshAnchor(meshAnchor)
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    removeMeshVisualization(for: meshAnchor.identifier)
                    capturedScan?.meshes.removeAll { $0.identifier == meshAnchor.identifier }
                }
            }
        }
    }
}
