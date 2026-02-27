import Foundation
import ARKit
import CoreMotion
import simd

/// Surface type classification based on normal direction
enum SurfaceType: String, CaseIterable {
    case floor = "Floor"
    case ceiling = "Ceiling"
    case ceilingProtrusion = "Ceiling Protrusion"  // Beams, ducts, fixtures
    case wall = "Wall"
    case wallEdge = "Wall Edge"                     // Corners, intersections
    case floorEdge = "Floor Edge"                   // Where floor meets wall
    case door = "Door"                              // Door opening or frame
    case doorFrame = "Door Frame"                   // Door frame edges
    case window = "Window"                          // Window opening
    case windowFrame = "Window Frame"               // Window frame edges
    case object = "Object"
    case unknown = "Unknown"

    var color: (r: Float, g: Float, b: Float, a: Float) {
        switch self {
        case .floor: return (0.2, 0.8, 0.2, 0.3)              // Green
        case .ceiling: return (0.8, 0.8, 0.2, 0.2)            // Yellow, transparent
        case .ceilingProtrusion: return (1.0, 0.5, 0.0, 0.6)  // Orange, more visible
        case .wall: return (0.2, 0.4, 0.9, 0.4)               // Blue
        case .wallEdge: return (0.0, 1.0, 1.0, 0.7)           // Cyan, highlight
        case .floorEdge: return (0.0, 0.8, 0.5, 0.6)          // Teal
        case .door: return (0.6, 0.3, 0.1, 0.5)               // Brown
        case .doorFrame: return (0.8, 0.5, 0.2, 0.7)          // Light brown
        case .window: return (0.5, 0.8, 1.0, 0.4)             // Light blue/glass
        case .windowFrame: return (0.7, 0.7, 0.7, 0.7)        // Gray
        case .object: return (0.9, 0.3, 0.3, 0.5)             // Red
        case .unknown: return (0.5, 0.5, 0.5, 0.3)            // Gray
        }
    }

    /// Whether this surface type should be highlighted for attention
    var isStructuralFeature: Bool {
        switch self {
        case .ceilingProtrusion, .wallEdge, .floorEdge, .door, .doorFrame, .window, .windowFrame:
            return true
        default:
            return false
        }
    }

    /// Whether this is an opening (door or window)
    var isOpening: Bool {
        switch self {
        case .door, .doorFrame, .window, .windowFrame:
            return true
        default:
            return false
        }
    }
}

/// Device orientation relative to gravity
enum DeviceOrientation: String {
    case lookingUp = "Looking Up (Ceiling)"
    case lookingDown = "Looking Down (Floor)"
    case lookingHorizontal = "Looking Horizontal"
    case lookingSlightlyUp = "Looking Slightly Up"
    case lookingSlightlyDown = "Looking Slightly Down"
}

/// Classified surface data with type and metrics
struct ClassifiedSurface {
    let surfaceType: SurfaceType
    let averageNormal: SIMD3<Float>
    let area: Float
    let vertexCount: Int
    let heightRange: (min: Float, max: Float)
    let boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
    let confidence: Float // 0-1, how confident we are in the classification

    /// Size of the bounding box
    var size: SIMD3<Float> {
        return boundingBox.max - boundingBox.min
    }

    /// Maximum dimension (width, height, or depth)
    var maxDimension: Float {
        return max(size.x, max(size.y, size.z))
    }

    /// Whether this surface should be filtered based on room layout mode
    func shouldFilter(settings: AppSettings, floorHeight: Float?) -> Bool {
        switch settings.roomLayoutMode {
        case .includeAll:
            return false

        case .roomOnly:
            // Only keep structural surfaces
            return surfaceType == .object || surfaceType == .unknown

        case .filterLarge:
            // Filter objects larger than threshold
            if surfaceType == .object {
                return maxDimension > settings.minObjectSizeMeters
            }
            return false

        case .filterByHeight:
            // Filter objects below height threshold (furniture on floor)
            if surfaceType == .object, let floor = floorHeight {
                let objectBottomHeight = heightRange.min - floor
                return objectBottomHeight < settings.maxObjectHeightMeters
            }
            return false

        case .custom:
            // Check individual surface type toggles
            switch surfaceType {
            case .floor, .floorEdge:
                return !settings.includeFloor
            case .ceiling:
                return !settings.includeCeiling
            case .ceilingProtrusion:
                return !settings.includeProtrusions
            case .wall:
                return !settings.includeWalls
            case .wallEdge:
                return !settings.includeEdges
            case .door, .doorFrame:
                return !settings.includeDoors
            case .window, .windowFrame:
                return !settings.includeWindows
            case .object:
                return !settings.includeObjects
            case .unknown:
                return true  // Always filter unknown
            }
        }
    }
}

