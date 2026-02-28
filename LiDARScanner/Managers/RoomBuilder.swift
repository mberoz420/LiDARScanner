import Foundation
import simd
import ARKit

/// Intelligent room geometry builder
/// - Floor is normalized to Y=0
/// - Ceiling is at Y=roomHeight
/// - Only full-height vertical surfaces are walls
/// - Detects openings (doors, windows, glass)
/// - Excludes furniture and objects that don't reach ceiling
@MainActor
class RoomBuilder: ObservableObject {

    // MARK: - Published State
    @Published var roomHeight: Float = 0
    @Published var floorLevel: Float = 0
    @Published var wallSegments: [WallSegment] = []
    @Published var detectedOpenings: [WallOpening] = []
    @Published var roomCorners: [RoomCorner] = []
    @Published var isCalibrated: Bool = false

    // MARK: - Configuration

    /// Tolerance for surface reaching floor/ceiling (meters)
    private let heightTolerance: Float = 0.15

    /// Minimum wall segment length to consider valid
    private let minWallLength: Float = 0.3

    /// Door height range
    private let doorHeightRange: ClosedRange<Float> = 1.8...2.5
    private let doorWidthRange: ClosedRange<Float> = 0.6...1.5

    /// Window detection
    private let windowMinHeight: Float = 0.4
    private let windowMinWidth: Float = 0.3
    private let windowMinFromFloor: Float = 0.5  // Windows start at least 50cm from floor

    /// Glass detection - LiDAR return strength threshold
    private let glassReturnThreshold: Float = 0.3  // Weak returns indicate glass

    /// Furniture exclusion - anything not reaching this % of ceiling is excluded
    private let ceilingReachThreshold: Float = 0.85  // Must reach 85% of room height

    // MARK: - Internal State

    private var verticalSurfaces: [VerticalSurface] = []
    private var horizontalSamples: [(position: SIMD3<Float>, isFloor: Bool)] = []

    // MARK: - Calibration

    /// Set floor level (Y=0 reference)
    func calibrateFloor(at height: Float) {
        floorLevel = height
        updateCalibration()
    }

    /// Set ceiling level and compute room height
    func calibrateCeiling(at height: Float) {
        roomHeight = height - floorLevel
        updateCalibration()
    }

    private func updateCalibration() {
        isCalibrated = floorLevel != 0 || roomHeight > 0
    }

    /// Get normalized Y coordinate (floor = 0, ceiling = roomHeight)
    func normalizedY(_ worldY: Float) -> Float {
        return worldY - floorLevel
    }

    // MARK: - Surface Processing

    /// Process a vertical surface and determine if it's a wall
    func processVerticalSurface(
        vertices: [SIMD3<Float>],
        normal: SIMD3<Float>,
        transform: simd_float4x4,
        meshID: UUID
    ) {
        guard isCalibrated, roomHeight > 0 else { return }

        // Transform vertices to world space
        let worldVertices = vertices.map { transformPoint($0, by: transform) }

        // Get height range of this surface
        let heights = worldVertices.map { normalizedY($0.y) }
        guard let minH = heights.min(), let maxH = heights.max() else { return }

        let surfaceHeight = maxH - minH
        let reachesCeiling = maxH >= roomHeight * ceilingReachThreshold
        let reachesFloor = minH <= heightTolerance

        // WALL: Must span from floor to near ceiling
        if reachesFloor && reachesCeiling {
            // This is a valid wall segment
            let segment = createWallSegment(
                vertices: worldVertices,
                normal: normal,
                minHeight: minH,
                maxHeight: maxH,
                meshID: meshID
            )

            // Check for openings in this wall
            detectOpenings(in: segment, vertices: worldVertices)

            addOrUpdateWallSegment(segment)
        }
        // FURNITURE/OBJECT: Doesn't reach ceiling - exclude
        else if !reachesCeiling {
            // This is furniture, cabinets, appliances - ignore for room geometry
            // Could track separately for room contents
        }
        // PARTIAL WALL: Reaches ceiling but not floor - could be above an opening
        else if reachesCeiling && !reachesFloor {
            // Wall section above a door or window
            // Store for later wall completion
            let partial = PartialWall(
                vertices: worldVertices,
                normal: normal,
                minHeight: minH,
                maxHeight: maxH
            )
            processPartialWall(partial)
        }
    }

    /// Detect if this is glass (LiDAR passes through)
    func detectGlass(
        at position: SIMD3<Float>,
        expectedWallNormal: SIMD3<Float>,
        returnStrength: Float
    ) -> Bool {
        // Very weak LiDAR return suggests glass
        // Normal windows and glass doors won't reflect LiDAR well
        return returnStrength < glassReturnThreshold
    }

