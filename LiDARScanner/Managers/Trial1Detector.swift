import Foundation
import simd
import ARKit

/// Trial 1: Scan ceiling-wall intersection to create room boundary, then extrude walls
@MainActor
class Trial1Detector: ObservableObject {

    // MARK: - Scan Phases
    enum ScanPhase: String {
        case ready = "Ready"
        case scanningCeilingBoundary = "Trace Ceiling Edge"
        case measuringFloor = "Measure Floor"
        case complete = "Complete"

        var instruction: String {
            switch self {
            case .ready:
                return "Tap Start to trace ceiling boundary"
            case .scanningCeilingBoundary:
                return "Point at ceiling-wall intersection, move along walls"
            case .measuringFloor:
                return "Point DOWN at floor to measure height"
            case .complete:
                return "Room boundary captured!"
            }
        }

        var icon: String {
            switch self {
            case .ready: return "hand.tap"
            case .scanningCeilingBoundary: return "arrow.up.right"
            case .measuringFloor: return "arrow.down.circle"
            case .complete: return "checkmark.circle.fill"
            }
        }
    }

    // MARK: - Published State
    @Published var phase: ScanPhase = .ready
    @Published var isScanning = false

    // Ceiling boundary points (2D XZ positions at ceiling height)
    @Published var ceilingBoundaryPoints: [SIMD2<Float>] = []
    @Published var ceilingHeight: Float?

    // Floor measurement
    @Published var floorHeight: Float?
    @Published var distanceToFloor: Float?
    @Published var isPointingAtFloor: Bool = false

    // Room dimensions
    @Published var roomHeight: Float?

    // Generated wall mesh
    @Published var generatedWallMesh: CapturedMeshData?

    // MARK: - Configuration
    let wallThickness: Float = 0.10  // 10cm thick walls
    private let minPointDistance: Float = 0.15  // 15cm between boundary points
    private let floorAngleThreshold: Float = -0.6  // Must point down (negative Y)
    private let ceilingAngleThreshold: Float = 0.3  // Must point somewhat up

    // MARK: - Internal State
    private var boundaryPointsRaw: [SIMD3<Float>] = []  // Full 3D points
    private var floorSamples: [Float] = []
    private var ceilingSamples: [Float] = []

    // MARK: - Public Methods

    func startScanning() {
        isScanning = true
        phase = .scanningCeilingBoundary
        reset()
    }

    func stopScanning() {
        isScanning = false
        if phase == .complete {
            generateWallMesh()
        }
    }

    func nextPhase() {
        switch phase {
        case .ready:
            phase = .scanningCeilingBoundary
        case .scanningCeilingBoundary:
            if ceilingBoundaryPoints.count >= 3 {
                phase = .measuringFloor
            }
        case .measuringFloor:
            if floorHeight != nil && ceilingHeight != nil {
                roomHeight = ceilingHeight! - floorHeight!
                phase = .complete
                generateWallMesh()
            }
        case .complete:
            break
        }
    }

    /// Process AR frame - detect ceiling boundary or floor
    func processFrame(_ frame: ARFrame) {
        guard isScanning else { return }

        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Get camera forward direction
        let forward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        switch phase {
        case .scanningCeilingBoundary:
            processCeilingBoundary(frame: frame, cameraPosition: cameraPosition, forward: forward)

        case .measuringFloor:
            processFloorMeasurement(frame: frame, cameraPosition: cameraPosition, forward: forward)

        default:
            break
        }
    }

    func reset() {
        ceilingBoundaryPoints = []
        boundaryPointsRaw = []
        ceilingHeight = nil
        floorHeight = nil
        distanceToFloor = nil
        roomHeight = nil
        generatedWallMesh = nil
        floorSamples = []
        ceilingSamples = []
        isPointingAtFloor = false
    }

    // MARK: - Ceiling Boundary Detection

