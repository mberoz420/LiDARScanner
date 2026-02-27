import Foundation
import simd

/// A simplified room representation - just floor polygon, ceiling, and walls
struct SimplifiedRoom {
    let floorHeight: Float
    let ceilingHeight: Float
    let floorPolygon: [SIMD2<Float>]  // 2D points (X, Z) forming floor outline
    let protrusions: [SimplifiedProtrusion]

    var roomHeight: Float {
        ceilingHeight - floorHeight
    }

    var floorArea: Float {
        calculatePolygonArea(floorPolygon)
    }

    var perimeterLength: Float {
        var length: Float = 0
        for i in 0..<floorPolygon.count {
            let p1 = floorPolygon[i]
            let p2 = floorPolygon[(i + 1) % floorPolygon.count]
            length += simd_distance(p1, p2)
        }
        return length
    }

    var vertexCount: Int {
        // Floor vertices + ceiling vertices + protrusion vertices
        floorPolygon.count * 2 + protrusions.reduce(0) { $0 + $1.polygon.count * 2 }
    }

    var wallCount: Int {
        floorPolygon.count
    }

    private func calculatePolygonArea(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var area: Float = 0
        for i in 0..<polygon.count {
            let j = (i + 1) % polygon.count
            area += polygon[i].x * polygon[j].y
            area -= polygon[j].x * polygon[i].y
        }
        return abs(area) / 2
    }
}

/// Simplified ceiling protrusion (beam, duct)
struct SimplifiedProtrusion {
    let polygon: [SIMD2<Float>]  // 2D outline
    let topHeight: Float         // Top of protrusion (at ceiling)
    let bottomHeight: Float      // Bottom of protrusion

    var depth: Float {
        topHeight - bottomHeight
    }
}

/// Extracts simplified room geometry from dense mesh data
@MainActor
class RoomSimplifier: ObservableObject {

    // MARK: - Configuration

    /// Grid resolution for edge detection (meters)
    var gridResolution: Float = 0.1  // 10cm

    /// Minimum wall segment length to keep (meters)
    var minWallLength: Float = 0.3  // 30cm

    /// Angle threshold for merging collinear walls (degrees)
    var collinearThreshold: Float = 10.0

    /// Distance threshold for snapping corners (meters)
    var cornerSnapDistance: Float = 0.15  // 15cm

    // MARK: - Extract Simplified Room

    func extractSimplifiedRoom(from scan: CapturedScan, statistics: ScanStatistics) -> SimplifiedRoom? {
        guard let floorHeight = statistics.floorHeight,
              let ceilingHeight = statistics.ceilingHeight else {
            return nil
        }

        // Step 1: Extract wall edge points at floor level
        let wallPoints = extractWallPoints(from: scan.meshes, atHeight: floorHeight, statistics: statistics)

        guard wallPoints.count >= 3 else { return nil }

        // Step 2: Create convex hull or outline from points
        var floorPolygon = createRoomOutline(from: wallPoints)

        // Step 3: Simplify the polygon (merge collinear edges, snap corners)
        floorPolygon = simplifyPolygon(floorPolygon)

        // Step 4: Extract protrusions
        let protrusions = extractProtrusions(from: statistics, ceilingHeight: ceilingHeight)

        return SimplifiedRoom(
            floorHeight: floorHeight,
            ceilingHeight: ceilingHeight,
            floorPolygon: floorPolygon,
            protrusions: protrusions
        )
    }

    // MARK: - Wall Point Extraction

    private func extractWallPoints(from meshes: [CapturedMeshData], atHeight: Float, statistics: ScanStatistics) -> [SIMD2<Float>] {
        var wallPoints: Set<GridPoint> = []

        let heightTolerance: Float = 0.3  // Look for walls within 30cm of floor

        for mesh in meshes {
            // Only process wall meshes
            guard mesh.surfaceType == .wall || mesh.surfaceType == .wallEdge else { continue }

            for vertex in mesh.vertices {
                // Transform to world space
                let worldVertex = transformPoint(vertex, by: mesh.transform)

                // Check if vertex is near floor height (wall base)
                if abs(worldVertex.y - atHeight) < heightTolerance {
                    // Snap to grid
                    let gridX = Int(round(worldVertex.x / gridResolution))
                    let gridZ = Int(round(worldVertex.z / gridResolution))
                    wallPoints.insert(GridPoint(x: gridX, z: gridZ))
                }
            }
        }

        // Convert grid points back to world coordinates
        return wallPoints.map { point in
            SIMD2<Float>(Float(point.x) * gridResolution, Float(point.z) * gridResolution)
        }
    }

    // MARK: - Room Outline Creation

    private func createRoomOutline(from points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }

        // Use convex hull as starting point, then refine
        let hull = convexHull(points)

        // For more complex rooms, we could use alpha shapes or concave hull
        // For now, convex hull gives us the outer boundary

