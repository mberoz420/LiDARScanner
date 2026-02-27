import Foundation
import ARKit
import RealityKit
import Combine
import UIKit

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
    @Published var surfaceClassificationEnabled = true
    @Published var deviceOrientation: DeviceOrientation = .lookingHorizontal

    // MARK: - Guided Room Scanning
    @Published var currentPhase: RoomScanPhase = .ready
    @Published var phaseProgress: Double = 0
    @Published var useEdgeVisualization = false  // Edge lines instead of mesh overlay

    // Surface classifier for floor/ceiling/wall detection
    let surfaceClassifier = SurfaceClassifier()

    // Edge visualizer for room mode
    let edgeVisualizer = EdgeVisualizer()

    // MARK: - Properties
    private weak var arView: ARView?
    private var meshAnchors: [UUID: AnchorEntity] = [:]
    private var faceAnchors: [UUID: AnchorEntity] = [:]
    private var surfaceTypes: [UUID: SurfaceType] = [:]  // Track surface type per mesh
    private var capturedScan: CapturedScan?
    private var lastMeshUpdateTime: Date = .distantPast
    private var currentFrame: ARFrame?

    // MARK: - Setup
    func setup(arView: ARView) {
        self.arView = arView
        arView.session.delegate = self

        // Check LiDAR availability
        lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

        // Check face tracking availability (TrueDepth camera)
        faceTrackingAvailable = ARFaceTrackingConfiguration.isSupported

        // Setup edge visualizer
        edgeVisualizer.setup(arView: arView)

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

    private func meshMaterial(for surfaceType: SurfaceType) -> SimpleMaterial {
        var material = SimpleMaterial()
        let color = surfaceType.color
        material.color = .init(tint: UIColor(
            red: CGFloat(color.r),
            green: CGFloat(color.g),
            blue: CGFloat(color.b),
            alpha: CGFloat(color.a)
        ))
        material.metallic = 0.0
        material.roughness = 0.9
        return material
    }

    // MARK: - Scanning Control
    func startScanning() {
        guard let arView = arView else { return }

        // Clear previous scan
        clearMeshVisualization()
        edgeVisualizer.clearEdges()
        capturedScan = CapturedScan(startTime: Date())
        meshUpdateCount = 0
        vertexCount = 0
        surfaceTypes.removeAll()

        // Reset surface classifier and sync with app settings
        surfaceClassifier.reset()
        surfaceClassificationEnabled = AppSettings.shared.surfaceClassificationEnabled

        // Setup guided scanning for room mode
        if currentMode == .walls {
            currentPhase = .floor
            phaseProgress = 0
            useEdgeVisualization = true
            // Always enable classification for guided room mode (needed for edge detection)
            surfaceClassifier.classificationEnabled = true
            scanStatus = currentPhase.instruction
        } else {
            currentPhase = .ready
            useEdgeVisualization = false
            surfaceClassifier.classificationEnabled = surfaceClassificationEnabled
        }

        // Configure based on mode
        if currentMode == .organic && faceTrackingAvailable && usingFrontCamera {
            startFaceTracking(arView: arView)
        } else {
            startLiDARTracking(arView: arView)
        }

        isScanning = true
        if currentMode != .walls {
            scanStatus = currentMode.guidanceText
        }
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
        capturedScan?.statistics = surfaceClassifier.statistics

        // Build summary
        var summary = "\(vertexCount) vertices"
        if !surfaceClassifier.statistics.summary.isEmpty {
            summary += " | \(surfaceClassifier.statistics.summary)"
        }
        scanStatus = "Scan complete - \(summary)"

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

        // Classify the surface
        let classifiedSurface = surfaceClassifier.classifyMeshAnchor(anchor)
        surfaceTypes[anchor.identifier] = classifiedSurface.surfaceType

        // Check if this surface should be filtered (room layout mode)
        let shouldFilter = surfaceClassifier.shouldFilterSurface(classifiedSurface)

        if shouldFilter {
            // Remove visualization if it exists (object was previously visible)
            removeMeshVisualization(for: anchor.identifier)
            // Remove from captured scan
            capturedScan?.meshes.removeAll { $0.identifier == anchor.identifier }
            return
        }

        // Adaptive throttling based on surface type
        let baseInterval = currentMode.updateInterval
        let multiplier = surfaceClassifier.updateIntervalMultiplier(for: classifiedSurface.surfaceType)
        let adjustedInterval = baseInterval * multiplier

        let now = Date()
        guard now.timeIntervalSince(lastMeshUpdateTime) > adjustedInterval else { return }
        lastMeshUpdateTime = now

        // Extract geometry data
        let meshData = extractMeshData(from: anchor)

        // Detect protrusions if ceiling-related
        if classifiedSurface.surfaceType == .ceilingProtrusion {
            surfaceClassifier.detectProtrusion(
                meshID: anchor.identifier,
                vertices: meshData.vertices,
                transform: anchor.transform,
                surfaceType: classifiedSurface.surfaceType
            )
        }

        // Detect doors/windows in wall meshes
        if classifiedSurface.surfaceType == .wall && AppSettings.shared.detectDoorsWindows {
            surfaceClassifier.detectOpenings(
                in: meshData,
                wallNormal: classifiedSurface.averageNormal
            )
        }

        // Update visualization with surface-appropriate color
        updateMeshVisualization(for: anchor, surfaceType: classifiedSurface.surfaceType)

        // Update edge visualization in room mode
        if useEdgeVisualization && currentMode == .walls {
            edgeVisualizer.updateEdges(surfaceClassifier.statistics.detectedEdges)
        }

        // Store for export
        if let index = capturedScan?.meshes.firstIndex(where: { $0.identifier == anchor.identifier }) {
            capturedScan?.meshes[index] = meshData
        } else {
            capturedScan?.meshes.append(meshData)
        }

        vertexCount = capturedScan?.vertexCount ?? 0
        meshUpdateCount += 1

        // Update status with room info
        updateScanStatus()
    }

    private func updateScanStatus() {
        let stats = surfaceClassifier.statistics

        // Handle guided room scanning
        if currentMode == .walls && useEdgeVisualization {
            updateRoomScanPhase()
            return
        }

        if !stats.summary.isEmpty {
            scanStatus = "\(currentMode.guidanceText) | \(stats.summary)"
        } else {
            scanStatus = currentMode.guidanceText
        }
    }

    // MARK: - Guided Room Scanning

    private func updateRoomScanPhase() {
        let stats = surfaceClassifier.statistics

        switch currentPhase {
        case .ready:
            scanStatus = currentPhase.instruction
            phaseProgress = 0

        case .floor:
            phaseProgress = Double(stats.floorConfidence)
            if stats.floorHeight != nil {
                scanStatus = String(format: "Floor detected at %.2fm", stats.floorHeight!)
            } else {
                scanStatus = currentPhase.instruction
            }
            // Auto-advance when floor is detected with high confidence
            if stats.floorConfidence >= Float(currentPhase.completionThreshold) {
                advancePhase()
            }

        case .ceiling:
            phaseProgress = Double(stats.ceilingConfidence)
            if let height = stats.estimatedRoomHeight {
                scanStatus = String(format: "Room height: %.2fm", height)
            } else if stats.ceilingHeight != nil {
                scanStatus = "Ceiling detected - measuring height..."
            } else {
                scanStatus = currentPhase.instruction
            }
            // Auto-advance when ceiling is detected
            if stats.ceilingConfidence >= Float(currentPhase.completionThreshold) {
                advancePhase()
            }

        case .walls:
            phaseProgress = Double(stats.wallCoveragePercent)
            let corners = stats.cornerCount
            scanStatus = "\(corners) corners detected | Turn to scan more"
            // Update edge visualization
            edgeVisualizer.updateEdges(stats.detectedEdges)
            // Check for completion
            if stats.wallCoveragePercent >= Float(currentPhase.completionThreshold) {
                advancePhase()
            }

        case .complete:
            phaseProgress = 1.0
            if let dims = stats.roomDimensions {
                scanStatus = String(format: "Room: %.1fm x %.1fm x %.1fm",
                                    dims.width, dims.depth, dims.height)
            } else {
                scanStatus = "Room captured!"
            }
        }
    }

    /// Advance to the next phase
    func advancePhase() {
        guard let next = currentPhase.nextPhase else { return }
        currentPhase = next
        phaseProgress = 0

        // Play haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        // Update status
        scanStatus = currentPhase.instruction
    }

    /// Skip current phase (manual override)
    func skipPhase() {
        advancePhase()
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

        // Sample colors from camera frame (skip for Walls mode - geometry only)
        var colors: [VertexColor] = []
        if currentMode != .walls, let frame = currentFrame {
            colors = TextureProjector.sampleColors(
                for: vertices,
                meshTransform: anchor.transform,
                frame: frame
            )
        }

        // Get surface classification
        let surfaceType = surfaceTypes[anchor.identifier]

        // Get per-face classifications if enabled (or if using edge visualization)
        var faceClassifications: [SurfaceType]? = nil
        if surfaceClassificationEnabled || useEdgeVisualization {
            faceClassifications = surfaceClassifier.classifyMesh(
                vertices: vertices,
                normals: normals,
                faces: faces,
                transform: anchor.transform
            )
        }

        return CapturedMeshData(
            vertices: vertices,
            normals: normals,
            colors: colors,
            faces: faces,
            transform: anchor.transform,
            identifier: anchor.identifier,
            surfaceType: surfaceType,
            faceClassifications: faceClassifications
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

        // Sample colors from camera frame
        var colors: [VertexColor] = []
        if let frame = currentFrame {
            colors = TextureProjector.sampleColors(
                for: vertices,
                meshTransform: anchor.transform,
                frame: frame
            )
        }

        return CapturedMeshData(
            vertices: vertices,
            normals: normals,
            colors: colors,
            faces: faces,
            transform: anchor.transform,
            identifier: anchor.identifier
        )
    }

    private func updateMeshVisualization(for anchor: ARMeshAnchor, surfaceType: SurfaceType? = nil) {
        guard let arView = arView else { return }

        // Skip mesh overlay when using edge visualization (room mode)
        if useEdgeVisualization {
            // Don't render mesh surfaces - only edges are shown
            return
        }

        guard let meshResource = try? MeshResource.generate(from: anchor.geometry) else { return }

        // Use surface-based color if classification is enabled, otherwise mode color
        let material: SimpleMaterial
        if surfaceClassificationEnabled, let type = surfaceType {
            material = meshMaterial(for: type)
        } else {
            material = meshMaterial(for: currentMode)
        }

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
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            currentFrame = frame

            // Update device orientation from gyroscope/accelerometer
            surfaceClassifier.updateDeviceOrientation(from: frame)
            deviceOrientation = surfaceClassifier.deviceOrientation
        }
    }

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