    /// Process areas with no LiDAR returns (potential glass/openings)
    func processNoReturnArea(
        bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
        adjacentWallNormal: SIMD3<Float>
    ) {
        let normalizedMin = normalizedY(bounds.min.y)
        let normalizedMax = normalizedY(bounds.max.y)
        let width = simd_distance(
            SIMD3<Float>(bounds.min.x, 0, bounds.min.z),
            SIMD3<Float>(bounds.max.x, 0, bounds.max.z)
        )
        let height = normalizedMax - normalizedMin

        // Classify the opening
        let openingType = classifyOpening(
            bottomHeight: normalizedMin,
            topHeight: normalizedMax,
            width: width,
            height: height
        )

        if let type = openingType {
            let center = (bounds.min + bounds.max) / 2
            let opening = WallOpening(
                id: UUID(),
                type: type,
                position: center,
                width: width,
                height: height,
                bottomFromFloor: normalizedMin,
                wallNormal: adjacentWallNormal
            )
            detectedOpenings.append(opening)
        }
    }

    // MARK: - Opening Classification

    private func classifyOpening(
        bottomHeight: Float,
        topHeight: Float,
        width: Float,
        height: Float
    ) -> WallOpening.OpeningType? {

        // DOOR: Starts at floor, goes up 1.8-2.5m
        if bottomHeight <= heightTolerance &&
           doorHeightRange.contains(height) &&
           doorWidthRange.contains(width) {
            return .door
        }

        // WINDOW: Starts above floor, doesn't reach ceiling
        if bottomHeight >= windowMinFromFloor &&
           topHeight < roomHeight - heightTolerance &&
           width >= windowMinWidth &&
           height >= windowMinHeight {
            return .window
        }

        // GLASS DOOR/WALL: Floor to ceiling opening (glass wall or sliding door)
        if bottomHeight <= heightTolerance &&
           topHeight >= roomHeight * ceilingReachThreshold &&
           width >= doorWidthRange.lowerBound {
            return .glassDoor
        }

        // PASS-THROUGH: Opening in wall (like kitchen pass-through)
        if bottomHeight > heightTolerance &&
           topHeight < roomHeight - heightTolerance &&
           width >= 0.4 {
            return .passThrough
        }

        return nil
    }

    // MARK: - Wall Building

    private func createWallSegment(
        vertices: [SIMD3<Float>],
        normal: SIMD3<Float>,
        minHeight: Float,
        maxHeight: Float,
        meshID: UUID
    ) -> WallSegment {
        // Get wall bounds on XZ plane
        let xCoords = vertices.map { $0.x }
        let zCoords = vertices.map { $0.z }

        let startPoint = SIMD2<Float>(xCoords.min() ?? 0, zCoords.min() ?? 0)
        let endPoint = SIMD2<Float>(xCoords.max() ?? 0, zCoords.max() ?? 0)

        return WallSegment(
            id: meshID,
            startPoint: startPoint,
            endPoint: endPoint,
            normal: SIMD2<Float>(normal.x, normal.z),
            height: maxHeight - minHeight,
            bottomY: minHeight,
            openings: []
        )
    }

    private func addOrUpdateWallSegment(_ segment: WallSegment) {
        // Check if this merges with existing segment
        if let existingIndex = wallSegments.firstIndex(where: { canMerge($0, with: segment) }) {
            wallSegments[existingIndex] = mergeSegments(wallSegments[existingIndex], segment)
        } else {
            wallSegments.append(segment)
        }

        // Update corners
        updateRoomCorners()
    }

    private func canMerge(_ a: WallSegment, with b: WallSegment) -> Bool {
        // Same wall if normals are similar and endpoints are close
        let normalDot = simd_dot(a.normal, b.normal)
        guard normalDot > 0.95 else { return false }  // Nearly parallel

        let endpointDist = min(
            simd_distance(a.endPoint, b.startPoint),
            simd_distance(a.startPoint, b.endPoint)
        )
        return endpointDist < 0.3  // Within 30cm
    }

    private func mergeSegments(_ a: WallSegment, _ b: WallSegment) -> WallSegment {
        // Extend to cover both segments
        let allX = [a.startPoint.x, a.endPoint.x, b.startPoint.x, b.endPoint.x]
        let allZ = [a.startPoint.y, a.endPoint.y, b.startPoint.y, b.endPoint.y]

        return WallSegment(
            id: a.id,
            startPoint: SIMD2<Float>(allX.min()!, allZ.min()!),
            endPoint: SIMD2<Float>(allX.max()!, allZ.max()!),
            normal: a.normal,
            height: max(a.height, b.height),
            bottomY: min(a.bottomY, b.bottomY),
            openings: a.openings + b.openings
        )
    }

    private func processPartialWall(_ partial: PartialWall) {
        // Wall above an opening - find the corresponding wall segment
        // and add an opening below it
    }