/// Detected ceiling protrusion (beam, duct, fixture)
struct CeilingProtrusion {
    let id: UUID
    let boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
    let depth: Float              // How far it protrudes below ceiling
    let area: Float
    let type: ProtrusionType

    enum ProtrusionType: String {
        case beam = "Beam"            // Long, narrow
        case duct = "Duct"            // Rectangular, runs along ceiling
        case fixture = "Light Fixture" // Compact, localized
        case dropCeiling = "Dropped Section" // Large area at different height
        case unknown = "Protrusion"
    }
}

/// Detected wall edge (corner or intersection)
struct WallEdge {
    let id: UUID
    let startPoint: SIMD3<Float>
    let endPoint: SIMD3<Float>
    let edgeType: EdgeType
    let angle: Float              // Angle between surfaces in radians

    enum EdgeType: String {
        case verticalCorner = "Corner"           // Wall meets wall
        case floorWall = "Floor-Wall"            // Floor meets wall
        case ceilingWall = "Ceiling-Wall"        // Ceiling meets wall
        case objectEdge = "Object Edge"          // Furniture edge
        case doorFrame = "Door Frame"            // Door frame edge
        case windowFrame = "Window Frame"        // Window frame edge
    }

    var length: Float {
        return simd_distance(startPoint, endPoint)
    }
}

/// Detected door opening
struct DetectedDoor {
    let id: UUID
    let position: SIMD3<Float>           // Center position
    let width: Float                      // Typical: 0.7-1.0m
    let height: Float                     // Typical: 1.9-2.2m
    let wallNormal: SIMD3<Float>          // Direction door faces
    let boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
    let confidence: Float

    var isStandardSize: Bool {
        return width >= 0.6 && width <= 1.2 && height >= 1.8 && height <= 2.5
    }
}

/// Detected window opening
struct DetectedWindow {
    let id: UUID
    let position: SIMD3<Float>           // Center position
    let width: Float                      // Variable
    let height: Float                     // Variable
    let heightFromFloor: Float            // Windows don't reach floor
    let wallNormal: SIMD3<Float>          // Direction window faces
    let boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
    let confidence: Float

    var windowType: WindowType {
        if height > 1.8 && heightFromFloor < 0.2 {
            return .floorToCeiling
        } else if width > height * 2 {
            return .horizontal
        } else if height > width * 2 {
            return .vertical
        } else {
            return .standard
        }
    }

    enum WindowType: String {
        case standard = "Standard"
        case floorToCeiling = "Floor to Ceiling"
        case horizontal = "Horizontal"
        case vertical = "Vertical"
    }
}

/// Candidate for door/window detection (gap in wall)
struct WallGapCandidate {
    let id: UUID
    let boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
    let wallNormal: SIMD3<Float>
    let bottomHeight: Float     // Height of gap bottom from floor
    let width: Float
    let height: Float
    var hitCount: Int = 1       // Number of times this gap was detected

    var center: SIMD3<Float> {
        return (boundingBox.min + boundingBox.max) / 2
    }
}

/// Statistics about the current scan
struct ScanStatistics {
    var floorArea: Float = 0
    var ceilingArea: Float = 0
    var wallArea: Float = 0
    var objectArea: Float = 0
    var protrusionArea: Float = 0

    var floorHeight: Float?
    var ceilingHeight: Float?
    var estimatedRoomHeight: Float? {
        guard let floor = floorHeight, let ceiling = ceilingHeight else { return nil }
        return ceiling - floor
    }

    var detectedProtrusions: [CeilingProtrusion] = []
    var detectedEdges: [WallEdge] = []
    var detectedDoors: [DetectedDoor] = []
    var detectedWindows: [DetectedWindow] = []
    var surfaceCounts: [SurfaceType: Int] = [:]

    var minClearanceHeight: Float? {
        guard let ceiling = ceilingHeight, let floor = floorHeight else { return nil }
        let maxProtrusionDepth = detectedProtrusions.map { $0.depth }.max() ?? 0
        return (ceiling - maxProtrusionDepth) - floor
    }

    var summary: String {
        var parts: [String] = []
        if let height = estimatedRoomHeight {
            parts.append(String(format: "Room: %.1fm", height))
        }
        if let clearance = minClearanceHeight, clearance < (estimatedRoomHeight ?? 0) - 0.1 {
            parts.append(String(format: "Clearance: %.1fm", clearance))
        }
        if !detectedProtrusions.isEmpty {
            parts.append("\(detectedProtrusions.count) protrusions")
        }
        if !detectedDoors.isEmpty {
            parts.append("\(detectedDoors.count) doors")
        }
        if !detectedWindows.isEmpty {
            parts.append("\(detectedWindows.count) windows")
        }
        if floorArea > 0 {
            parts.append(String(format: "%.1fm²", floorArea))
        }
        return parts.joined(separator: " | ")
    }
}

