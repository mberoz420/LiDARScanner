import Foundation
import simd

// MARK: - Data Structures

struct ReconstructedWall: Identifiable {
    let id: UUID
    let start: SIMD2<Float>         // XZ corner position
    let end: SIMD2<Float>           // XZ corner position
    let floorY: Float
    let ceilingY: Float
    let normal: SIMD3<Float>        // Facing direction (inward)
    var openings: [ReconstructedOpening]     // Doors/windows to cut out

    var length: Float {
        simd_length(end - start)
    }

    var height: Float {
        ceilingY - floorY
    }
}

struct ReconstructedOpening: Identifiable {
    let id = UUID()
    let type: ReconstructedOpeningType
    let bottomY: Float              // Bottom of opening
    let topY: Float                 // Top of opening
    let startOffset: Float          // Distance from wall start
    let width: Float                // Opening width

    var endOffset: Float {
        startOffset + width
    }

    var height: Float {
        topY - bottomY
    }
}

enum ReconstructedOpeningType {
    case door
    case window
    case glassDoor
}

// MARK: - Wall Reconstructor

/// Generates clean wall surfaces from detected edges
@MainActor
class WallReconstructor {

    // MARK: - Configuration

    var cornerSnapDistance: Float = 0.15  // 15cm - merge corners closer than this
    var minWallLength: Float = 0.3        // 30cm - minimum wall segment length
    var openingProximity: Float = 0.3     // 30cm - max distance to associate opening with wall
    var defaultCeilingHeight: Float = 3.5 // Default if not detected (increased for tall rooms)
    var wallThickness: Float = 0.05       // 5cm wall thickness for double-sided export
    var doubleSidedWalls: Bool = true     // Generate both sides of walls

    // MARK: - Public Methods

    /// Main entry point - reconstruct walls from scan statistics
    func reconstruct(from statistics: ScanStatistics) -> [ReconstructedWall] {
        // Get room dimensions
        let floorY = statistics.floorHeight ?? 0
        var ceilingY = statistics.ceilingHeight ?? (floorY + defaultCeilingHeight)

        // Ensure minimum room height
        if ceilingY - floorY < 2.0 {
            ceilingY = floorY + defaultCeilingHeight
        }

        print("[WallReconstructor] Room dimensions: floor=\(floorY), ceiling=\(ceilingY), height=\(ceilingY - floorY)")

        // Extract corners - prioritize user-confirmed corners, then detected edges
        let corners = extractCornersWithUserConfirmed(
            userConfirmed: statistics.userConfirmedCorners,
            detectedEdges: statistics.detectedEdges
        )

        guard corners.count >= 3 else {
            print("[WallReconstructor] Insufficient corners: \(corners.count)")
            return []
        }

        print("[WallReconstructor] Corners: \(corners.map { "(\($0.x), \($0.y))" }.joined(separator: ", "))")

        // Generate walls between corners
        let walls = generateWalls(
            corners: corners,
            floorY: floorY,
            ceilingY: ceilingY,
            doors: statistics.detectedDoors,
            windows: statistics.detectedWindows
        )

        print("[WallReconstructor] Generated \(walls.count) walls from \(corners.count) corners")
        return walls
    }

    /// Extract corners, prioritizing user-confirmed corners
    func extractCornersWithUserConfirmed(
        userConfirmed: [SIMD3<Float>],
        detectedEdges: [WallEdge]
    ) -> [SIMD2<Float>] {
        var corners: [SIMD2<Float>] = []

        // First, add all user-confirmed corners (highest priority)
        for corner3D in userConfirmed {
            let corner2D = SIMD2<Float>(corner3D.x, corner3D.z)
            corners.append(corner2D)
            print("[WallReconstructor] User-confirmed corner: (\(corner2D.x), \(corner2D.y))")
        }

        // Then add detected edges that aren't near user-confirmed ones
        let detectedCorners = extractCorners(from: detectedEdges)
        for detected in detectedCorners {
            let isNearConfirmed = corners.contains { confirmed in
                simd_length(confirmed - detected) < cornerSnapDistance * 2  // Wider threshold for user-confirmed
            }
            if !isNearConfirmed {
                corners.append(detected)
            }
        }

        // Snap and order
        corners = snapNearbyCorners(corners)
        corners = orderClockwise(corners)

        print("[WallReconstructor] Total corners: \(corners.count) (\(userConfirmed.count) user-confirmed)")
        return corners
    }

