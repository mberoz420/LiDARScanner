import Foundation
import ARKit
import RealityKit
import simd

/// Manages adding texture/color to an existing scan
@MainActor
class TextureOverlayManager: NSObject, ObservableObject {

    // MARK: - Published State
    @Published var isLoaded = false
    @Published var isCapturing = false
    @Published var captureProgress: Float = 0  // 0-1
    @Published var verticesColored: Int = 0
    @Published var totalVertices: Int = 0
    @Published var status: String = "Ready"

    // MARK: - Properties
    private weak var arView: ARView?
    private var loadedScan: CapturedScan?
    private var vertexColors: [[VertexColor]] = []  // Colors per mesh
    private var vertexColorCounts: [[Int]] = []     // How many samples per vertex
    private var currentFrame: ARFrame?

    // Visualization
    private var meshEntities: [UUID: ModelEntity] = [:]

    // MARK: - Load Existing Scan

    /// Load a scan file to add texture to
    func loadScan(_ scan: CapturedScan) {
        loadedScan = scan
        totalVertices = scan.vertexCount

        // Initialize color arrays
        vertexColors = scan.meshes.map { mesh in
            Array(repeating: VertexColor(r: 0.5, g: 0.5, b: 0.5), count: mesh.vertices.count)
        }
        vertexColorCounts = scan.meshes.map { mesh in
            Array(repeating: 0, count: mesh.vertices.count)
        }

        verticesColored = 0
        isLoaded = true
        status = "Scan loaded. Start texture capture."
    }