@MainActor
class SurfaceClassifier: ObservableObject {
    // MARK: - Published State
    @Published var deviceOrientation: DeviceOrientation = .lookingHorizontal
    @Published var devicePitch: Float = 0 // Radians, negative = looking down
    @Published var statistics = ScanStatistics()
    @Published var classificationEnabled = true

    // MARK: - Classification Thresholds (from settings)

    /// Normal Y threshold for floor/ceiling classification
    private var horizontalSurfaceThreshold: Float {
        AppSettings.shared.horizontalSurfaceThreshold
    }

    /// Normal Y threshold for wall classification (|Y| must be below this)
    private var wallThreshold: Float {
        AppSettings.shared.wallThreshold
    }

    /// Minimum depth below ceiling to be considered a protrusion (meters)
    private var protrusionMinDepth: Float {
        AppSettings.shared.protrusionMinDepthMeters
    }

    /// Maximum depth for protrusion (beyond this, it's a different ceiling level)
    private var protrusionMaxDepth: Float {
        AppSettings.shared.protrusionMaxDepthMeters
    }

    // MARK: - Fixed Thresholds

    /// Pitch threshold for "looking up" (radians, ~30 degrees)
    private let lookingUpThreshold: Float = 0.52

    /// Pitch threshold for "looking down" (radians)
    private let lookingDownThreshold: Float = -0.52

    /// Height clustering tolerance for floor/ceiling detection (meters)
    private let heightClusterTolerance: Float = 0.15

    /// Angle threshold for edge detection (radians, ~60 degrees)
    private let edgeAngleThreshold: Float = 1.05

    // MARK: - Internal State
    private var floorHeightSamples: [Float] = []
    private var ceilingHeightSamples: [Float] = []
    private var protrusionCandidates: [UUID: (height: Float, area: Float, bounds: (SIMD3<Float>, SIMD3<Float>))] = [:]
    private var edgeCandidates: [(point: SIMD3<Float>, normal1: SIMD3<Float>, normal2: SIMD3<Float>)] = []

    // Door/window detection
    private var wallGapCandidates: [WallGapCandidate] = []

    // Door/window size thresholds
    private let doorMinWidth: Float = 0.6       // 60cm minimum door width
    private let doorMaxWidth: Float = 1.5       // 150cm maximum door width
    private let doorMinHeight: Float = 1.8      // 180cm minimum door height
    private let doorMaxHeight: Float = 2.5      // 250cm maximum door height
    private let doorMaxBottomFromFloor: Float = 0.05  // Door starts near floor

    private let windowMinWidth: Float = 0.3     // 30cm minimum window width
    private let windowMinHeight: Float = 0.3    // 30cm minimum window height
    private let windowMinBottomFromFloor: Float = 0.4  // Window at least 40cm from floor

    // MARK: - Device Orientation

    /// Update device orientation from ARFrame camera transform
    func updateDeviceOrientation(from frame: ARFrame) {
        // Camera looks along -Z in camera space
        // We need to find where -Z points in world space
        let cameraTransform = frame.camera.transform

        // Extract the camera's forward direction (negative Z-axis of camera)
        let forward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        // Pitch is the angle between forward and horizontal plane
        // Positive pitch = looking up, negative = looking down
        devicePitch = asin(forward.y)

        // Classify orientation
        if devicePitch > lookingUpThreshold {
            deviceOrientation = .lookingUp
        } else if devicePitch < lookingDownThreshold {
            deviceOrientation = .lookingDown
        } else if devicePitch > 0.17 { // ~10 degrees
            deviceOrientation = .lookingSlightlyUp
        } else if devicePitch < -0.17 {
            deviceOrientation = .lookingSlightlyDown
        } else {
            deviceOrientation = .lookingHorizontal
        }
    }

    // MARK: - Surface Classification

    /// Classify a single surface based on its average normal
    func classifySurface(averageNormal: SIMD3<Float>, worldY: Float) -> SurfaceType {
        guard classificationEnabled else { return .unknown }

        let normalY = averageNormal.y

        if normalY > horizontalSurfaceThreshold {
            // Surface facing up = floor
            updateFloorHeight(worldY)
            return .floor
        } else if normalY < -horizontalSurfaceThreshold {
            // Surface facing down - could be ceiling or protrusion
            return classifyCeilingSurface(worldY: worldY)
        } else if abs(normalY) < wallThreshold {
            // Mostly vertical surface = wall
            return .wall
        } else {
            // Angled surface = likely an object (furniture, stairs, etc.)
            return .object
        }
    }