    /// Extract corner positions from detected edges
    func extractCorners(from edges: [WallEdge]) -> [SIMD2<Float>] {
        // Get only vertical corners
        let verticalCorners = edges.filter { $0.edgeType == .verticalCorner }

        guard !verticalCorners.isEmpty else {
            print("[WallReconstructor] No vertical corners found")
            return []
        }

        // Extract XZ positions (2D floor plan)
        var positions = verticalCorners.map { edge -> SIMD2<Float> in
            let mid = (edge.startPoint + edge.endPoint) / 2
            return SIMD2<Float>(mid.x, mid.z)
        }

        // Snap nearby corners together
        positions = snapNearbyCorners(positions)

        // Order clockwise around room center
        positions = orderClockwise(positions)

        print("[WallReconstructor] Extracted \(positions.count) corners from \(verticalCorners.count) edges")
        return positions
    }

    /// Generate mesh from reconstructed walls
    func generateMesh(walls: [ReconstructedWall]) -> CapturedMeshData {
        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []

        for wall in walls {
            let wallMesh = generateWallMesh(wall)
            let offset = UInt32(allVertices.count)

            allVertices.append(contentsOf: wallMesh.vertices)
            allNormals.append(contentsOf: wallMesh.normals)
            allFaces.append(contentsOf: wallMesh.faces.map {
                [$0[0] + offset, $0[1] + offset, $0[2] + offset]
            })
        }

        return CapturedMeshData(
            vertices: allVertices,
            normals: allNormals,
            colors: [],
            faces: allFaces,
            transform: matrix_identity_float4x4,
            identifier: UUID(),
            surfaceType: .wall
        )
    }

    /// Generate floor and ceiling mesh from corners
    func generateFloorCeiling(corners: [SIMD2<Float>], floorY: Float, ceilingY: Float) -> CapturedMeshData {
        guard corners.count >= 3 else {
            return CapturedMeshData(
                vertices: [],
                normals: [],
                colors: [],
                faces: [],
                transform: matrix_identity_float4x4,
                identifier: UUID()
            )
        }

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []

        // Generate floor (fan triangulation from center)
        let floorMesh = generatePolygonMesh(corners: corners, y: floorY, normalY: 1.0)
        allVertices.append(contentsOf: floorMesh.vertices)
        allNormals.append(contentsOf: floorMesh.normals)
        allFaces.append(contentsOf: floorMesh.faces)

        // Generate ceiling (fan triangulation from center, normal facing down)
        let ceilingMesh = generatePolygonMesh(corners: corners, y: ceilingY, normalY: -1.0)
        let offset = UInt32(allVertices.count)
        allVertices.append(contentsOf: ceilingMesh.vertices)
        allNormals.append(contentsOf: ceilingMesh.normals)
        allFaces.append(contentsOf: ceilingMesh.faces.map {
            [$0[0] + offset, $0[1] + offset, $0[2] + offset]
        })

        return CapturedMeshData(
            vertices: allVertices,
            normals: allNormals,
            colors: [],
            faces: allFaces,
            transform: matrix_identity_float4x4,
            identifier: UUID(),
            surfaceType: .floor
        )
    }

    // MARK: - Private Methods

    /// Snap corners that are close together
    private func snapNearbyCorners(_ corners: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var result: [SIMD2<Float>] = []

        for corner in corners {
            // Check if close to existing corner
            var merged = false
            for i in 0..<result.count {
                if simd_length(result[i] - corner) < cornerSnapDistance {
                    // Average the positions
                    result[i] = (result[i] + corner) / 2
                    merged = true
                    break
                }
            }

            if !merged {
                result.append(corner)
            }
        }

        return result
    }

    /// Order corners clockwise around centroid
    private func orderClockwise(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }

        // Find centroid
        let center = points.reduce(.zero, +) / Float(points.count)