    private func processCeilingBoundary(frame: ARFrame, cameraPosition: SIMD3<Float>, forward: SIMD3<Float>) {
        // Must be pointing somewhat upward to scan ceiling boundary
        guard forward.y > ceilingAngleThreshold else { return }

        // Get depth at center of frame
        guard let depth = getCenterDepth(from: frame) else { return }

        // Calculate 3D point where we're looking
        let hitPoint = cameraPosition + forward * depth

        // Record ceiling height from the Y value
        ceilingSamples.append(hitPoint.y)
        if ceilingSamples.count > 50 {
            ceilingSamples.removeFirst()
        }
        if ceilingSamples.count >= 5 {
            let sorted = ceilingSamples.sorted()
            ceilingHeight = sorted[sorted.count * 3 / 4]  // 75th percentile (highest consistent point)
        }

        // Add boundary point if far enough from last point
        let point2D = SIMD2<Float>(hitPoint.x, hitPoint.z)

        if let lastPoint = ceilingBoundaryPoints.last {
            let distance = simd_distance(point2D, lastPoint)
            if distance >= minPointDistance {
                ceilingBoundaryPoints.append(point2D)
                boundaryPointsRaw.append(hitPoint)
            }
        } else {
            ceilingBoundaryPoints.append(point2D)
            boundaryPointsRaw.append(hitPoint)
        }
    }

    // MARK: - Floor Measurement

    private func processFloorMeasurement(frame: ARFrame, cameraPosition: SIMD3<Float>, forward: SIMD3<Float>) {
        // Must be pointing downward
        isPointingAtFloor = forward.y < floorAngleThreshold

        guard isPointingAtFloor else {
            distanceToFloor = nil
            return
        }

        // Get depth at center of frame
        guard let depth = getCenterDepth(from: frame) else { return }

        distanceToFloor = depth

        // Calculate floor height (Y position of floor)
        let floorPoint = cameraPosition + forward * depth
        floorSamples.append(floorPoint.y)

        if floorSamples.count > 30 {
            floorSamples.removeFirst()
        }

        if floorSamples.count >= 5 {
            let sorted = floorSamples.sorted()
            floorHeight = sorted[sorted.count / 4]  // 25th percentile (lowest consistent point)

            // Calculate room height if we have ceiling
            if let ceiling = ceilingHeight {
                roomHeight = ceiling - floorHeight!
            }
        }
    }

    // MARK: - Wall Mesh Generation

    private func generateWallMesh() {
        guard let floorY = floorHeight,
              let ceilingY = ceilingHeight,
              ceilingBoundaryPoints.count >= 3 else {
            print("[Trial1] Cannot generate walls: missing floor/ceiling or insufficient points")
            return
        }

        // Order points clockwise
        let orderedPoints = orderClockwise(ceilingBoundaryPoints)

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[UInt32]] = []

        // Generate wall segments between each pair of boundary points
        for i in 0..<orderedPoints.count {
            let start = orderedPoints[i]
            let end = orderedPoints[(i + 1) % orderedPoints.count]

            // Calculate wall direction and normal
            let wallDir = simd_normalize(end - start)
            let wallLength = simd_distance(start, end)

            // Normal points inward (perpendicular to wall, right-hand rule for clockwise)
            let normalDir = SIMD2<Float>(wallDir.y, -wallDir.x)
            let normal3D = SIMD3<Float>(normalDir.x, 0, normalDir.y)

            // Create wall quad with thickness (outer and inner surfaces)
            let wallMesh = createThickWall(
                start: start,
                end: end,
                floorY: floorY,
                ceilingY: ceilingY,
                thickness: wallThickness,
                inwardNormal: normalDir
            )

            // Append to mesh
            let offset = UInt32(vertices.count)
            vertices.append(contentsOf: wallMesh.vertices)
            normals.append(contentsOf: wallMesh.normals)
            faces.append(contentsOf: wallMesh.faces.map { [$0[0] + offset, $0[1] + offset, $0[2] + offset] })
        }

        generatedWallMesh = CapturedMeshData(
            vertices: vertices,
            normals: normals,
            colors: [],
            faces: faces,
            transform: matrix_identity_float4x4,
            identifier: UUID(),
            surfaceType: .wall
        )