    /// Classify downward-facing surface as ceiling or protrusion
    private func classifyCeilingSurface(worldY: Float) -> SurfaceType {
        // If we have a ceiling height estimate, check for protrusions
        if let ceilingHeight = statistics.ceilingHeight {
            let depthBelowCeiling = ceilingHeight - worldY

            if depthBelowCeiling > protrusionMinDepth && depthBelowCeiling < protrusionMaxDepth {
                // This is below the main ceiling but not too far - it's a protrusion
                return .ceilingProtrusion
            } else if depthBelowCeiling >= protrusionMaxDepth {
                // Too far below - might be a dropped ceiling section or different room level
                // Still track as potential new ceiling level
                updateCeilingHeight(worldY)
                return .ceiling
            }
        }

        // Normal ceiling - update height tracking
        updateCeilingHeight(worldY)
        return .ceiling
    }

    /// Detect and classify a ceiling protrusion
    func detectProtrusion(
        meshID: UUID,
        vertices: [SIMD3<Float>],
        transform: simd_float4x4,
        surfaceType: SurfaceType
    ) {
        guard surfaceType == .ceilingProtrusion else { return }
        guard let ceilingHeight = statistics.ceilingHeight else { return }

        // Calculate bounds of this mesh section
        var minBound = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBound = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        for vertex in vertices {
            let worldVertex = transformPoint(vertex, by: transform)
            minBound = min(minBound, worldVertex)
            maxBound = max(maxBound, worldVertex)
        }

        let depth = ceilingHeight - ((minBound.y + maxBound.y) / 2)
        let width = maxBound.x - minBound.x
        let length = maxBound.z - minBound.z
        let area = width * length

        // Classify protrusion type based on shape
        let aspectRatio = max(width, length) / max(min(width, length), 0.01)

        let protrusionType: CeilingProtrusion.ProtrusionType
        if aspectRatio > 5 && area < 2.0 {
            protrusionType = .beam  // Long and narrow
        } else if aspectRatio > 3 && area >= 0.5 {
            protrusionType = .duct  // Rectangular, moderate size
        } else if area < 0.25 {
            protrusionType = .fixture  // Small, compact
        } else if area > 4.0 {
            protrusionType = .dropCeiling  // Large area
        } else {
            protrusionType = .unknown
        }

        // Check if we already have this protrusion
        if let existingIndex = statistics.detectedProtrusions.firstIndex(where: { $0.id == meshID }) {
            statistics.detectedProtrusions[existingIndex] = CeilingProtrusion(
                id: meshID,
                boundingBox: (minBound, maxBound),
                depth: depth,
                area: area,
                type: protrusionType
            )
        } else {
            statistics.detectedProtrusions.append(CeilingProtrusion(
                id: meshID,
                boundingBox: (minBound, maxBound),
                depth: depth,
                area: area,
                type: protrusionType
            ))
        }
    }

    /// Classify mesh triangles and return per-face classification
    func classifyMesh(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        faces: [[UInt32]],
        transform: simd_float4x4
    ) -> [SurfaceType] {
        guard classificationEnabled else {
            return Array(repeating: .unknown, count: faces.count)
        }

        var faceClassifications: [SurfaceType] = []
        var surfaceAreas: [SurfaceType: Float] = [:]
        var faceNormals: [SIMD3<Float>] = []
        var faceCenters: [SIMD3<Float>] = []

        // First pass: classify all faces
        for face in faces {
            guard face.count >= 3,
                  Int(face[0]) < vertices.count,
                  Int(face[1]) < vertices.count,
                  Int(face[2]) < vertices.count else {
                faceClassifications.append(.unknown)
                faceNormals.append(SIMD3<Float>(0, 1, 0))
                faceCenters.append(SIMD3<Float>(0, 0, 0))
                continue
            }

            // Get vertices in local space
            let v0 = vertices[Int(face[0])]
            let v1 = vertices[Int(face[1])]
            let v2 = vertices[Int(face[2])]

            // Transform to world space
            let worldV0 = transformPoint(v0, by: transform)
            let worldV1 = transformPoint(v1, by: transform)
            let worldV2 = transformPoint(v2, by: transform)

            // Compute face normal in world space
            let edge1 = worldV1 - worldV0
            let edge2 = worldV2 - worldV0
            let faceNormal = normalize(cross(edge1, edge2))
            faceNormals.append(faceNormal)

            let center = (worldV0 + worldV1 + worldV2) / 3
            faceCenters.append(center)

            // Classify based on normal
            let avgY = center.y
            let surfaceType = classifySurface(averageNormal: faceNormal, worldY: avgY)
            faceClassifications.append(surfaceType)

            // Calculate triangle area for statistics
            let area = length(cross(edge1, edge2)) / 2
            surfaceAreas[surfaceType, default: 0] += area
        }

        // Second pass: detect edges by finding adjacent faces with different classifications
        detectEdges(
            faces: faces,
            vertices: vertices,
            transform: transform,
            faceClassifications: faceClassifications,
            faceNormals: faceNormals,
            faceCenters: faceCenters
        )

        // Update statistics
        statistics.floorArea = surfaceAreas[.floor, default: 0]
        statistics.ceilingArea = surfaceAreas[.ceiling, default: 0]
        statistics.wallArea = surfaceAreas[.wall, default: 0]
        statistics.objectArea = surfaceAreas[.object, default: 0]
        statistics.protrusionArea = surfaceAreas[.ceilingProtrusion, default: 0]

        return faceClassifications
    }