    private func detectOpenings(in segment: WallSegment, vertices: [SIMD3<Float>]) {
        // Analyze vertex density along the wall
        // Gaps in vertex coverage indicate openings

        // Sort vertices by position along wall
        let wallDirection = normalize(segment.endPoint - segment.startPoint)
        let wallLength = simd_distance(segment.startPoint, segment.endPoint)

        // Create height profile along wall
        let bucketCount = Int(wallLength / 0.1)  // 10cm buckets
        guard bucketCount > 0 else { return }

        var heightProfile: [[Float]] = Array(repeating: [], count: bucketCount)

        for vertex in vertices {
            let pos2D = SIMD2<Float>(vertex.x, vertex.z)
            let projectedDist = simd_dot(pos2D - segment.startPoint, wallDirection)
            let bucketIndex = min(Int(projectedDist / 0.1), bucketCount - 1)
            if bucketIndex >= 0 {
                heightProfile[bucketIndex].append(normalizedY(vertex.y))
            }
        }

        // Find gaps in height coverage (potential openings)
        for (index, heights) in heightProfile.enumerated() {
            if heights.isEmpty { continue }

            let minH = heights.min() ?? 0
            let maxH = heights.max() ?? roomHeight

            // Gap at bottom = door
            if minH > heightTolerance {
                let position = segment.startPoint + wallDirection * Float(index) * 0.1
                // Potential door detected
            }

            // Gap in middle = window
            // (would need more sophisticated analysis)
        }
    }

    // MARK: - Corner Detection

    private func updateRoomCorners() {
        roomCorners.removeAll()

        // Find intersections between wall segments
        for i in 0..<wallSegments.count {
            for j in (i+1)..<wallSegments.count {
                if let corner = findCorner(between: wallSegments[i], and: wallSegments[j]) {
                    roomCorners.append(corner)
                }
            }
        }
    }

    private func findCorner(between a: WallSegment, and b: WallSegment) -> RoomCorner? {
        // Check if walls are perpendicular (corner)
        let dot = abs(simd_dot(a.normal, b.normal))
        guard dot < 0.3 else { return nil }  // Not perpendicular

        // Find closest endpoints
        let distances = [
            (simd_distance(a.startPoint, b.startPoint), a.startPoint, b.startPoint),
            (simd_distance(a.startPoint, b.endPoint), a.startPoint, b.endPoint),
            (simd_distance(a.endPoint, b.startPoint), a.endPoint, b.startPoint),
            (simd_distance(a.endPoint, b.endPoint), a.endPoint, b.endPoint)
        ]

        guard let closest = distances.min(by: { $0.0 < $1.0 }),
              closest.0 < 0.3 else { return nil }

        let cornerPoint = (closest.1 + closest.2) / 2
        let angle = acos(simd_dot(a.normal, b.normal))

        return RoomCorner(
            id: UUID(),
            position: SIMD3<Float>(cornerPoint.x, floorLevel, cornerPoint.y),
            angle: angle,
            wallIDs: [a.id, b.id]
        )
    }

    // MARK: - Helpers

    private func transformPoint(_ point: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let p = SIMD4<Float>(point.x, point.y, point.z, 1)
        let transformed = transform * p
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    // MARK: - Reset

    func reset() {
        roomHeight = 0
        floorLevel = 0
        wallSegments.removeAll()
        detectedOpenings.removeAll()
        roomCorners.removeAll()
        verticalSurfaces.removeAll()
        horizontalSamples.removeAll()
        isCalibrated = false
    }
}

// MARK: - Supporting Types

struct WallSegment: Identifiable {
    let id: UUID
    var startPoint: SIMD2<Float>  // XZ coordinates
    var endPoint: SIMD2<Float>
    var normal: SIMD2<Float>      // Wall facing direction (XZ)
    var height: Float
    var bottomY: Float            // Normalized Y of bottom
    var openings: [WallOpening]

    var length: Float {
        simd_distance(startPoint, endPoint)
    }

    var center: SIMD2<Float> {
        (startPoint + endPoint) / 2
    }
}

struct WallOpening: Identifiable {
    let id: UUID
    let type: OpeningType
    let position: SIMD3<Float>
    let width: Float
    let height: Float
    let bottomFromFloor: Float
    let wallNormal: SIMD3<Float>

    enum OpeningType: String {
        case door = "Door"
        case window = "Window"
        case glassDoor = "Glass Door"
        case passThrough = "Pass-Through"
    }
}

struct RoomCorner: Identifiable {
    let id: UUID
    let position: SIMD3<Float>
    let angle: Float              // Angle between walls (radians)
    let wallIDs: [UUID]
}

struct VerticalSurface {
    let meshID: UUID
    let vertices: [SIMD3<Float>]
    let normal: SIMD3<Float>
    let minHeight: Float
    let maxHeight: Float
}

struct PartialWall {
    let vertices: [SIMD3<Float>]
    let normal: SIMD3<Float>
    let minHeight: Float
    let maxHeight: Float
}