    /// Load scan from file URL
    func loadScanFromFile(_ url: URL) async -> Bool {
        let importer = MeshImporter()

        status = "Loading file..."

        do {
            let scan = try await importer.importMesh(from: url)
            loadScan(scan)
            return true
        } catch {
            status = "Error: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Setup AR

    func setup(arView: ARView) {
        self.arView = arView
        arView.session.delegate = self

        // Start AR session
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        arView.session.run(config)
    }

    // MARK: - Texture Capture

    func startCapture() {
        guard isLoaded else {
            status = "No scan loaded"
            return
        }

        isCapturing = true
        status = "Move around to capture texture..."

        // Show loaded mesh as wireframe guide
        showMeshGuide()
    }

    func stopCapture() {
        isCapturing = false
        hideMeshGuide()

        // Calculate final colors (average of samples)
        finalizeColors()

        status = "Capture complete. \(verticesColored) vertices colored."
    }

    /// Process current camera frame to sample colors
    private func processFrame(_ frame: ARFrame) {
        guard isCapturing, let scan = loadedScan else { return }

        var newlyColored = 0

        for (meshIndex, mesh) in scan.meshes.enumerated() {
            for (vertexIndex, vertex) in mesh.vertices.enumerated() {
                // Transform vertex to world space
                let worldVertex = transformPoint(vertex, by: mesh.transform)

                // Check if vertex is visible in current frame
                guard isVertexVisible(worldVertex, in: frame) else { continue }

                // Sample color from camera
                if let color = sampleColor(for: worldVertex, frame: frame) {
                    // Accumulate color
                    let existing = vertexColors[meshIndex][vertexIndex]
                    let count = vertexColorCounts[meshIndex][vertexIndex]

                    if count == 0 {
                        vertexColors[meshIndex][vertexIndex] = color
                        newlyColored += 1
                    } else {
                        // Running average
                        let newR = (existing.r * Float(count) + color.r) / Float(count + 1)
                        let newG = (existing.g * Float(count) + color.g) / Float(count + 1)
                        let newB = (existing.b * Float(count) + color.b) / Float(count + 1)
                        vertexColors[meshIndex][vertexIndex] = VertexColor(r: newR, g: newG, b: newB)
                    }

                    vertexColorCounts[meshIndex][vertexIndex] += 1
                }
            }
        }

        verticesColored += newlyColored
        captureProgress = Float(verticesColored) / Float(max(1, totalVertices))
    }

    /// Check if a world-space vertex is visible in the current frame
    private func isVertexVisible(_ worldVertex: SIMD3<Float>, in frame: ARFrame) -> Bool {
        let camera = frame.camera

        // Transform to camera space
        let cameraTransform = camera.transform
        let cameraPos = SIMD3<Float>(cameraTransform.columns.3.x,
                                      cameraTransform.columns.3.y,
                                      cameraTransform.columns.3.z)

        // Check distance (not too far, not too close)
        let distance = simd_distance(worldVertex, cameraPos)
        guard distance > 0.3 && distance < 5.0 else { return false }

        // Project to screen
        let projectedPoint = camera.projectPoint(worldVertex,
                                                  orientation: .portrait,
                                                  viewportSize: CGSize(width: 1920, height: 1080))

        // Check if in frame
        let inFrame = projectedPoint.x >= 0 && projectedPoint.x <= 1920 &&
                      projectedPoint.y >= 0 && projectedPoint.y <= 1080

        return inFrame
    }

    /// Sample color from camera image at vertex position
    private func sampleColor(for worldVertex: SIMD3<Float>, frame: ARFrame) -> VertexColor? {
        let camera = frame.camera

        // Project to image coordinates
        let imageSize = CGSize(width: CVPixelBufferGetWidth(frame.capturedImage),
                               height: CVPixelBufferGetHeight(frame.capturedImage))

        let projectedPoint = camera.projectPoint(worldVertex,
                                                  orientation: .portrait,
                                                  viewportSize: imageSize)

        let x = Int(projectedPoint.x)
        let y = Int(projectedPoint.y)

        guard x >= 0 && x < Int(imageSize.width) &&
              y >= 0 && y < Int(imageSize.height) else {
            return nil
        }

        // Sample from pixel buffer
        return samplePixelBuffer(frame.capturedImage, x: x, y: y)
    }

    /// Sample color from pixel buffer (YCbCr to RGB conversion)
    private func samplePixelBuffer(_ pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> VertexColor? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Get Y plane
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }

        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let yIndex = y * yBytesPerRow + x
        let cbcrIndex = (y / 2) * cbcrBytesPerRow + (x / 2) * 2

        let yPointer = yPlane.assumingMemoryBound(to: UInt8.self)
        let cbcrPointer = cbcrPlane.assumingMemoryBound(to: UInt8.self)

        let yValue = Float(yPointer[yIndex])
        let cbValue = Float(cbcrPointer[cbcrIndex]) - 128
        let crValue = Float(cbcrPointer[cbcrIndex + 1]) - 128

        // YCbCr to RGB
        let r = yValue + 1.402 * crValue
        let g = yValue - 0.344136 * cbValue - 0.714136 * crValue
        let b = yValue + 1.772 * cbValue

        return VertexColor(
            r: max(0, min(1, r / 255)),
            g: max(0, min(1, g / 255)),
            b: max(0, min(1, b / 255))
        )
    }

    // MARK: - Visualization

    private func showMeshGuide() {
        guard let arView = arView, let scan = loadedScan else { return }

        // Show loaded mesh as semi-transparent guide
        for mesh in scan.meshes {
            // Create simple visualization
            // This is a placeholder - would need proper mesh generation
        }
    }

    private func hideMeshGuide() {
        for (_, entity) in meshEntities {
            entity.removeFromParent()
        }
        meshEntities.removeAll()
    }

    // MARK: - Finalize

    private func finalizeColors() {
        // Colors are already averaged, nothing else to do
    }

    /// Get the textured scan
    func getTexturedScan() -> CapturedScan? {
        guard var scan = loadedScan else { return nil }

        // Update meshes with colors
        var newMeshes: [CapturedMeshData] = []

        for (meshIndex, mesh) in scan.meshes.enumerated() {
            let colors = vertexColors[meshIndex]

            let newMesh = CapturedMeshData(
                vertices: mesh.vertices,
                normals: mesh.normals,
                colors: colors,
                faces: mesh.faces,
                transform: mesh.transform,
                identifier: mesh.identifier,
                surfaceType: mesh.surfaceType,
                faceClassifications: mesh.faceClassifications
            )
            newMeshes.append(newMesh)
        }

        scan.meshes = newMeshes
        return scan
    }

    // MARK: - Helpers

    private func transformPoint(_ point: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let p4 = SIMD4<Float>(point.x, point.y, point.z, 1)
        let transformed = transform * p4
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    // MARK: - Reset

    func reset() {
        loadedScan = nil
        vertexColors = []
        vertexColorCounts = []
        isLoaded = false
        isCapturing = false
        captureProgress = 0
        verticesColored = 0
        totalVertices = 0
        status = "Ready"
        hideMeshGuide()
    }
}

// MARK: - ARSessionDelegate

extension TextureOverlayManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            currentFrame = frame
            if isCapturing {
                processFrame(frame)
            }
        }
    }
}
