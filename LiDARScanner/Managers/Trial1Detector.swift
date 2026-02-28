import Foundation
import simd
import ARKit

/// Trial 1: Detect wall-ceiling intersections and calculate distances
@MainActor
class Trial1Detector: ObservableObject {

    // MARK: - Published State
    @Published var ceilingHeight: Float?           // Measured ceiling height
    @Published var distanceToTarget: Float?        // Real-time distance when pointing up
    @Published var wallCeilingEdges: [WallCeilingEdge] = []  // Detected intersection lines
    @Published var isPointingAtCeiling: Bool = false

    // MARK: - Data Structures

    struct WallCeilingEdge: Identifiable {
        let id: UUID
        let startPoint: SIMD3<Float>    // 3D start of edge
        let endPoint: SIMD3<Float>      // 3D end of edge
        let wallDirection: SIMD2<Float> // XZ direction of wall

        var length: Float {
            simd_distance(startPoint, endPoint)
        }

        // 2D projection for floor plan
        var start2D: SIMD2<Float> {
            SIMD2<Float>(startPoint.x, startPoint.z)
        }
        var end2D: SIMD2<Float> {
            SIMD2<Float>(endPoint.x, endPoint.z)
        }
    }

    // MARK: - Configuration

    private let minEdgeLength: Float = 0.3       // 30cm minimum edge
    private let ceilingAngleThreshold: Float = 0.7  // ~45 degrees up
    private let mergeDistance: Float = 0.15      // 15cm to merge nearby edges

    // MARK: - Internal State

    private var ceilingHeightSamples: [Float] = []
    private var rawEdges: [WallCeilingEdge] = []

    // MARK: - Public Methods

    /// Process AR frame to detect ceiling when pointing up
    func processFrame(_ frame: ARFrame, floorHeight: Float?) {
        let cameraTransform = frame.camera.transform

        // Get camera forward direction
        let forward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        // Check if pointing up (forward.y > threshold)
        isPointingAtCeiling = forward.y > ceilingAngleThreshold

        if isPointingAtCeiling {
            // Calculate distance to ceiling using raycast
            if let distance = calculateCeilingDistance(from: frame) {
                distanceToTarget = distance

                // Calculate absolute ceiling height
                let cameraY = cameraTransform.columns.3.y
                let absoluteCeilingHeight = cameraY + (distance * forward.y)

                // Accumulate samples for stable measurement
                ceilingHeightSamples.append(absoluteCeilingHeight)
                if ceilingHeightSamples.count > 30 {
                    ceilingHeightSamples.removeFirst()
                }

                // Use median for stability
                if ceilingHeightSamples.count >= 5 {
                    let sorted = ceilingHeightSamples.sorted()
                    ceilingHeight = sorted[sorted.count / 2]
                }
            }
        } else {
            distanceToTarget = nil
        }
    }

    /// Process detected edges from SurfaceClassifier
    func processEdges(_ edges: [WallEdge], ceilingY: Float?) {
        // Filter for ceiling-wall edges only
        let ceilingWallEdges = edges.filter { $0.edgeType == .ceilingWall }

        // Convert to our edge type
        for edge in ceilingWallEdges {
            guard edge.length >= minEdgeLength else { continue }

            // Calculate wall direction (XZ plane)
            let dir3D = edge.endPoint - edge.startPoint
            let length2D = sqrt(dir3D.x * dir3D.x + dir3D.z * dir3D.z)
            guard length2D > 0.001 else { continue }
            let dir2D = SIMD2<Float>(dir3D.x / length2D, dir3D.z / length2D)

            let newEdge = WallCeilingEdge(
                id: edge.id,
                startPoint: edge.startPoint,
                endPoint: edge.endPoint,
                wallDirection: dir2D
            )

            // Check if we should merge with existing edge
            if !mergeWithExisting(newEdge) {
                rawEdges.append(newEdge)
            }
        }

        // Update published edges (merged and filtered)
        wallCeilingEdges = mergeCollinearEdges(rawEdges)
    }

    /// Get inferred wall lines from ceiling intersections
    func getWallLines() -> [(start: SIMD2<Float>, end: SIMD2<Float>)] {
        return wallCeilingEdges.map { edge in
            (edge.start2D, edge.end2D)
        }
    }

    /// Reset all state
    func reset() {
        ceilingHeight = nil
        distanceToTarget = nil
        wallCeilingEdges = []
        isPointingAtCeiling = false
        ceilingHeightSamples = []
        rawEdges = []
    }

    // MARK: - Private Methods

    private func calculateCeilingDistance(from frame: ARFrame) -> Float? {
        // Use depth data if available
        guard let depthMap = frame.sceneDepth?.depthMap else { return nil }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

        // Sample center of frame
        let centerX = width / 2
        let centerY = height / 2
        let index = centerY * width + centerX

        let depth = floatBuffer[index]

        // Filter invalid depths
        guard depth > 0.1 && depth < 10.0 else { return nil }

        return depth
    }

    private func mergeWithExisting(_ newEdge: WallCeilingEdge) -> Bool {
        for i in 0..<rawEdges.count {
            let existing = rawEdges[i]

            // Check if endpoints are close
            let startClose = simd_distance(existing.startPoint, newEdge.startPoint) < mergeDistance ||
                             simd_distance(existing.startPoint, newEdge.endPoint) < mergeDistance
            let endClose = simd_distance(existing.endPoint, newEdge.startPoint) < mergeDistance ||
                           simd_distance(existing.endPoint, newEdge.endPoint) < mergeDistance

            // Check if collinear (similar direction)
            let dotProduct = abs(simd_dot(existing.wallDirection, newEdge.wallDirection))
            let collinear = dotProduct > 0.95

            if (startClose || endClose) && collinear {
                // Merge: extend existing edge
                let allPoints = [existing.startPoint, existing.endPoint,
                                newEdge.startPoint, newEdge.endPoint]

                // Find extreme points along wall direction
                let projected = allPoints.map { p in
                    simd_dot(SIMD2<Float>(p.x, p.z), existing.wallDirection)
                }
                guard let minVal = projected.min(),
                      let maxVal = projected.max(),
                      let minIdx = projected.firstIndex(of: minVal),
                      let maxIdx = projected.firstIndex(of: maxVal) else {
                    continue
                }

                rawEdges[i] = WallCeilingEdge(
                    id: existing.id,
                    startPoint: allPoints[minIdx],
                    endPoint: allPoints[maxIdx],
                    wallDirection: existing.wallDirection
                )
                return true
            }
        }
        return false
    }

    private func mergeCollinearEdges(_ edges: [WallCeilingEdge]) -> [WallCeilingEdge] {
        // Group edges by similar direction
        var groups: [[WallCeilingEdge]] = []

        for edge in edges {
            var foundGroup = false
            for i in 0..<groups.count {
                if let first = groups[i].first {
                    let dot = abs(simd_dot(first.wallDirection, edge.wallDirection))
                    if dot > 0.95 {
                        groups[i].append(edge)
                        foundGroup = true
                        break
                    }
                }
            }
            if !foundGroup {
                groups.append([edge])
            }
        }

        // Return longest edge from each group
        return groups.compactMap { group in
            group.max(by: { $0.length < $1.length })
        }
    }
}