    /// Detect edges where different surface types meet
    private func detectEdges(
        faces: [[UInt32]],
        vertices: [SIMD3<Float>],
        transform: simd_float4x4,
        faceClassifications: [SurfaceType],
        faceNormals: [SIMD3<Float>],
        faceCenters: [SIMD3<Float>]
    ) {
        // Build edge-to-face mapping
        var edgeToFaces: [String: [Int]] = [:]

        for (faceIndex, face) in faces.enumerated() {
            guard face.count >= 3 else { continue }

            // Create edge keys (sorted vertex indices)
            let edges = [
                edgeKey(face[0], face[1]),
                edgeKey(face[1], face[2]),
                edgeKey(face[2], face[0])
            ]

            for edge in edges {
                edgeToFaces[edge, default: []].append(faceIndex)
            }
        }

        // Find edges where surface types differ or normals change sharply
        var detectedEdgePoints: [(start: SIMD3<Float>, end: SIMD3<Float>, type: WallEdge.EdgeType, angle: Float)] = []

        for (edgeKey, faceIndices) in edgeToFaces {
            guard faceIndices.count == 2 else { continue }  // Only internal edges

            let face1 = faceIndices[0]
            let face2 = faceIndices[1]

            guard face1 < faceClassifications.count,
                  face2 < faceClassifications.count,
                  face1 < faceNormals.count,
                  face2 < faceNormals.count else { continue }

            let type1 = faceClassifications[face1]
            let type2 = faceClassifications[face2]
            let normal1 = faceNormals[face1]
            let normal2 = faceNormals[face2]

            // Calculate angle between normals
            let dotProduct = simd_dot(normal1, normal2)
            let angle = acos(min(max(dotProduct, -1), 1))

            // Check for significant edge
            let isTypeChange = type1 != type2
            let isSharpAngle = angle > edgeAngleThreshold

            if isTypeChange || isSharpAngle {
                // Extract edge vertices
                let vertexIndices = edgeKey.split(separator: "-").compactMap { UInt32($0) }
                guard vertexIndices.count == 2,
                      Int(vertexIndices[0]) < vertices.count,
                      Int(vertexIndices[1]) < vertices.count else { continue }

                let start = transformPoint(vertices[Int(vertexIndices[0])], by: transform)
                let end = transformPoint(vertices[Int(vertexIndices[1])], by: transform)

                // Determine edge type
                let edgeType = determineEdgeType(type1: type1, type2: type2, angle: angle)

                detectedEdgePoints.append((start, end, edgeType, angle))
            }
        }

        // Merge nearby edge segments into continuous edges
        mergeEdgeSegments(detectedEdgePoints)
    }

    /// Create a consistent key for an edge
    private func edgeKey(_ v1: UInt32, _ v2: UInt32) -> String {
        let minV = min(v1, v2)
        let maxV = max(v1, v2)
        return "\(minV)-\(maxV)"
    }

    /// Determine edge type based on adjacent surface types
    private func determineEdgeType(type1: SurfaceType, type2: SurfaceType, angle: Float) -> WallEdge.EdgeType {
        let types = Set([type1, type2])

        if types.contains(.floor) && types.contains(.wall) {
            return .floorWall
        } else if types.contains(.ceiling) && types.contains(.wall) {
            return .ceilingWall
        } else if types == Set([.wall]) && angle > edgeAngleThreshold {
            return .verticalCorner
        } else if types.contains(.object) {
            return .objectEdge
        } else {
            return .verticalCorner
        }
    }