        // Sort by angle from center (clockwise = decreasing angle)
        return points.sorted { p1, p2 in
            let angle1 = atan2(p1.y - center.y, p1.x - center.x)
            let angle2 = atan2(p2.y - center.y, p2.x - center.x)
            return angle1 > angle2  // Descending for clockwise
        }
    }

    /// Generate wall segments between corners
    private func generateWalls(
        corners: [SIMD2<Float>],
        floorY: Float,
        ceilingY: Float,
        doors: [DetectedDoor],
        windows: [DetectedWindow]
    ) -> [ReconstructedWall] {
        var walls: [ReconstructedWall] = []

        for i in 0..<corners.count {
            let start = corners[i]
            let end = corners[(i + 1) % corners.count]

            // Skip very short walls
            let wallLength = simd_length(end - start)
            if wallLength < minWallLength { continue }

            // Calculate wall direction and inward-facing normal
            let direction = simd_normalize(end - start)
            // Normal perpendicular to wall, pointing inward (right-hand rule for clockwise)
            let normal = SIMD3<Float>(direction.y, 0, -direction.x)

            // Find openings on this wall
            let openings = findOpeningsOnWall(
                start: start,
                end: end,
                doors: doors,
                windows: windows,
                floorY: floorY
            )

            walls.append(ReconstructedWall(
                id: UUID(),
                start: start,
                end: end,
                floorY: floorY,
                ceilingY: ceilingY,
                normal: normal,
                openings: openings
            ))
        }

        return walls
    }

    /// Find and map openings (doors/windows) to a wall segment
    private func findOpeningsOnWall(
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        doors: [DetectedDoor],
        windows: [DetectedWindow],
        floorY: Float
    ) -> [ReconstructedOpening] {
        var openings: [ReconstructedOpening] = []
        let wallLength = simd_length(end - start)

        // Process doors
        for door in doors {
            let doorPos = SIMD2<Float>(door.position.x, door.position.z)
            let projection = projectOntoSegment(doorPos, start, end)

            if projection.distance < openingProximity {
                let startOffset = max(0, projection.offset - door.width / 2)
                let width = min(door.width, wallLength - startOffset)

                openings.append(ReconstructedOpening(
                    type: .door,
                    bottomY: floorY,
                    topY: floorY + door.height,
                    startOffset: startOffset,
                    width: width
                ))
            }
        }

        // Process windows
        for window in windows {
            let windowPos = SIMD2<Float>(window.position.x, window.position.z)
            let projection = projectOntoSegment(windowPos, start, end)

            if projection.distance < openingProximity {
                let startOffset = max(0, projection.offset - window.width / 2)
                let width = min(window.width, wallLength - startOffset)

                // Calculate window Y positions from heightFromFloor and height
                let windowBottomY = floorY + window.heightFromFloor
                let windowTopY = windowBottomY + window.height

                openings.append(ReconstructedOpening(
                    type: .window,
                    bottomY: windowBottomY,
                    topY: windowTopY,
                    startOffset: startOffset,
                    width: width
                ))
            }
        }

        // Sort by offset and merge overlapping
        let sorted = openings.sorted { $0.startOffset < $1.startOffset }
        return mergeOverlappingOpenings(sorted)
    }

    /// Project a point onto a line segment
    private func projectOntoSegment(
        _ point: SIMD2<Float>,
        _ start: SIMD2<Float>,
        _ end: SIMD2<Float>
    ) -> (offset: Float, distance: Float) {
        let line = end - start
        let lineLength = simd_length(line)

        guard lineLength > 0.001 else {
            return (0, simd_length(point - start))
        }

        let lineDir = line / lineLength
        let toPoint = point - start
        let projection = simd_dot(toPoint, lineDir)

        // Clamp to segment
        let clampedProjection = max(0, min(lineLength, projection))

        // Distance from point to projected position
        let projectedPoint = start + lineDir * clampedProjection
        let distance = simd_length(point - projectedPoint)

        return (clampedProjection, distance)
    }

    /// Merge overlapping openings
    private func mergeOverlappingOpenings(_ openings: [ReconstructedOpening]) -> [ReconstructedOpening] {
        guard openings.count > 1 else { return openings }

        var result: [ReconstructedOpening] = []

        for opening in openings {
            if let lastIndex = result.indices.last,
               result[lastIndex].endOffset >= opening.startOffset - 0.05 {
                // Overlapping - merge
                let merged = ReconstructedOpening(
                    type: result[lastIndex].type,  // Keep first type
                    bottomY: min(result[lastIndex].bottomY, opening.bottomY),
                    topY: max(result[lastIndex].topY, opening.topY),
                    startOffset: result[lastIndex].startOffset,
                    width: opening.endOffset - result[lastIndex].startOffset
                )
                result[lastIndex] = merged
            } else {
                result.append(opening)
            }
        }

        return result
    }

    // MARK: - Mesh Generation

    /// Generate mesh for a single wall with openings
    private func generateWallMesh(_ wall: ReconstructedWall) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [[UInt32]]) {

        if wall.openings.isEmpty {
            // Simple solid wall - just a quad (2 triangles)
            return generateSolidWall(wall)
        } else {
            // Wall with openings - subdivide around them
            return generateWallWithOpenings(wall)
        }
    }

    /// Generate simple solid wall (no openings)
    private func generateSolidWall(_ wall: ReconstructedWall) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [[UInt32]]) {

        // 4 corners of the wall quad - front face
        let v0 = SIMD3<Float>(wall.start.x, wall.floorY, wall.start.y)   // Bottom-left
        let v1 = SIMD3<Float>(wall.end.x, wall.floorY, wall.end.y)       // Bottom-right
        let v2 = SIMD3<Float>(wall.end.x, wall.ceilingY, wall.end.y)     // Top-right
        let v3 = SIMD3<Float>(wall.start.x, wall.ceilingY, wall.start.y) // Top-left

        if doubleSidedWalls {
            // Double-sided: add vertices for back face with reversed normals
            let backNormal = -wall.normal

            let vertices = [
                v0, v1, v2, v3,  // Front face vertices (0-3)
                v0, v1, v2, v3   // Back face vertices (4-7) - same positions, different normals
            ]
            let normals = [
                wall.normal, wall.normal, wall.normal, wall.normal,      // Front normals
                backNormal, backNormal, backNormal, backNormal           // Back normals
            ]

            // Front face: 0-1-2, 0-2-3 (counter-clockwise from front)
            // Back face: 4-6-5, 4-7-6 (clockwise from front = counter-clockwise from back)
            let faces: [[UInt32]] = [
                [0, 1, 2], [0, 2, 3],  // Front
                [4, 6, 5], [4, 7, 6]   // Back (reversed winding)
            ]

            return (vertices, normals, faces)
        } else {
            let vertices = [v0, v1, v2, v3]
            let normals = [wall.normal, wall.normal, wall.normal, wall.normal]
            let faces: [[UInt32]] = [[0, 1, 2], [0, 2, 3]]
            return (vertices, normals, faces)
        }
    }

    /// Generate wall with openings cut out
    private func generateWallWithOpenings(_ wall: ReconstructedWall) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [[UInt32]]) {

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[UInt32]] = []

        let wallDir = simd_normalize(wall.end - wall.start)
        let wallLength = wall.length
        let backNormal = -wall.normal

        // Helper to create 3D point on wall
        func wallPoint(offset: Float, y: Float) -> SIMD3<Float> {
            let pos2D = wall.start + wallDir * offset
            return SIMD3<Float>(pos2D.x, y, pos2D.y)
        }

        // Helper to add a quad (2 triangles) - double-sided if enabled
        func addQuad(bl: SIMD3<Float>, br: SIMD3<Float>, tr: SIMD3<Float>, tl: SIMD3<Float>) {
            let baseIndex = UInt32(vertices.count)

            if doubleSidedWalls {
                // Front and back vertices
                vertices.append(contentsOf: [bl, br, tr, tl, bl, br, tr, tl])
                normals.append(contentsOf: [
                    wall.normal, wall.normal, wall.normal, wall.normal,
                    backNormal, backNormal, backNormal, backNormal
                ])
                // Front faces
                faces.append([baseIndex, baseIndex + 1, baseIndex + 2])
                faces.append([baseIndex, baseIndex + 2, baseIndex + 3])
                // Back faces (reversed winding)
                faces.append([baseIndex + 4, baseIndex + 6, baseIndex + 5])
                faces.append([baseIndex + 4, baseIndex + 7, baseIndex + 6])
            } else {
                vertices.append(contentsOf: [bl, br, tr, tl])
                normals.append(contentsOf: [wall.normal, wall.normal, wall.normal, wall.normal])
                faces.append([baseIndex, baseIndex + 1, baseIndex + 2])
                faces.append([baseIndex, baseIndex + 2, baseIndex + 3])
            }
        }

        // Build wall regions around openings
        var currentOffset: Float = 0

        for opening in wall.openings {
            // Region before opening (full height)
            if opening.startOffset > currentOffset {
                let bl = wallPoint(offset: currentOffset, y: wall.floorY)
                let br = wallPoint(offset: opening.startOffset, y: wall.floorY)
                let tr = wallPoint(offset: opening.startOffset, y: wall.ceilingY)
                let tl = wallPoint(offset: currentOffset, y: wall.ceilingY)
                addQuad(bl: bl, br: br, tr: tr, tl: tl)
            }

            // Region below opening (if any)
            if opening.bottomY > wall.floorY {
                let bl = wallPoint(offset: opening.startOffset, y: wall.floorY)
                let br = wallPoint(offset: opening.endOffset, y: wall.floorY)
                let tr = wallPoint(offset: opening.endOffset, y: opening.bottomY)
                let tl = wallPoint(offset: opening.startOffset, y: opening.bottomY)
                addQuad(bl: bl, br: br, tr: tr, tl: tl)
            }

            // Region above opening (if any)
            if opening.topY < wall.ceilingY {
                let bl = wallPoint(offset: opening.startOffset, y: opening.topY)
                let br = wallPoint(offset: opening.endOffset, y: opening.topY)
                let tr = wallPoint(offset: opening.endOffset, y: wall.ceilingY)
                let tl = wallPoint(offset: opening.startOffset, y: wall.ceilingY)
                addQuad(bl: bl, br: br, tr: tr, tl: tl)
            }

            currentOffset = opening.endOffset
        }

        // Region after last opening
        if currentOffset < wallLength {
            let bl = wallPoint(offset: currentOffset, y: wall.floorY)
            let br = wallPoint(offset: wallLength, y: wall.floorY)
            let tr = wallPoint(offset: wallLength, y: wall.ceilingY)
            let tl = wallPoint(offset: currentOffset, y: wall.ceilingY)
            addQuad(bl: bl, br: br, tr: tr, tl: tl)
        }

        return (vertices, normals, faces)
    }

    /// Generate floor or ceiling mesh from corner polygon
    private func generatePolygonMesh(
        corners: [SIMD2<Float>],
        y: Float,
        normalY: Float
    ) -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [[UInt32]]) {

        guard corners.count >= 3 else {
            return ([], [], [])
        }

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[UInt32]] = []

        let normal = SIMD3<Float>(0, normalY, 0)
        let backNormal = SIMD3<Float>(0, -normalY, 0)

        // Fan triangulation from centroid
        let center = corners.reduce(.zero, +) / Float(corners.count)
        let centerVertex = SIMD3<Float>(center.x, y, center.y)

        // Add center vertex
        vertices.append(centerVertex)
        normals.append(normal)

        // Add corner vertices
        for corner in corners {
            vertices.append(SIMD3<Float>(corner.x, y, corner.y))
            normals.append(normal)
        }

        let vertexCount = vertices.count

        // Create triangles (fan from center) - front side
        for i in 0..<corners.count {
            let next = (i + 1) % corners.count
            if normalY > 0 {
                // Floor - counter-clockwise winding for upward normal
                faces.append([0, UInt32(i + 1), UInt32(next + 1)])
            } else {
                // Ceiling - clockwise winding for downward normal
                faces.append([0, UInt32(next + 1), UInt32(i + 1)])
            }
        }

        // Add back side for double-sided rendering
        if doubleSidedWalls {
            // Duplicate vertices with opposite normals
            vertices.append(centerVertex)
            normals.append(backNormal)

            for corner in corners {
                vertices.append(SIMD3<Float>(corner.x, y, corner.y))
                normals.append(backNormal)
            }

            // Back side triangles (reversed winding)
            let offset = UInt32(vertexCount)
            for i in 0..<corners.count {
                let next = (i + 1) % corners.count
                if normalY > 0 {
                    // Back of floor
                    faces.append([offset, offset + UInt32(next + 1), offset + UInt32(i + 1)])
                } else {
                    // Back of ceiling
                    faces.append([offset, offset + UInt32(i + 1), offset + UInt32(next + 1)])
                }
            }
        }

        return (vertices, normals, faces)
    }
}