        print("[Trial1] Generated wall mesh: \(vertices.count) vertices, \(faces.count) faces, \(orderedPoints.count) wall segments")
    }

    /// Create a thick wall segment (box with 6 faces)
    private func createThickWall(
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        floorY: Float,
        ceilingY: Float,
        thickness: Float,
        inwardNormal: SIMD2<Float>
    ) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [[UInt32]]) {

        // Offset for inner and outer surfaces
        let halfThick = thickness / 2
        let outward = SIMD2<Float>(-inwardNormal.x, -inwardNormal.y)

        // Outer edge (away from room center)
        let outerStart = start + outward * halfThick
        let outerEnd = end + outward * halfThick

        // Inner edge (toward room center)
        let innerStart = start - outward * halfThick
        let innerEnd = end - outward * halfThick

        // 8 vertices of the wall box
        let v0 = SIMD3<Float>(outerStart.x, floorY, outerStart.y)    // Outer bottom start
        let v1 = SIMD3<Float>(outerEnd.x, floorY, outerEnd.y)        // Outer bottom end
        let v2 = SIMD3<Float>(outerEnd.x, ceilingY, outerEnd.y)      // Outer top end
        let v3 = SIMD3<Float>(outerStart.x, ceilingY, outerStart.y)  // Outer top start

        let v4 = SIMD3<Float>(innerStart.x, floorY, innerStart.y)    // Inner bottom start
        let v5 = SIMD3<Float>(innerEnd.x, floorY, innerEnd.y)        // Inner bottom end
        let v6 = SIMD3<Float>(innerEnd.x, ceilingY, innerEnd.y)      // Inner top end
        let v7 = SIMD3<Float>(innerStart.x, ceilingY, innerStart.y)  // Inner top start

        let vertices = [v0, v1, v2, v3, v4, v5, v6, v7]

        // Normals for each face
        let outNormal = SIMD3<Float>(outward.x, 0, outward.y)
        let inNormal = SIMD3<Float>(-outward.x, 0, -outward.y)
        let upNormal = SIMD3<Float>(0, 1, 0)
        let downNormal = SIMD3<Float>(0, -1, 0)

        // Wall direction for side normals
        let wallDir = simd_normalize(end - start)
        let startNormal = SIMD3<Float>(-wallDir.x, 0, -wallDir.y)
        let endNormal = SIMD3<Float>(wallDir.x, 0, wallDir.y)

        // Faces (each face needs its own vertices for proper normals)
        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []

        // Helper to add a quad
        func addQuad(v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>, v3: SIMD3<Float>, normal: SIMD3<Float>) {
            let idx = UInt32(allVertices.count)
            allVertices.append(contentsOf: [v0, v1, v2, v3])
            allNormals.append(contentsOf: [normal, normal, normal, normal])
            allFaces.append([idx, idx + 1, idx + 2])
            allFaces.append([idx, idx + 2, idx + 3])
        }

        // Outer face (facing out)
        addQuad(v0: v0, v1: v1, v2: v2, v3: v3, normal: outNormal)

        // Inner face (facing in)
        addQuad(v0: v5, v1: v4, v2: v7, v3: v6, normal: inNormal)

        // Top face
        addQuad(v0: v3, v1: v2, v2: v6, v3: v7, normal: upNormal)

        // Bottom face
        addQuad(v0: v4, v1: v5, v2: v1, v3: v0, normal: downNormal)

        // Start cap
        addQuad(v0: v4, v1: v0, v2: v3, v3: v7, normal: startNormal)

        // End cap
        addQuad(v0: v1, v1: v5, v2: v6, v3: v2, normal: endNormal)

        return (allVertices, allNormals, allFaces)
    }

    // MARK: - Helpers

    private func getCenterDepth(from frame: ARFrame) -> Float? {
        guard let depthMap = frame.sceneDepth?.depthMap else { return nil }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

        let centerX = width / 2
        let centerY = height / 2
        let index = centerY * width + centerX

        let depth = floatBuffer[index]

        guard depth > 0.1 && depth < 10.0 else { return nil }

        return depth
    }

    private func orderClockwise(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }

        let center = points.reduce(.zero, +) / Float(points.count)

        return points.sorted { p1, p2 in
            let angle1 = atan2(p1.y - center.y, p1.x - center.x)
            let angle2 = atan2(p2.y - center.y, p2.x - center.x)
            return angle1 > angle2
        }
    }
}