    /// Merge nearby edge segments into longer edges
    private func mergeEdgeSegments(_ segments: [(start: SIMD3<Float>, end: SIMD3<Float>, type: WallEdge.EdgeType, angle: Float)]) {
        // Simple approach: keep significant edges, limit total count
        let significantEdges = segments.filter { segment in
            let length = simd_distance(segment.start, segment.end)
            return length > 0.1  // At least 10cm
        }

        // Sort by angle (sharpest first) and take top edges
        let sortedEdges = significantEdges.sorted { $0.angle > $1.angle }
        let topEdges = Array(sortedEdges.prefix(50))  // Keep top 50 edges

        statistics.detectedEdges = topEdges.map { segment in
            WallEdge(
                id: UUID(),
                startPoint: segment.start,
                endPoint: segment.end,
                edgeType: segment.type,
                angle: segment.angle
            )
        }
    }

    /// Classify entire mesh anchor and return dominant surface type
    func classifyMeshAnchor(_ anchor: ARMeshAnchor) -> ClassifiedSurface {
        let geometry = anchor.geometry
        let transform = anchor.transform

        var normalSum = SIMD3<Float>(0, 0, 0)
        var minBound = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBound = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)
        var totalArea: Float = 0

        // Sample faces to compute average normal and bounds
        let sampleStride = max(1, geometry.faces.count / 100) // Sample up to 100 faces

        for i in stride(from: 0, to: geometry.faces.count, by: sampleStride) {
            let faceIndices = geometry.faceIndices(at: i)
            guard faceIndices.count >= 3 else { continue }

            let v0 = transformPoint(geometry.vertex(at: Int(faceIndices[0])), by: transform)
            let v1 = transformPoint(geometry.vertex(at: Int(faceIndices[1])), by: transform)
            let v2 = transformPoint(geometry.vertex(at: Int(faceIndices[2])), by: transform)

            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let normal = cross(edge1, edge2)
            let area = length(normal) / 2

            normalSum += normalize(normal) * area
            totalArea += area

            // Update bounding box
            minBound = min(minBound, min(v0, min(v1, v2)))
            maxBound = max(maxBound, max(v0, max(v1, v2)))
        }

        let averageNormal = totalArea > 0 ? normalize(normalSum) : SIMD3<Float>(0, 1, 0)
        let avgY = (minBound.y + maxBound.y) / 2
        let surfaceType = classifySurface(averageNormal: averageNormal, worldY: avgY)

        // Calculate confidence based on how consistent the normal is
        let confidence = min(1.0, length(normalSum) / (totalArea + 0.001))

