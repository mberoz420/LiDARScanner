import ARKit
import RealityKit
import Combine

/// Handles LiDAR scanning and mesh capture
@MainActor
class LiDARCapture: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isScanning = false
    @Published var meshAnchors: [ARMeshAnchor] = []
    @Published var scanProgress: Float = 0
    @Published var error: LiDARError?
    @Published var boundingBox: BoundingBox?

    // MARK: - Properties
    private var arSession: ARSession?
    private var cancellables = Set<AnyCancellable>()

    /// Check if LiDAR is available on this device
    static var isLiDARAvailable: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    // MARK: - Configuration

    /// Create AR configuration for LiDAR scanning
    func createConfiguration() -> ARWorldTrackingConfiguration? {
        guard Self.isLiDARAvailable else {
            error = .lidarNotAvailable
            return nil
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        configuration.environmentTexturing = .automatic
        configuration.planeDetection = [.horizontal, .vertical]

        // Enable frame semantics for better mesh quality
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        return configuration
    }

    // MARK: - Scanning Control

    /// Start LiDAR scanning session
    func startScanning(session: ARSession) {
        guard let configuration = createConfiguration() else { return }

        self.arSession = session
        session.delegate = self

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        meshAnchors = []
        scanProgress = 0
        error = nil
    }

    /// Stop scanning and capture current mesh state
    func stopScanning() -> [ARMeshAnchor] {
        isScanning = false
        arSession?.pause()
        return meshAnchors
    }

    /// Reset scanning session
    func resetScanning() {
        meshAnchors = []
        boundingBox = nil
        scanProgress = 0

        if let session = arSession, let config = createConfiguration() {
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    // MARK: - Bounding Box

    /// Set bounding box for object isolation
    func setBoundingBox(center: SIMD3<Float>, extent: SIMD3<Float>) {
        boundingBox = BoundingBox(center: center, extent: extent)
    }

    /// Filter mesh anchors within bounding box
    func getMeshesInBoundingBox() -> [ARMeshAnchor] {
        guard let box = boundingBox else { return meshAnchors }

        return meshAnchors.filter { anchor in
            let anchorPosition = SIMD3<Float>(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            return box.contains(anchorPosition)
        }
    }

    // MARK: - Mesh Extraction

    /// Extract combined mesh data from all anchors
    func extractMeshData(from anchors: [ARMeshAnchor]? = nil) -> MeshData? {
        let targetAnchors = anchors ?? getMeshesInBoundingBox()
        guard !targetAnchors.isEmpty else { return nil }

        var allVertices: [Float] = []
        var allNormals: [Float] = []
        var allIndices: [UInt32] = []

        var indexOffset: UInt32 = 0

        for anchor in targetAnchors {
            let geometry = anchor.geometry

            // Extract vertices
            let vertexBuffer = geometry.vertices
            let vertexCount = vertexBuffer.count
            let vertexStride = vertexBuffer.stride

            vertexBuffer.buffer.contents().withMemoryRebound(to: UInt8.self, capacity: vertexBuffer.buffer.length) { ptr in
                for i in 0..<vertexCount {
                    let vertexPtr = ptr.advanced(by: i * vertexStride)
                    let vertex = vertexPtr.withMemoryRebound(to: SIMD3<Float>.self, capacity: 1) { $0.pointee }

                    // Transform vertex to world coordinates
                    let worldVertex = anchor.transform * SIMD4<Float>(vertex, 1)
                    allVertices.append(contentsOf: [worldVertex.x, worldVertex.y, worldVertex.z])
                }
            }

            // Extract normals
            let normalBuffer = geometry.normals
            normalBuffer.buffer.contents().withMemoryRebound(to: UInt8.self, capacity: normalBuffer.buffer.length) { ptr in
                for i in 0..<normalBuffer.count {
                    let normalPtr = ptr.advanced(by: i * normalBuffer.stride)
                    let normal = normalPtr.withMemoryRebound(to: SIMD3<Float>.self, capacity: 1) { $0.pointee }

                    // Transform normal (rotation only)
                    let rotation = simd_float3x3(
                        SIMD3<Float>(anchor.transform.columns.0.x, anchor.transform.columns.0.y, anchor.transform.columns.0.z),
                        SIMD3<Float>(anchor.transform.columns.1.x, anchor.transform.columns.1.y, anchor.transform.columns.1.z),
                        SIMD3<Float>(anchor.transform.columns.2.x, anchor.transform.columns.2.y, anchor.transform.columns.2.z)
                    )
                    let worldNormal = rotation * normal
                    allNormals.append(contentsOf: [worldNormal.x, worldNormal.y, worldNormal.z])
                }
            }

            // Extract indices
            let indexBuffer = geometry.faces
            indexBuffer.buffer.contents().withMemoryRebound(to: UInt32.self, capacity: indexBuffer.count * 3) { ptr in
                for i in 0..<(indexBuffer.count * 3) {
                    allIndices.append(ptr[i] + indexOffset)
                }
            }

            indexOffset += UInt32(vertexCount)
        }

        return MeshData(vertices: allVertices, normals: allNormals, indices: allIndices)
    }
}

// MARK: - ARSessionDelegate

extension LiDARCapture: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
            meshAnchors.append(contentsOf: meshes)
            updateScanProgress()
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
                if let index = meshAnchors.firstIndex(where: { $0.identifier == meshAnchor.identifier }) {
                    meshAnchors[index] = meshAnchor
                }
            }
            updateScanProgress()
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            let removedIDs = Set(anchors.map { $0.identifier })
            meshAnchors.removeAll { removedIDs.contains($0.identifier) }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.error = .sessionFailed(error.localizedDescription)
            isScanning = false
        }
    }

    private func updateScanProgress() {
        // Estimate progress based on mesh coverage
        let totalVertices = meshAnchors.reduce(0) { $0 + $1.geometry.vertices.count }
        // Assume ~10000 vertices is a "complete" scan
        scanProgress = min(Float(totalVertices) / 10000.0, 1.0)
    }
}

// MARK: - Supporting Types

struct BoundingBox {
    let center: SIMD3<Float>
    let extent: SIMD3<Float>

    var minPoint: SIMD3<Float> {
        center - extent / 2
    }

    var maxPoint: SIMD3<Float> {
        center + extent / 2
    }

    func contains(_ point: SIMD3<Float>) -> Bool {
        point.x >= minPoint.x && point.x <= maxPoint.x &&
        point.y >= minPoint.y && point.y <= maxPoint.y &&
        point.z >= minPoint.z && point.z <= maxPoint.z
    }
}

enum LiDARError: LocalizedError {
    case lidarNotAvailable
    case sessionFailed(String)
    case meshExtractionFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .lidarNotAvailable:
            return "LiDAR is not available on this device. iPhone 12 Pro or newer is required."
        case .sessionFailed(let message):
            return "AR session failed: \(message)"
        case .meshExtractionFailed:
            return "Failed to extract mesh data from scan."
        case .exportFailed(let message):
            return "Failed to export mesh: \(message)"
        }
    }
}