        return hull
    }

    /// Compute convex hull using Graham scan
    private func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }

        // Find bottom-most point (or left-most in case of tie)
        var sorted = points.sorted { p1, p2 in
            if p1.y != p2.y { return p1.y < p2.y }
            return p1.x < p2.x
        }

        let pivot = sorted.removeFirst()

        // Sort by polar angle with respect to pivot
        sorted.sort { p1, p2 in
            let angle1 = atan2(p1.y - pivot.y, p1.x - pivot.x)
            let angle2 = atan2(p2.y - pivot.y, p2.x - pivot.x)
            if abs(angle1 - angle2) < 0.001 {
                // Same angle - keep closer point first
                return simd_distance(p1, pivot) < simd_distance(p2, pivot)
            }
            return angle1 < angle2
        }

        var hull: [SIMD2<Float>] = [pivot]

        for point in sorted {
            while hull.count >= 2 {
                let top = hull[hull.count - 1]
                let nextToTop = hull[hull.count - 2]

                // Check if we make a left turn
                let cross = (top.x - nextToTop.x) * (point.y - nextToTop.y) -
                            (top.y - nextToTop.y) * (point.x - nextToTop.x)

                if cross <= 0 {
                    hull.removeLast()
                } else {
                    break
                }
            }
            hull.append(point)
        }

        return hull
    }

    // MARK: - Polygon Simplification

    private func simplifyPolygon(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard polygon.count >= 3 else { return polygon }

        var simplified = polygon

        // Step 1: Remove short segments
        simplified = removeShortSegments(simplified)

        // Step 2: Merge collinear segments
        simplified = mergeCollinearSegments(simplified)

        // Step 3: Snap to right angles where close
        simplified = snapToRightAngles(simplified)

        // Step 4: Snap nearby corners
        simplified = snapNearbyCorners(simplified)

        return simplified
    }

    private func removeShortSegments(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard polygon.count > 4 else { return polygon }  // Keep at least 4 corners

        var result: [SIMD2<Float>] = []

        for i in 0..<polygon.count {
            let current = polygon[i]
            let next = polygon[(i + 1) % polygon.count]

            if simd_distance(current, next) >= minWallLength {
                result.append(current)
            }
        }

        return result.count >= 3 ? result : polygon
    }

    private func mergeCollinearSegments(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard polygon.count > 4 else { return polygon }

        var result: [SIMD2<Float>] = []
        let thresholdRadians = collinearThreshold * .pi / 180

        for i in 0..<polygon.count {
            let prev = polygon[(i - 1 + polygon.count) % polygon.count]
            let current = polygon[i]
            let next = polygon[(i + 1) % polygon.count]

            let angle1 = atan2(current.y - prev.y, current.x - prev.x)
            let angle2 = atan2(next.y - current.y, next.x - current.x)

            var angleDiff = abs(angle1 - angle2)
            if angleDiff > .pi { angleDiff = 2 * .pi - angleDiff }

            // Keep point if angle change is significant
            if angleDiff > thresholdRadians {
                result.append(current)
            }
        }

        return result.count >= 3 ? result : polygon
    }

    private func snapToRightAngles(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        // Snap angles close to 90° to exactly 90°
        let snapThreshold: Float = 15 * .pi / 180  // 15 degrees

        var result = polygon

        for i in 0..<result.count {
            let prev = result[(i - 1 + result.count) % result.count]
            let current = result[i]
            let next = result[(i + 1) % result.count]

            let v1 = normalize(prev - current)
            let v2 = normalize(next - current)

            let dot = simd_dot(v1, v2)
            let angle = acos(max(-1, min(1, dot)))

            // Check if close to 90°
            if abs(angle - .pi / 2) < snapThreshold {
                // Adjust to make exactly 90°
                // Keep the first edge direction, adjust the second
                let perpendicular = SIMD2<Float>(-v1.y, v1.x)
                let dist = simd_distance(current, next)

                // Choose perpendicular direction closer to original
                let newNext: SIMD2<Float>
                if simd_dot(perpendicular, v2) > 0 {
                    newNext = current + perpendicular * dist
                } else {
                    newNext = current - perpendicular * dist
                }

                result[(i + 1) % result.count] = newNext
            }
        }

        return result
    }

    private func snapNearbyCorners(_ polygon: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var result = polygon

        // Snap corners that are very close to each other
        for i in 0..<result.count {
            for j in (i + 2)..<result.count {
                if j == (i - 1 + result.count) % result.count { continue }  // Skip adjacent

                let dist = simd_distance(result[i], result[j])
                if dist < cornerSnapDistance && dist > 0 {
                    // Snap to midpoint
                    let midpoint = (result[i] + result[j]) / 2
                    result[i] = midpoint
                    result[j] = midpoint
                }
            }
        }

        // Remove duplicate points
        var unique: [SIMD2<Float>] = []
        for point in result {
            if !unique.contains(where: { simd_distance($0, point) < 0.01 }) {
                unique.append(point)
            }
        }

        return unique
    }

    // MARK: - Protrusion Extraction

    private func extractProtrusions(from statistics: ScanStatistics, ceilingHeight: Float) -> [SimplifiedProtrusion] {
        return statistics.detectedProtrusions.map { protrusion in
            let (minBound, maxBound) = protrusion.boundingBox

            // Create rectangular outline for protrusion
            let polygon: [SIMD2<Float>] = [
                SIMD2<Float>(minBound.x, minBound.z),
                SIMD2<Float>(maxBound.x, minBound.z),
                SIMD2<Float>(maxBound.x, maxBound.z),
                SIMD2<Float>(minBound.x, maxBound.z)
            ]

            return SimplifiedProtrusion(
                polygon: polygon,
                topHeight: ceilingHeight,
                bottomHeight: ceilingHeight - protrusion.depth
            )
        }
    }

    // MARK: - Generate Simplified Mesh

    /// Convert simplified room to mesh data for export
    func generateMesh(from room: SimplifiedRoom) -> CapturedMeshData {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[UInt32]] = []

        let floorY = room.floorHeight
        let ceilingY = room.ceilingHeight

        // Generate floor polygon
        let floorStartIndex = UInt32(vertices.count)
        for point in room.floorPolygon {
            vertices.append(SIMD3<Float>(point.x, floorY, point.y))
            normals.append(SIMD3<Float>(0, 1, 0))  // Floor faces up
        }

        // Triangulate floor (fan triangulation for convex polygon)
        for i in 1..<(room.floorPolygon.count - 1) {
            faces.append([floorStartIndex, floorStartIndex + UInt32(i), floorStartIndex + UInt32(i + 1)])
        }

        // Generate ceiling polygon
        let ceilingStartIndex = UInt32(vertices.count)
        for point in room.floorPolygon {
            vertices.append(SIMD3<Float>(point.x, ceilingY, point.y))
            normals.append(SIMD3<Float>(0, -1, 0))  // Ceiling faces down
        }

        // Triangulate ceiling
        for i in 1..<(room.floorPolygon.count - 1) {
            faces.append([ceilingStartIndex, ceilingStartIndex + UInt32(i + 1), ceilingStartIndex + UInt32(i)])
        }

        // Generate walls
        for i in 0..<room.floorPolygon.count {
            let j = (i + 1) % room.floorPolygon.count

            let p1 = room.floorPolygon[i]
            let p2 = room.floorPolygon[j]

            // Wall normal (pointing inward)
            let wallDir = normalize(p2 - p1)
            let wallNormal = SIMD3<Float>(wallDir.y, 0, -wallDir.x)

            let wallStartIndex = UInt32(vertices.count)

            // Four vertices for wall quad
            vertices.append(SIMD3<Float>(p1.x, floorY, p1.y))
            vertices.append(SIMD3<Float>(p2.x, floorY, p2.y))
            vertices.append(SIMD3<Float>(p2.x, ceilingY, p2.y))
            vertices.append(SIMD3<Float>(p1.x, ceilingY, p1.y))

            for _ in 0..<4 {
                normals.append(wallNormal)
            }

            // Two triangles for wall
            faces.append([wallStartIndex, wallStartIndex + 1, wallStartIndex + 2])
            faces.append([wallStartIndex, wallStartIndex + 2, wallStartIndex + 3])
        }

        // Generate protrusions
        for protrusion in room.protrusions {
            let bottomY = protrusion.bottomHeight
            let topY = protrusion.topHeight

            // Bottom face of protrusion
            let protStartIndex = UInt32(vertices.count)
            for point in protrusion.polygon {
                vertices.append(SIMD3<Float>(point.x, bottomY, point.y))
                normals.append(SIMD3<Float>(0, -1, 0))
            }

            for i in 1..<(protrusion.polygon.count - 1) {
                faces.append([protStartIndex, protStartIndex + UInt32(i + 1), protStartIndex + UInt32(i)])
            }

            // Sides of protrusion
            for i in 0..<protrusion.polygon.count {
                let j = (i + 1) % protrusion.polygon.count
                let p1 = protrusion.polygon[i]
                let p2 = protrusion.polygon[j]

                let sideStartIndex = UInt32(vertices.count)

                vertices.append(SIMD3<Float>(p1.x, bottomY, p1.y))
                vertices.append(SIMD3<Float>(p2.x, bottomY, p2.y))
                vertices.append(SIMD3<Float>(p2.x, topY, p2.y))
                vertices.append(SIMD3<Float>(p1.x, topY, p1.y))

                let sideDir = normalize(p2 - p1)
                let sideNormal = SIMD3<Float>(-sideDir.y, 0, sideDir.x)
                for _ in 0..<4 {
                    normals.append(sideNormal)
                }

                faces.append([sideStartIndex, sideStartIndex + 1, sideStartIndex + 2])
                faces.append([sideStartIndex, sideStartIndex + 2, sideStartIndex + 3])
            }
        }

        return CapturedMeshData(
            vertices: vertices,
            normals: normals,
            colors: [],
            faces: faces,
            transform: matrix_identity_float4x4,
            identifier: UUID(),
            surfaceType: .wall,
            faceClassifications: nil
        )
    }

    // MARK: - Helpers

    private func transformPoint(_ point: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let p4 = SIMD4<Float>(point.x, point.y, point.z, 1)
        let transformed = transform * p4
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}

/// Grid point for snapping
private struct GridPoint: Hashable {
    let x: Int
    let z: Int
}