        return ClassifiedSurface(
            surfaceType: surfaceType,
            averageNormal: averageNormal,
            area: totalArea,
            vertexCount: geometry.vertices.count,
            heightRange: (minBound.y, maxBound.y),
            boundingBox: (minBound, maxBound),
            confidence: confidence
        )
    }

    /// Check if a classified surface should be filtered out
    func shouldFilterSurface(_ surface: ClassifiedSurface) -> Bool {
        return surface.shouldFilter(
            settings: AppSettings.shared,
            floorHeight: statistics.floorHeight
        )
    }

    // MARK: - Height Estimation

    private func updateFloorHeight(_ y: Float) {
        floorHeightSamples.append(y)

        // Keep last 100 samples
        if floorHeightSamples.count > 100 {
            floorHeightSamples.removeFirst()
        }

        // Estimate floor as the most common low height
        if floorHeightSamples.count >= 10 {
            let sorted = floorHeightSamples.sorted()
            // Take 25th percentile as floor estimate
            let index = floorHeightSamples.count / 4
            statistics.floorHeight = sorted[index]
        }
    }

    private func updateCeilingHeight(_ y: Float) {
        ceilingHeightSamples.append(y)

        if ceilingHeightSamples.count > 100 {
            ceilingHeightSamples.removeFirst()
        }

        if ceilingHeightSamples.count >= 10 {
            let sorted = ceilingHeightSamples.sorted()
            // Take 75th percentile as ceiling estimate
            let index = (ceilingHeightSamples.count * 3) / 4
            statistics.ceilingHeight = sorted[index]
        }
    }

    // MARK: - Optimization Hints

    /// Returns true if we should skip detailed processing for this surface type
    func shouldReduceDetail(for surfaceType: SurfaceType) -> Bool {
        switch surfaceType {
        case .ceiling, .ceilingProtrusion:
            return true // Ceilings are usually flat, less detail needed
        case .floor, .floorEdge:
            return false // Floors may have furniture, keep detail
        case .wall, .wallEdge:
            return false // Walls have features
        case .door, .doorFrame, .window, .windowFrame:
            return false // Openings need detail
        case .object:
            return false // Objects need detail
        case .unknown:
            return false
        }
    }

    /// Suggested update interval multiplier for surface type
    func updateIntervalMultiplier(for surfaceType: SurfaceType) -> Double {
        switch surfaceType {
        case .ceiling, .ceilingProtrusion: return 3.0  // Update ceiling 3x less frequently
        case .floor, .floorEdge: return 1.5            // Floor slightly less
        case .wall, .wallEdge: return 1.0              // Walls normal rate
        case .door, .doorFrame, .window, .windowFrame: return 0.8  // Openings slightly more
        case .object: return 0.5                       // Objects more frequently
        case .unknown: return 1.0
        }
    }

    // MARK: - Door/Window Detection

    /// Analyze wall mesh for potential door/window openings
    func detectOpenings(
        in wallMesh: CapturedMeshData,
        wallNormal: SIMD3<Float>
    ) {
        guard let floorHeight = statistics.floorHeight else { return }

        // Find gaps in the wall mesh by analyzing vertex distribution
        let worldVertices = wallMesh.vertices.map { vertex in
            transformPoint(vertex, by: wallMesh.transform)
        }

        guard !worldVertices.isEmpty else { return }

        // Get wall bounding box
        var wallMin = worldVertices[0]
        var wallMax = worldVertices[0]
        for v in worldVertices {
            wallMin = min(wallMin, v)
            wallMax = max(wallMax, v)
        }

        // Determine wall orientation (which axis is the wall's width)
        let wallSize = wallMax - wallMin
        let isXAligned = abs(wallNormal.x) > abs(wallNormal.z)

        // Divide wall into grid cells and find empty regions (gaps)
        let gridResolution: Float = 0.1  // 10cm cells
        let widthAxis = isXAligned ? wallSize.z : wallSize.x
        let heightAxis = wallSize.y

        let gridWidth = Int(widthAxis / gridResolution) + 1
        let gridHeight = Int(heightAxis / gridResolution) + 1

        guard gridWidth > 0 && gridHeight > 0 && gridWidth < 200 && gridHeight < 200 else { return }

        // Create occupancy grid
        var grid = Array(repeating: Array(repeating: false, count: gridHeight), count: gridWidth)

        for vertex in worldVertices {
            let w = isXAligned ? (vertex.z - wallMin.z) : (vertex.x - wallMin.x)
            let h = vertex.y - wallMin.y

            let gridX = Int(w / gridResolution)
            let gridY = Int(h / gridResolution)

            if gridX >= 0 && gridX < gridWidth && gridY >= 0 && gridY < gridHeight {
                grid[gridX][gridY] = true
            }
        }

        // Find rectangular empty regions (potential openings)
        let gaps = findEmptyRectangles(in: grid, gridResolution: gridResolution)

        for gap in gaps {
            let gapWidth = Float(gap.width) * gridResolution
            let gapHeight = Float(gap.height) * gridResolution
            let gapBottom = wallMin.y + Float(gap.minY) * gridResolution
            let gapBottomFromFloor = gapBottom - floorHeight

            // Calculate world position of gap
            let gapCenterW = Float(gap.minX + gap.width / 2) * gridResolution
            let gapCenterH = gapBottom + gapHeight / 2

            var gapCenter: SIMD3<Float>
            if isXAligned {
                gapCenter = SIMD3<Float>(
                    (wallMin.x + wallMax.x) / 2,
                    gapCenterH,
                    wallMin.z + gapCenterW
                )
            } else {
                gapCenter = SIMD3<Float>(
                    wallMin.x + gapCenterW,
                    gapCenterH,
                    (wallMin.z + wallMax.z) / 2
                )
            }

            // Classify as door or window
            let isDoor = gapBottomFromFloor < doorMaxBottomFromFloor &&
                         gapWidth >= doorMinWidth && gapWidth <= doorMaxWidth &&
                         gapHeight >= doorMinHeight && gapHeight <= doorMaxHeight

            let isWindow = !isDoor &&
                           gapBottomFromFloor >= windowMinBottomFromFloor &&
                           gapWidth >= windowMinWidth &&
                           gapHeight >= windowMinHeight

            if isDoor {
                let door = DetectedDoor(
                    id: UUID(),
                    position: gapCenter,
                    width: gapWidth,
                    height: gapHeight,
                    wallNormal: wallNormal,
                    boundingBox: (
                        SIMD3<Float>(gapCenter.x - gapWidth/2, gapBottom, gapCenter.z - 0.1),
                        SIMD3<Float>(gapCenter.x + gapWidth/2, gapBottom + gapHeight, gapCenter.z + 0.1)
                    ),
                    confidence: min(1.0, Float(gap.width * gap.height) / 100.0)
                )

                // Check if we already detected a similar door
                if !statistics.detectedDoors.contains(where: { simd_distance($0.position, door.position) < 0.5 }) {
                    statistics.detectedDoors.append(door)
                }
            } else if isWindow {
                let window = DetectedWindow(
                    id: UUID(),
                    position: gapCenter,
                    width: gapWidth,
                    height: gapHeight,
                    heightFromFloor: gapBottomFromFloor,
                    wallNormal: wallNormal,
                    boundingBox: (
                        SIMD3<Float>(gapCenter.x - gapWidth/2, gapBottom, gapCenter.z - 0.1),
                        SIMD3<Float>(gapCenter.x + gapWidth/2, gapBottom + gapHeight, gapCenter.z + 0.1)
                    ),
                    confidence: min(1.0, Float(gap.width * gap.height) / 50.0)
                )

                // Check if we already detected a similar window
                if !statistics.detectedWindows.contains(where: { simd_distance($0.position, window.position) < 0.5 }) {
                    statistics.detectedWindows.append(window)
                }
            }
        }
    }

    /// Find empty rectangular regions in occupancy grid
    private func findEmptyRectangles(in grid: [[Bool]], gridResolution: Float) -> [(minX: Int, minY: Int, width: Int, height: Int)] {
        let width = grid.count
        guard width > 0 else { return [] }
        let height = grid[0].count

        var rectangles: [(minX: Int, minY: Int, width: Int, height: Int)] = []

        // Simple approach: find connected empty regions
        var visited = Array(repeating: Array(repeating: false, count: height), count: width)

        for x in 0..<width {
            for y in 0..<height {
                if !grid[x][y] && !visited[x][y] {
                    // Found an empty cell, expand to find rectangle
                    var maxX = x
                    var maxY = y

                    // Expand right
                    while maxX + 1 < width && !grid[maxX + 1][y] && !visited[maxX + 1][y] {
                        maxX += 1
                    }

                    // Expand down
                    var canExpandDown = true
                    while canExpandDown && maxY + 1 < height {
                        for checkX in x...maxX {
                            if grid[checkX][maxY + 1] || visited[checkX][maxY + 1] {
                                canExpandDown = false
                                break
                            }
                        }
                        if canExpandDown {
                            maxY += 1
                        }
                    }

                    // Mark as visited
                    for vx in x...maxX {
                        for vy in y...maxY {
                            visited[vx][vy] = true
                        }
                    }

                    let rectWidth = maxX - x + 1
                    let rectHeight = maxY - y + 1

                    // Only keep significant rectangles (potential doors/windows)
                    let minCells = Int(0.3 / gridResolution)  // At least 30cm
                    if rectWidth >= minCells && rectHeight >= minCells {
                        rectangles.append((x, y, rectWidth, rectHeight))
                    }
                }
            }
        }

        return rectangles
    }

    // MARK: - Reset

    func reset() {
        floorHeightSamples.removeAll()
        ceilingHeightSamples.removeAll()
        protrusionCandidates.removeAll()
        edgeCandidates.removeAll()
        wallGapCandidates.removeAll()
        statistics = ScanStatistics()
    }

    // MARK: - Query Methods

    /// Get all wall corners (vertical edges where walls meet)
    func getWallCorners() -> [WallEdge] {
        return statistics.detectedEdges.filter { $0.edgeType == .verticalCorner }
    }

    /// Get floor perimeter (edges where floor meets walls)
    func getFloorPerimeter() -> [WallEdge] {
        return statistics.detectedEdges.filter { $0.edgeType == .floorWall }
    }

    /// Get ceiling perimeter (edges where ceiling meets walls)
    func getCeilingPerimeter() -> [WallEdge] {
        return statistics.detectedEdges.filter { $0.edgeType == .ceilingWall }
    }

    /// Get all beams and ducts
    func getBeamsAndDucts() -> [CeilingProtrusion] {
        return statistics.detectedProtrusions.filter {
            $0.type == .beam || $0.type == .duct
        }
    }

    /// Get minimum clearance at a specific point
    func getClearanceAt(x: Float, z: Float) -> Float? {
        guard let floor = statistics.floorHeight,
              let ceiling = statistics.ceilingHeight else { return nil }

        // Check if any protrusion is above this point
        var lowestProtrusion = ceiling
        for protrusion in statistics.detectedProtrusions {
            let (minBound, maxBound) = protrusion.boundingBox
            if x >= minBound.x && x <= maxBound.x &&
               z >= minBound.z && z <= maxBound.z {
                lowestProtrusion = min(lowestProtrusion, minBound.y)
            }
        }

        return lowestProtrusion - floor
    }

    // MARK: - Helpers

    private func transformPoint(_ point: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let p4 = SIMD4<Float>(point.x, point.y, point.z, 1)
        let transformed = transform * p4
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}
