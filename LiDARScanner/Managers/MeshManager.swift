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
    @Published var faceTrackingAvailable = false
    @Published var currentMode: ScanMode = .largeObjects
    @Published var usingFrontCamera = false

    // MARK: - Properties
    private weak var arView: ARView?
    private var meshAnchors: [UUID: AnchorEntity] = [:]
    private var faceAnchors: [UUID: AnchorEntity] = [:]
    private var capturedScan: CapturedScan?
    private var lastMeshUpdateTime: Date = .distantPast

    // MARK: - Setup
    func setup(arView: ARView) {
        self.arView = arView
        arView.session.delegate = self

        // Check LiDAR availability
        lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

        // Check face tracking availability (TrueDepth camera)
        faceTrackingAvailable = ARFaceTrackingConfiguration.isSupported

        if lidarAvailable {
            scanStatus = "LiDAR ready"
        } else {
            scanStatus = "LiDAR not available"
        }
    }

    // MARK: - Mode Management
    func setMode(_ mode: ScanMode) {
        currentMode = mode
        scanStatus = mode.guidanceText
    }

    private func meshMaterial(for mode: ScanMode) -> SimpleMaterial {
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(mode.color).withAlphaComponent(0.4))
        material.metallic = 0.0
        material.roughness = 0.9
        return material
    }

    // MARK: - Scanning Control
    func startScanning() {
        guard let arView = arView else { return }

        // Clear previous scan
        clearMeshVisualization()
        capturedScan = CapturedScan(startTime: Date())
        meshUpdateCount = 0
        vertexCount = 0

        // Configure based on mode
        if currentMode == .organic && faceTrackingAvailable && usingFrontCamera {
            startFaceTracking(arView: arView)
        } else {
            startLiDARTracking(arView: arView)
        }

        isScanning = true
        scanStatus = currentMode.guidanceText
    }

    private func startLiDARTracking(arView: ARView) {
        let config = ARWorldTrackingConfiguration()

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        config.planeDetection = [.horizontal, .vertical]

        // Higher frame rate for small objects
        if currentMode == .smallObjects {
            config.videoFormat = ARWorldTrackingConfiguration.supportedVideoFormats
                .filter { $0.framesPerSecond >= 60 }
                .first ?? config.videoFormat
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        usingFrontCamera = false
    }

    private func startFaceTracking(arView: ARView) {
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        usingFrontCamera = true
        scanStatus = "Face detected - hold still"
    }

    func toggleCamera() {
        guard let arView = arView, currentMode == .organic else { return }

        if usingFrontCamera {
            startLiDARTracking(arView: arView)
        } else if faceTrackingAvailable {
            startFaceTracking(arView: arView)
        }
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

        for (_, anchor) in faceAnchors {
            anchor.removeFromParent()
        }
        faceAnchors.removeAll()
    }

    // MARK: - Mesh Processing
    private func processMeshAnchor(_ anchor: ARMeshAnchor) {
        guard isScanning else { return }

        // Throttle updates based on mode
        let now = Date()
        guard now.timeIntervalSince(lastMeshUpdateTime) > currentMode.updateInterval else { return }
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

    private func processFaceAnchor(_ anchor: ARFaceAnchor) {
        guard isScanning else { return }

        let now = Date()
        guard now.timeIntervalSince(lastMeshUpdateTime) > currentMode.updateInterval else { return }
        lastMeshUpdateTime = now

        // Extract face geometry
        let meshData = extractFaceData(from: anchor)

        // Update visualization
        updateFaceVisualization(for: anchor)

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

        var vertices: [SIMD3<Float>] = []
        for i in 0..<geometry.vertices.count {
            vertices.append(geometry.vertex(at: i))
        }

        var normals: [SIMD3<Float>] = []
        for i in 0..<geometry.normals.count {
            normals.append(geometry.normal(at: i))
        }

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

    private func extractFaceData(from anchor: ARFaceAnchor) -> CapturedMeshData {
        let geometry = anchor.geometry

        // Extract vertices
        var vertices: [SIMD3<Float>] = []
        for i in 0..<geometry.vertices.count {
            vertices.append(geometry.vertices[i])
        }

        // Face geometry doesn't have normals in the same way, compute from faces
        var normals: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0, 0, 1), count: vertices.count)

        // Extract faces (triangles)
        var faces: [[UInt32]] = []
        let indexCount = geometry.triangleCount * 3
        for i in stride(from: 0, to: indexCount, by: 3) {
            let i0 = UInt32(geometry.triangleIndices[i])
            let i1 = UInt32(geometry.triangleIndices[i + 1])
            let i2 = UInt32(geometry.triangleIndices[i + 2])
            faces.append([i0, i1, i2])

            // Compute face normal
            if Int(i0) < vertices.count && Int(i1) < vertices.count && Int(i2) < vertices.count {
                let v0 = vertices[Int(i0)]
                let v1 = vertices[Int(i1)]
                let v2 = vertices[Int(i2)]
                let normal = normalize(cross(v1 - v0, v2 - v0))
                normals[Int(i0)] = normal
                normals[Int(i1)] = normal
                normals[Int(i2)] = normal
            }
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

        guard let meshResource = try? MeshResource.generate(from: anchor.geometry) else { return }

        let material = meshMaterial(for: currentMode)

        if let existingAnchor = meshAnchors[anchor.identifier] {
            if let modelEntity = existingAnchor.children.first as? ModelEntity {
                modelEntity.model?.mesh = meshResource
                modelEntity.model?.materials = [material]
            }
        } else {
            let modelEntity = ModelEntity(mesh: meshResource, materials: [material])
            let anchorEntity = AnchorEntity(world: anchor.transform)
            anchorEntity.addChild(modelEntity)
            arView.scene.addAnchor(anchorEntity)
            meshAnchors[anchor.identifier] = anchorEntity
        }
    }

    private func updateFaceVisualization(for anchor: ARFaceAnchor) {
        guard let arView = arView else { return }

        guard let meshResource = try? MeshResource.generate(from: anchor.geometry) else { return }

        let material = meshMaterial(for: currentMode)

        if let existingAnchor = faceAnchors[anchor.identifier] {
            if let modelEntity = existingAnchor.children.first as? ModelEntity {
                modelEntity.model?.mesh = meshResource
            }
            existingAnchor.transform = Transform(matrix: anchor.transform)
        } else {
            let modelEntity = ModelEntity(mesh: meshResource, materials: [material])
            let anchorEntity = AnchorEntity(world: anchor.transform)
            anchorEntity.addChild(modelEntity)
            arView.scene.addAnchor(anchorEntity)
            faceAnchors[anchor.identifier] = anchorEntity
        }
    }

    private func removeMeshVisualization(for anchorID: UUID) {
        if let anchor = meshAnchors.removeValue(forKey: anchorID) {
            anchor.removeFromParent()
        }
        if let anchor = faceAnchors.removeValue(forKey: anchorID) {
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
                } else if let faceAnchor = anchor as? ARFaceAnchor {
                    processFaceAnchor(faceAnchor)
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    processMeshAnchor(meshAnchor)
                } else if let faceAnchor = anchor as? ARFaceAnchor {
                    processFaceAnchor(faceAnchor)
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                removeMeshVisualization(for: anchor.identifier)
                capturedScan?.meshes.removeAll { $0.identifier == anchor.identifier }
            }
        }
    }
}
