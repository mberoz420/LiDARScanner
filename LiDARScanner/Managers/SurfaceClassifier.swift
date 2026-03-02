import Foundation
import ARKit
import CoreMotion
import CoreML
import simd

// Note: debugLog is defined in MeshManager.swift

/// Surface type classification based on normal direction
enum SurfaceType: String, CaseIterable, Sendable {
    case floor = "Floor"
    case ceiling = "Ceiling"
    case cove = "Cove"                             // Rounded ceiling-wall transition
    case ceilingProtrusion = "Ceiling Protrusion"  // Beams, ducts, fixtures
    case wall = "Wall"
    case wallEdge = "Wall Edge"                     // Corners, intersections
    case floorEdge = "Floor Edge"                   // Where floor meets wall
    case door = "Door"                              // Door opening or frame
    case doorFrame = "Door Frame"                   // Door frame edges
    case window = "Window"                          // Window opening
    case windowFrame = "Window Frame"               // Window frame edges
    case object = "Object"
    case objectTop = "Object Top"                   // Top of object (upward normal but above floor)
    case backReflection = "Back Reflection"         // LiDAR reflection artifact - not real surface
    case unknown = "Unknown"

    var color: (r: Float, g: Float, b: Float, a: Float) {
        switch self {
        case .floor: return (0.2, 0.8, 0.2, 0.3)              // Green
        case .ceiling: return (0.8, 0.8, 0.2, 0.2)            // Yellow, transparent
        case .cove: return (0.9, 0.7, 0.9, 0.5)               // Light purple/lavender
        case .ceilingProtrusion: return (1.0, 0.5, 0.0, 0.6)  // Orange, more visible
        case .wall: return (0.2, 0.4, 0.9, 0.4)               // Blue
        case .wallEdge: return (0.0, 1.0, 1.0, 0.7)           // Cyan, highlight
        case .floorEdge: return (0.0, 0.8, 0.5, 0.6)          // Teal
        case .door: return (0.6, 0.3, 0.1, 0.5)               // Brown
        case .doorFrame: return (0.8, 0.5, 0.2, 0.7)          // Light brown
        case .window: return (0.5, 0.8, 1.0, 0.4)             // Light blue/glass
        case .windowFrame: return (0.7, 0.7, 0.7, 0.7)        // Gray
        case .object: return (0.9, 0.3, 0.3, 0.5)             // Red
        case .objectTop: return (0.9, 0.5, 0.5, 0.4)          // Light red - object tops
        case .backReflection: return (1.0, 0.0, 1.0, 0.3)     // Magenta, transparent - artifacts
        case .unknown: return (0.5, 0.5, 0.5, 0.3)            // Gray
        }
    }

    /// Whether this surface type should be highlighted for attention
    var isStructuralFeature: Bool {
        switch self {
        case .cove, .ceilingProtrusion, .wallEdge, .floorEdge, .door, .doorFrame, .window, .windowFrame:
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
        // Always filter back reflections (LiDAR artifacts)
        if surfaceType == .backReflection {
            return true
        }

        switch settings.roomLayoutMode {
        case .includeAll:
            return surfaceType == .backReflection  // Still filter artifacts

        case .roomOnly:
            // Only keep structural surfaces
            return surfaceType == .object || surfaceType == .objectTop || surfaceType == .unknown

        case .filterLarge:
            // Filter objects larger than threshold
            if surfaceType == .object || surfaceType == .objectTop {
                return maxDimension > settings.minObjectSizeMeters
            }
            return false

        case .filterByHeight:
            // Filter objects below height threshold (furniture on floor)
            if surfaceType == .object || surfaceType == .objectTop, let floor = floorHeight {
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
            case .cove:
                return !settings.includeCoves
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
            case .object, .objectTop:
                return !settings.includeObjects
            case .backReflection:
                return true  // Always filter back reflections
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

/// Detection source for doors/windows
enum OpeningDetectionSource: String {
    case automatic = "Auto"           // Detected by gap/anomaly analysis
    case calibrated = "Calibrated"    // User pointed at it for 3s
    case voiceCommand = "Voice"       // User said "door" or "window"
}

/// Detected door opening
struct DetectedDoor {
    let id: UUID
    let position: SIMD3<Float>           // Center position
    var width: Float                      // Typical: 0.7-1.0m
    var height: Float                     // Typical: 1.9-2.2m
    let wallNormal: SIMD3<Float>          // Direction door faces
    var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
    var confidence: Float
    var source: OpeningDetectionSource = .automatic
    var isConfirmed: Bool = false         // User has confirmed this detection

    var isStandardSize: Bool {
        return width >= 0.6 && width <= 1.2 && height >= 1.8 && height <= 2.5
    }
}

/// Detected window opening
struct DetectedWindow {
    let id: UUID
    let position: SIMD3<Float>           // Center position
    var width: Float                      // Variable
    var height: Float                     // Variable
    let heightFromFloor: Float            // Windows don't reach floor
    let wallNormal: SIMD3<Float>          // Direction window faces
    var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
    var confidence: Float
    var source: OpeningDetectionSource = .automatic
    var isConfirmed: Bool = false         // User has confirmed this detection
    var hasGlass: Bool = true             // Detected glass (noisy LiDAR readings)

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

/// Opening candidate detected by distance anomaly
struct OpeningCandidate {
    let id: UUID
    let position: SIMD3<Float>           // Estimated center
    let wallAngle: Float                  // Horizontal angle where detected
    let wallDistance: Float               // Expected wall distance
    let openingDistance: Float            // Actual distance (much farther = opening)
    let bottomHeight: Float               // Height from floor
    let detectionType: DetectionType
    var detectionCount: Int = 1           // Times detected (higher = more confident)

    enum DetectionType: String {
        case distanceJump = "Distance Jump"       // Sudden far distance = open doorway
        case meshGap = "Mesh Gap"                 // Hole in wall mesh
        case noisePattern = "Noise Pattern"       // Inconsistent readings = glass
    }

    /// Likely classification based on height
    var likelyType: SurfaceType {
        if bottomHeight < 0.1 {
            return .door
        } else if bottomHeight > 0.3 {
            return .window
        } else {
            return .door  // Ambiguous, default to door
        }
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
    var coveArea: Float = 0        // Rounded ceiling-wall transitions
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
    var openingCandidates: [OpeningCandidate] = []  // Auto-detected, awaiting confirmation
    var surfaceCounts: [SurfaceType: Int] = [:]

    /// User-confirmed corners (high confidence - user paused over these)
    var userConfirmedCorners: [SIMD3<Float>] = []

    // MARK: - Detected Planes (for guided scanning)

    /// Detected floor plane (infinite plane at floor height)
    var floorPlane: (height: Float, normal: SIMD3<Float>)? {
        guard let h = floorHeight else { return nil }
        return (h, SIMD3<Float>(0, 1, 0))  // Floor faces up
    }

    /// Detected ceiling plane (infinite plane at ceiling height)
    var ceilingPlane: (height: Float, normal: SIMD3<Float>)? {
        guard let h = ceilingHeight else { return nil }
        return (h, SIMD3<Float>(0, -1, 0))  // Ceiling faces down
    }

    // MARK: - Phase Confidence Metrics (for guided scanning)

    /// Confidence that floor plane has been detected (0-1)
    /// Once ANY floor is detected, confidence is high (plane is extrapolated)
    var floorConfidence: Float {
        guard floorHeight != nil else { return 0 }
        // Even small floor detection = high confidence (we extrapolate the plane)
        let areaConfidence = min(floorArea / 0.5, 1.0)  // 0.5m² = full confidence
        return areaConfidence
    }

    /// Confidence that ceiling has been detected (0-1)
    /// Once ANY ceiling is detected, confidence is high (plane is extrapolated)
    var ceilingConfidence: Float {
        guard ceilingHeight != nil else { return 0 }
        // Even small ceiling detection = high confidence (we extrapolate the plane)
        let areaConfidence = min(ceilingArea / 0.3, 1.0)  // 0.3m² = full confidence
        let heightConfidence: Float = estimatedRoomHeight != nil ? 1.0 : 0.5
        return (areaConfidence + heightConfidence) / 2
    }

    /// Estimated wall coverage percentage (0-1)
    var wallCoveragePercent: Float {
        // Based on detected corners - 4 corners = good rectangular room coverage
        let cornerCount = detectedEdges.filter { $0.edgeType == .verticalCorner }.count
        let cornerScore = min(Float(cornerCount) / 4.0, 1.0)

        // Also consider wall area
        let areaScore = min(wallArea / 10.0, 1.0)  // 10m² wall area = good

        return (cornerScore * 0.6 + areaScore * 0.4)
    }

    /// Number of vertical corners detected
    var cornerCount: Int {
        detectedEdges.filter { $0.edgeType == .verticalCorner }.count
    }

    /// Room dimensions if fully captured
    var roomDimensions: (width: Float, depth: Float, height: Float)? {
        guard let height = estimatedRoomHeight,
              floorHeight != nil else { return nil }

        // Calculate from floor edges
        let floorEdges = detectedEdges.filter { $0.edgeType == .floorWall }
        guard floorEdges.count >= 4 else { return nil }

        // Get bounds from floor edge points
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude

        for edge in floorEdges {
            minX = min(minX, edge.startPoint.x, edge.endPoint.x)
            maxX = max(maxX, edge.startPoint.x, edge.endPoint.x)
            minZ = min(minZ, edge.startPoint.z, edge.endPoint.z)
            maxZ = max(maxZ, edge.startPoint.z, edge.endPoint.z)
        }

        let width = maxX - minX
        let depth = maxZ - minZ

        guard width > 0.5, depth > 0.5 else { return nil }

        return (width, depth, height)
    }

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
    @Published var mlModelLoaded = false
    @Published var mlClassificationEnabled = false  // Use ML when available

    // MARK: - Scan Phase (for distance-based classification)
    @Published var currentScanPhase: RoomScanPhase = .ready

    // Distance tracking per phase - farthest points are the actual surfaces
    private var maxFloorDistance: Float = 0      // Farthest downward point during floor phase
    private var maxCeilingDistance: Float = 0    // Farthest upward point during ceiling phase
    private var maxWallDistance: Float = 0       // Farthest horizontal point during wall phase
    private let distanceTolerance: Float = 0.3   // 30cm tolerance for "farthest" classification

    // MARK: - Calibrated Reference Planes (user-confirmed by pointing)
    @Published var floorCalibrated = false
    @Published var ceilingCalibrated = false

    /// Calibrated floor plane - user pointed at floor for 3+ seconds
    private var calibratedFloorHeight: Float?
    private var calibratedFloorNormal: SIMD3<Float>?

    /// Calibrated ceiling plane - user pointed at ceiling for 3+ seconds
    private var calibratedCeilingHeight: Float?
    private var calibratedCeilingNormal: SIMD3<Float>?

    /// Tolerance for matching calibrated planes (meters)
    private let calibrationTolerance: Float = 0.15  // 15cm tolerance

    // MARK: - Public Room Bounds Access

    /// Get the effective floor height (calibrated or estimated)
    var effectiveFloorHeight: Float? {
        calibratedFloorHeight ?? statistics.floorHeight
    }

    /// Get the effective ceiling height (calibrated or estimated)
    var effectiveCeilingHeight: Float? {
        calibratedCeilingHeight ?? statistics.ceilingHeight
    }

    // MARK: - Core ML Model
    private var segmentationModel: MLModel?
    private var lastMLInferenceTime: Date = .distantPast
    private let mlInferenceInterval: TimeInterval = 0.5  // Run ML every 0.5s max

    // Accumulated points for ML batch processing
    private var accumulatedPoints: [SIMD3<Float>] = []
    private var accumulatedNormals: [SIMD3<Float>] = []
    private var mlClassifications: [SIMD3<Float>: SurfaceType] = [:]  // Cache ML results
    private let maxAccumulatedPoints = 8192  // Limit for memory

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

    /// Angle threshold for edge detection (radians, ~45 degrees - lower = more edges detected)
    private let edgeAngleThreshold: Float = 0.78

    // MARK: - Internal State
    private var floorHeightSamples: [Float] = []
    private var ceilingHeightSamples: [Float] = []
    private var protrusionCandidates: [UUID: (height: Float, area: Float, bounds: (SIMD3<Float>, SIMD3<Float>))] = [:]
    private var edgeCandidates: [(point: SIMD3<Float>, normal1: SIMD3<Float>, normal2: SIMD3<Float>)] = []

    // Door/window detection
    private var wallGapCandidates: [WallGapCandidate] = []

    // Door/window size thresholds
    private let doorMinWidth: Float = 0.5       // 50cm minimum door width
    private let doorMaxWidth: Float = 1.8       // 180cm maximum door width (double doors)
    private let doorMinHeight: Float = 1.7      // 170cm minimum door height
    private let doorMaxHeight: Float = 2.8      // 280cm maximum door height
    private let doorMaxBottomFromFloor: Float = 0.4   // Door starts within 40cm of floor (tolerance for floor detection errors)

    private let windowMinWidth: Float = 0.25    // 25cm minimum window width
    private let windowMinHeight: Float = 0.25   // 25cm minimum window height
    private let windowMinBottomFromFloor: Float = 0.3  // Window at least 30cm from floor

    // MARK: - Wall Detection (farthest surface when pointing horizontally = wall)

    /// Tracks farthest distance per horizontal angle bucket (in degrees)
    /// When looking horizontally, the farthest surface = wall, closer = object
    private var wallDistanceByAngle: [Int: Float] = [:]  // angle bucket (degrees) -> farthest distance

    /// Camera position when wall distances were measured
    private var wallMeasurementOrigin: SIMD3<Float>?

    /// Tolerance for wall distance matching (surfaces within this of farthest = wall)
    private let wallDistanceTolerance: Float = 0.3  // 30cm tolerance

    // MARK: - Back Reflection Detection

    /// Camera positions during scan (for line-of-sight validation)
    private var cameraPositions: [SIMD3<Float>] = []
    private let maxCameraPositions: Int = 100

    /// Track camera position for back reflection detection
    func trackCameraPosition(_ position: SIMD3<Float>) {
        cameraPositions.append(position)
        if cameraPositions.count > maxCameraPositions {
            cameraPositions.removeFirst()
        }
    }

    /// Check if a point is likely a back reflection (LiDAR artifact)
    /// Back reflections occur when LiDAR bounces off reflective surfaces
    /// and detects points that couldn't be seen directly
    func isBackReflection(
        point: SIMD3<Float>,
        normal: SIMD3<Float>,
        cameraPosition: SIMD3<Float>?
    ) -> Bool {
        guard let camPos = cameraPosition ?? cameraPositions.last else {
            return false
        }

        // 1. Check if point is behind a known wall
        // If we have established walls, check if this point is on the wrong side
        if let floorY = statistics.floorHeight,
           let ceilingY = statistics.ceilingHeight {

            // Point above ceiling or below floor is suspicious
            if point.y > ceilingY + 0.3 || point.y < floorY - 0.3 {
                return true
            }
        }

        // 2. Check normal direction vs view direction
        // If we're looking at the back of a surface, it's likely a reflection
        let viewDirection = simd_normalize(point - camPos)
        let dotProduct = simd_dot(normal, viewDirection)

        // If normal points same direction as view (back face), suspicious
        // Real surfaces should have normals facing the camera (negative dot product)
        if dotProduct > 0.5 {
            return true
        }

        // 3. Check if point is unreasonably far
        let distance = simd_length(point - camPos)
        if distance > 10.0 {  // More than 10m away is suspicious for indoor scanning
            return true
        }

        // 4. Check for points that appear on surfaces we couldn't see
        // If looking down at floor but point is on top of a tall object we're not looking at
        if let floorY = statistics.floorHeight {
            let heightAboveFloor = point.y - floorY
            let cameraHeightAboveFloor = camPos.y - floorY

            // If point is above camera eye level but has upward normal (object top)
            // and camera is looking down, this could be a reflection
            if heightAboveFloor > cameraHeightAboveFloor && normal.y > 0.7 {
                // Camera can't see tops of things above eye level while looking down
                let cameraLookingDown = viewDirection.y < -0.3
                if cameraLookingDown {
                    return true
                }
            }
        }

        return false
    }

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

    // MARK: - Calibration (User teaches floor/ceiling by pointing)

    /// Calibrate floor plane - called when user points at floor for 3+ seconds
    func calibrateFloor(height: Float, normal: SIMD3<Float>) {
        calibratedFloorHeight = height
        calibratedFloorNormal = normal
        floorCalibrated = true
        statistics.floorHeight = height
        debugLog("[SurfaceClassifier] Floor CALIBRATED at Y=\(height), normal=\(normal)")
    }

    /// Calibrate ceiling plane - called when user points at ceiling for 3+ seconds
    func calibrateCeiling(height: Float, normal: SIMD3<Float>) {
        calibratedCeilingHeight = height
        calibratedCeilingNormal = normal
        ceilingCalibrated = true
        statistics.ceilingHeight = height
        debugLog("[SurfaceClassifier] Ceiling CALIBRATED at Y=\(height), normal=\(normal)")
    }

    /// Clear floor calibration
    func clearFloorCalibration() {
        calibratedFloorHeight = nil
        calibratedFloorNormal = nil
        floorCalibrated = false
        debugLog("[SurfaceClassifier] Floor calibration cleared")
    }

    /// Clear ceiling calibration
    func clearCeilingCalibration() {
        calibratedCeilingHeight = nil
        calibratedCeilingNormal = nil
        ceilingCalibrated = false
        debugLog("[SurfaceClassifier] Ceiling calibration cleared")
    }

    /// Check if a point matches the calibrated floor plane
    private func matchesCalibratedFloor(worldY: Float, normal: SIMD3<Float>) -> Bool {
        guard let floorY = calibratedFloorHeight else { return false }

        // Must be within tolerance of calibrated height
        let heightMatch = abs(worldY - floorY) < calibrationTolerance

        // Normal should be pointing up (similar to calibrated normal)
        let normalMatch = normal.y > 0.5

        return heightMatch && normalMatch
    }

    /// Check if a point matches the calibrated ceiling plane
    private func matchesCalibratedCeiling(worldY: Float, normal: SIMD3<Float>) -> Bool {
        guard let ceilingY = calibratedCeilingHeight else { return false }

        // Must be within tolerance of calibrated height
        let heightMatch = abs(worldY - ceilingY) < calibrationTolerance

        // Normal should be pointing down (similar to calibrated normal)
        let normalMatch = normal.y < -0.5

        return heightMatch && normalMatch
    }

    // MARK: - Surface Classification

    /// Classify a single surface based on its average normal
    func classifySurface(averageNormal: SIMD3<Float>, worldY: Float) -> SurfaceType {
        return classifySurfaceWithPosition(
            averageNormal: averageNormal,
            worldPosition: SIMD3<Float>(0, worldY, 0),
            cameraPosition: wallMeasurementOrigin
        )
    }

    /// Classify a surface with full position information (enables wall distance detection)
    func classifySurfaceWithPosition(
        averageNormal: SIMD3<Float>,
        worldPosition: SIMD3<Float>,
        cameraPosition: SIMD3<Float>?
    ) -> SurfaceType {
        guard classificationEnabled else { return .unknown }

        // PRIORITY 0: Check for back reflections (LiDAR artifacts)
        // These are impossible points caused by reflections off shiny surfaces
        if isBackReflection(point: worldPosition, normal: averageNormal, cameraPosition: cameraPosition) {
            return .backReflection
        }

        let worldY = worldPosition.y
        let useCalibration = AppSettings.shared.useCalibration
        let useML = AppSettings.shared.useMLClassification && mlModelLoaded

        // PRIORITY 1: Use calibrated floor/ceiling planes (most accurate)
        if useCalibration {
            // Always collect samples from upward-facing surfaces for density analysis
            if averageNormal.y > 0.5 {
                updateFloorHeight(worldY)
            }

            // Check floor (continuous surface, normal pointing up, at calibrated Y)
            if floorCalibrated {
                if isPartOfFloorPlane(point: worldPosition, normal: averageNormal) {
                    debugLog("[FLOOR-CLASS] CALIBRATED path: Y=\(worldY), floorY=\(calibratedFloorHeight ?? -999)")
                    return .floor
                }
            }

            // Always collect samples from downward-facing surfaces for density analysis
            if averageNormal.y < -0.5 {
                updateCeilingHeight(worldY)
            }

            // Check ceiling (continuous surface, normal pointing down, at calibrated Y)
            if ceilingCalibrated {
                if isPartOfCeilingPlane(point: worldPosition, normal: averageNormal) {
                    return classifyCeilingSurface(worldY: worldY, normal: averageNormal)
                }
            }

            // If BOTH floor and ceiling calibrated, use refined classification
            if isFullyCalibrated {
                let floorY = calibratedFloorHeight!
                let ceilingY = calibratedCeilingHeight!

                // Upward-facing surface: floor (within 1mm) or objectTop (above floor)
                if averageNormal.y > 0.5 {  // Faces up
                    let heightAboveFloor = abs(worldY - floorY)
                    if heightAboveFloor < heightBinSize {  // Within 1mm = floor
                        return .floor
                    } else {
                        return .objectTop  // Above floor plane = object top
                    }
                }

                // Downward-facing surface: ceiling (within 1mm) or protrusion/object
                if averageNormal.y < -0.5 {  // Faces down
                    let heightBelowCeiling = abs(ceilingY - worldY)
                    if heightBelowCeiling < heightBinSize {  // Within 1mm = ceiling
                        return .ceiling
                    } else {
                        return classifyCeilingSurface(worldY: worldY, normal: averageNormal)  // Protrusion or object
                    }
                }

                // Vertical surface between floor and ceiling - classify as wall
                if abs(averageNormal.y) < 0.5 {
                    let horizontalMag = sqrt(averageNormal.x * averageNormal.x + averageNormal.z * averageNormal.z)
                    if horizontalMag > 0.5 {
                        return .wall
                    }
                }
            } else {
                // Only one calibrated - use what we have
                if floorCalibrated && averageNormal.y > 0.5 {
                    // Surface faces up but doesn't match floor (outside 1mm) = object top
                    return .objectTop
                }

                if ceilingCalibrated && averageNormal.y < -0.5 {
                    // Surface faces down but doesn't match ceiling = check protrusion or object
                    return classifyCeilingSurface(worldY: worldY, normal: averageNormal)
                }

                // Vertical surface - classify as wall based on normal
                if abs(averageNormal.y) < 0.5 {
                    let horizontalMag = sqrt(averageNormal.x * averageNormal.x + averageNormal.z * averageNormal.z)
                    if horizontalMag > 0.5 {
                        return .wall
                    }
                }
            }
        }

        // PRIORITY 2: ML classification (if enabled and model loaded)
        if useML {
            if let mlResult = getMLEnhancedClassification(worldPoint: worldPosition, normal: averageNormal) {
                return mlResult
            }
        }

        // PRIORITY 3: Distance-based classification per scan phase
        // Farthest points from LiDAR are the actual surfaces (floor/ceiling/walls)
        // Closer points are objects (cabinets, furniture, etc.)
        let normalY = averageNormal.y
        let horizontalMag = sqrt(averageNormal.x * averageNormal.x + averageNormal.z * averageNormal.z)

        // Calculate distance from camera
        let camPos = cameraPosition ?? cameraPositions.last ?? SIMD3<Float>(0, 0, 0)
        let distanceFromCamera = simd_length(worldPosition - camPos)

        // Update max distances and height samples based on normal direction
        if normalY > 0.5 {
            updateFloorHeight(worldY)
            // Track farthest floor point (looking down at floor)
            if distanceFromCamera > maxFloorDistance {
                maxFloorDistance = distanceFromCamera
            }
        } else if normalY < -0.5 {
            updateCeilingHeight(worldY)
            // Track farthest ceiling point (looking up at ceiling)
            if distanceFromCamera > maxCeilingDistance {
                maxCeilingDistance = distanceFromCamera
            }
        } else if horizontalMag > 0.5 {
            // Track farthest wall point
            if distanceFromCamera > maxWallDistance {
                maxWallDistance = distanceFromCamera
            }
        }

        // Floor detection: normal pointing UP
        if normalY > 0.7 {
            // During floor scanning: farthest points = floor, closer = object tops
            if maxFloorDistance > 0 {
                // Points at or near max distance are floor
                // Points significantly closer are cabinet/object tops
                if distanceFromCamera >= maxFloorDistance - distanceTolerance {
                    return .floor
                } else {
                    return .objectTop
                }
            }
            return .floor  // No max distance yet, assume floor
        }

        // Ceiling detection: normal pointing DOWN
        if normalY < -0.7 {
            // During ceiling scanning: farthest points = ceiling, closer = object bottoms
            if maxCeilingDistance > 0 {
                if distanceFromCamera >= maxCeilingDistance - distanceTolerance {
                    return .ceiling
                } else {
                    return .objectTop
                }
            }
            return .ceiling  // No max distance yet, assume ceiling
        }

        // Wall detection: normal pointing horizontally
        if horizontalMag > 0.7 && abs(normalY) < 0.5 {
            // During wall scanning: farthest points = walls, closer = furniture
            if maxWallDistance > 0 {
                if distanceFromCamera >= maxWallDistance - distanceTolerance {
                    return .wall
                } else {
                    return .object  // Furniture, cabinets against walls
                }
            }
            return .wall  // No max distance yet, assume wall
        }

        // Tilted surfaces - classify based on dominant direction and distance
        if normalY > 0.5 {
            if maxFloorDistance > 0 && distanceFromCamera >= maxFloorDistance - distanceTolerance {
                return .floor
            }
            return .objectTop
        } else if normalY < -0.5 {
            if maxCeilingDistance > 0 && distanceFromCamera >= maxCeilingDistance - distanceTolerance {
                return .ceiling
            }
            return .objectTop
        } else if horizontalMag > 0.5 {
            if maxWallDistance > 0 && distanceFromCamera >= maxWallDistance - distanceTolerance {
                return .wall
            }
            return .object
        }

        // Anything else is an object
        return .object
    }

    /// Classify downward-facing surface as ceiling, cove, protrusion, or object bottom
    private func classifyCeilingSurface(worldY: Float, normal: SIMD3<Float>? = nil) -> SurfaceType {
        // Check for cove (rounded ceiling-wall transition)
        // Coves have angled normals: not purely downward (ceiling) nor horizontal (wall)
        if let n = normal {
            // Cove detection: normal Y between -0.85 and -0.35 (roughly 30-70 degrees from horizontal)
            // AND has significant horizontal component
            let horizontalLength = sqrt(n.x * n.x + n.z * n.z)
            let isCoveAngle = n.y < -0.35 && n.y > -0.85 && horizontalLength > 0.4

            if isCoveAngle {
                // Also check if we're near ceiling height
                if let ceilingHeight = statistics.ceilingHeight {
                    let distanceFromCeiling = abs(ceilingHeight - worldY)
                    // Within 30cm of ceiling = cove
                    if distanceFromCeiling < 0.3 {
                        return .cove
                    }
                } else {
                    // No ceiling reference yet, but angle suggests cove
                    // Could be a cove if we're looking up
                    return .cove
                }
            }
        }

        // If we have a ceiling height estimate, use density-based classification
        if let ceilingHeight = statistics.ceilingHeight {
            let distanceFromCeiling = abs(ceilingHeight - worldY)

            // Within 1mm bin (highest density range) = true ceiling
            if distanceFromCeiling < heightBinSize {
                return .ceiling
            }

            let depthBelowCeiling = ceilingHeight - worldY

            if depthBelowCeiling > protrusionMinDepth && depthBelowCeiling < protrusionMaxDepth {
                // This is below the main ceiling but not too far - it's a protrusion (beam, duct, etc.)
                return .ceilingProtrusion
            } else if depthBelowCeiling >= protrusionMaxDepth {
                // Too far below ceiling - could be bottom of hanging object (light fixture, etc.)
                // or a dropped ceiling section
                return .objectTop  // Reuse objectTop for downward-facing object surfaces
            } else if depthBelowCeiling > heightBinSize {
                // Between 1mm and protrusionMinDepth - small protrusion or surface irregularity
                return .ceilingProtrusion
            }
        }

        // No ceiling reference yet - collect sample but don't classify as ceiling
        // Ceiling will be determined by density (highest point count in 1mm bin)
        updateCeilingHeight(worldY)
        return .unknown  // Will be reclassified once ceiling height is established
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

        // Classify protrusion type based on shape and depth
        // Beams: protrude downward from ceiling, lower surface parallel to ceiling
        // - Shallow beams: 3-10cm depth (decorative/crown molding)
        // - Deep beams: 10-50cm depth (structural)
        let aspectRatio = max(width, length) / max(min(width, length), 0.01)

        let protrusionType: CeilingProtrusion.ProtrusionType
        if aspectRatio > 4 && area < 3.0 {
            // Long and narrow = beam (structural or decorative)
            // Lower surface is parallel to ceiling (we already know normal faces down)
            protrusionType = .beam
        } else if aspectRatio > 2.5 && area >= 0.3 && depth < 0.4 {
            protrusionType = .duct  // Rectangular, moderate size, not too deep
        } else if area < 0.25 {
            protrusionType = .fixture  // Small, compact (lights, sprinklers)
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
        statistics.coveArea = surfaceAreas[.cove, default: 0]
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
        // Skip edge detection on very large meshes to avoid memory issues
        let maxFacesForEdgeDetection = 5000
        guard faces.count < maxFacesForEdgeDetection else {
            debugLog("[SurfaceClassifier] Skipping edge detection - mesh too large (\(faces.count) faces)")
            return
        }

        // Also skip if we already have enough edges
        guard statistics.detectedEdges.count < 150 else {
            return
        }

        debugLog("[SurfaceClassifier] detectEdges called with \(faces.count) faces")

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
        var typeChangeCount = 0
        var sharpAngleCount = 0

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

            if isTypeChange { typeChangeCount += 1 }
            if isSharpAngle { sharpAngleCount += 1 }

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

        debugLog("[SurfaceClassifier] Edge detection: \(typeChangeCount) type changes, \(sharpAngleCount) sharp angles, \(detectedEdgePoints.count) edges found")

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

    /// Merge nearby edge segments into longer edges and extend to floor/ceiling
    private func mergeEdgeSegments(_ segments: [(start: SIMD3<Float>, end: SIMD3<Float>, type: WallEdge.EdgeType, angle: Float)]) {
        // Simple approach: keep significant edges, limit total count
        let significantEdges = segments.filter { segment in
            let length = simd_distance(segment.start, segment.end)
            return length > 0.05  // At least 5cm (lowered from 10cm to catch more edges)
        }

        // Sort by angle (sharpest first) and take top edges
        let sortedEdges = significantEdges.sorted { $0.angle > $1.angle }
        let topEdges = Array(sortedEdges.prefix(50))  // Keep top 50 edges from this mesh

        // Create new edges and APPEND to existing (accumulate across meshes)
        let newEdges = topEdges.map { segment -> WallEdge in
            var start = segment.start
            var end = segment.end

            // For vertical corners, extend to floor and ceiling planes
            if segment.type == .verticalCorner {
                if let floorH = statistics.floorHeight {
                    // Extend to floor
                    let lowerY = min(start.y, end.y)
                    if lowerY > floorH {
                        if start.y < end.y {
                            start.y = floorH
                        } else {
                            end.y = floorH
                        }
                    }
                }
                if let ceilingH = statistics.ceilingHeight {
                    // Extend to ceiling
                    let upperY = max(start.y, end.y)
                    if upperY < ceilingH {
                        if start.y > end.y {
                            start.y = ceilingH
                        } else {
                            end.y = ceilingH
                        }
                    }
                }
            }

            return WallEdge(
                id: UUID(),
                startPoint: start,
                endPoint: end,
                edgeType: segment.type,
                angle: segment.angle
            )
        }

        // Append new edges, avoiding duplicates (edges with very similar positions)
        for newEdge in newEdges {
            let isDuplicate = statistics.detectedEdges.contains { existingEdge in
                let startDist = simd_distance(existingEdge.startPoint, newEdge.startPoint)
                let endDist = simd_distance(existingEdge.endPoint, newEdge.endPoint)
                let reversedStartDist = simd_distance(existingEdge.startPoint, newEdge.endPoint)
                let reversedEndDist = simd_distance(existingEdge.endPoint, newEdge.startPoint)

                let normalMatch = (startDist < 0.15 && endDist < 0.15)
                let reversedMatch = (reversedStartDist < 0.15 && reversedEndDist < 0.15)

                return normalMatch || reversedMatch
            }

            if !isDuplicate {
                statistics.detectedEdges.append(newEdge)
            }
        }

        // Limit total edges to prevent memory issues
        if statistics.detectedEdges.count > 200 {
            // Keep the most significant edges (longest, by angle)
            statistics.detectedEdges.sort { $0.length > $1.length }
            statistics.detectedEdges = Array(statistics.detectedEdges.prefix(150))
        }

        debugLog("[SurfaceClassifier] Total accumulated edges: \(statistics.detectedEdges.count)")
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
        let center = (minBound + maxBound) / 2
        let heightRange = (min: minBound.y, max: maxBound.y)

        // Classify surface based on normal direction and constraints
        let surfaceType: SurfaceType

        // For vertical surfaces, use bounds-aware classification
        // This enforces the constraint that walls span floor-to-ceiling
        if abs(averageNormal.y) < 0.5 {
            // Vertical surface - check if it's a wall (floor-to-ceiling) or object
            surfaceType = classifyVerticalSurfaceWithBounds(
                position: center,
                normal: averageNormal,
                heightRange: heightRange,
                cameraPosition: wallMeasurementOrigin
            )
        } else {
            // Horizontal surface - use standard classification
            surfaceType = classifySurfaceEnhanced(averageNormal: averageNormal, worldPosition: center)
        }

        // Calculate confidence
        var confidence = min(1.0, length(normalSum) / (totalArea + 0.001))
        if surfaceType == .wall {
            // Boost confidence if this wall is at farthest distance
            confidence = min(1.0, confidence + 0.1)
        }
        if mlClassificationEnabled && getMLEnhancedClassification(worldPoint: center, normal: averageNormal) != nil {
            confidence = min(1.0, confidence + 0.2)  // Boost confidence for ML-backed classification
        }

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

    // MARK: - Height Estimation (Density-Based)

    /// Bin size for density histogram (1mm bins for sub-mm precision)
    private let heightBinSize: Float = 0.001  // 1mm

    private func updateFloorHeight(_ y: Float) {
        floorHeightSamples.append(y)

        // Keep last 1000 samples for better density estimation
        if floorHeightSamples.count > 1000 {
            floorHeightSamples.removeFirst()
        }

        // Need enough samples for reliable density estimation
        if floorHeightSamples.count >= 20 {
            let oldHeight = statistics.floorHeight
            statistics.floorHeight = findTightestCluster(samples: floorHeightSamples, findLowest: true)
            if oldHeight != statistics.floorHeight {
                debugLog("[FLOOR-DENSITY] Floor height updated: \(statistics.floorHeight ?? -999) from \(floorHeightSamples.count) samples, range: \(floorHeightSamples.min() ?? 0) to \(floorHeightSamples.max() ?? 0)")
            }
        }
    }

    private func updateCeilingHeight(_ y: Float) {
        ceilingHeightSamples.append(y)

        if ceilingHeightSamples.count > 1000 {
            ceilingHeightSamples.removeFirst()
        }

        if ceilingHeightSamples.count >= 20 {
            statistics.ceilingHeight = findTightestCluster(samples: ceilingHeightSamples, findLowest: false)
        }
    }

    /// Find floor/ceiling height using density at lowest/highest Y
    /// For floor: find the LOWEST Y level that has significant point density
    /// For ceiling: find the HIGHEST Y level that has significant point density
    /// This ensures we capture the actual floor/ceiling, not cabinet tops/bottoms
    private func findTightestCluster(samples: [Float], findLowest: Bool) -> Float {
        guard samples.count >= 10 else { return samples.first ?? 0 }

        let sorted = samples.sorted()
        let minY = sorted.first!
        let maxY = sorted.last!
        let range = maxY - minY

        // If all samples are within 5cm, they're effectively the same surface
        guard range > 0.05 else {
            return sorted[sorted.count / 2]  // Return median
        }

        // Create 5cm bins for density analysis
        let binSize: Float = 0.05  // 5cm bins
        let binCount = max(1, Int(range / binSize) + 1)
        var histogram = [Int](repeating: 0, count: binCount)

        // Fill histogram
        for y in samples {
            let binIndex = min(binCount - 1, Int((y - minY) / binSize))
            histogram[binIndex] += 1
        }

        // Find threshold for "significant" density (at least 10% of max density)
        let maxDensity = histogram.max() ?? 1
        let densityThreshold = max(3, maxDensity / 10)

        // For floor: find LOWEST bin with significant density
        // For ceiling: find HIGHEST bin with significant density
        var selectedBin = 0
        if findLowest {
            // Start from lowest and find first bin with significant density
            for i in 0..<binCount {
                if histogram[i] >= densityThreshold {
                    selectedBin = i
                    break
                }
            }
        } else {
            // Start from highest and find first bin with significant density
            for i in stride(from: binCount - 1, through: 0, by: -1) {
                if histogram[i] >= densityThreshold {
                    selectedBin = i
                    break
                }
            }
        }

        // Calculate precise Y by averaging all points within this bin and adjacent bins
        let binY = minY + Float(selectedBin) * binSize
        var sum: Float = 0
        var count = 0

        for y in samples {
            if abs(y - binY) < binSize * 1.5 {  // Within 1.5 bins
                sum += y
                count += 1
            }
        }

        let result = count > 0 ? sum / Float(count) : binY
        debugLog("[HEIGHT] \(findLowest ? "FLOOR" : "CEILING"): samples=\(samples.count), bins=\(binCount), selectedBin=\(selectedBin), density=\(histogram[selectedBin]), result=\(result)")
        return result
    }

    // MARK: - Point Filtering

    /// Check if a point is within room bounds (between floor and ceiling)
    func isPointWithinRoomBounds(_ point: SIMD3<Float>) -> Bool {
        guard let floorY = calibratedFloorHeight ?? statistics.floorHeight,
              let ceilingY = calibratedCeilingHeight ?? statistics.ceilingHeight else {
            return true  // No bounds established, accept all points
        }

        // Point must be between floor and ceiling (with small tolerance for surface thickness)
        let tolerance: Float = 0.05  // 5cm tolerance
        return point.y >= floorY - tolerance && point.y <= ceilingY + tolerance
    }

    /// Filter vertices to only include points within room bounds
    func filterVerticesWithinBounds(_ vertices: [SIMD3<Float>]) -> [SIMD3<Float>] {
        return vertices.filter { isPointWithinRoomBounds($0) }
    }

    // MARK: - Optimization Hints

    /// Returns true if we should skip detailed processing for this surface type
    func shouldReduceDetail(for surfaceType: SurfaceType) -> Bool {
        switch surfaceType {
        case .ceiling, .ceilingProtrusion, .cove:
            return true // Ceilings are usually flat, less detail needed
        case .floor, .floorEdge:
            return false // Floors may have furniture, keep detail
        case .wall, .wallEdge:
            return false // Walls have features
        case .door, .doorFrame, .window, .windowFrame:
            return false // Openings need detail
        case .object, .objectTop:
            return false // Objects need detail
        case .backReflection:
            return true // Back reflections don't need detail
        case .unknown:
            return false
        }
    }

    /// Suggested update interval multiplier for surface type
    func updateIntervalMultiplier(for surfaceType: SurfaceType) -> Double {
        switch surfaceType {
        case .ceiling, .ceilingProtrusion, .cove: return 3.0  // Update ceiling 3x less frequently
        case .floor, .floorEdge: return 1.5            // Floor slightly less
        case .wall, .wallEdge: return 1.0              // Walls normal rate
        case .door, .doorFrame, .window, .windowFrame: return 0.8  // Openings slightly more
        case .object, .objectTop: return 0.5           // Objects more frequently
        case .backReflection: return 5.0               // Back reflections rarely need update
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

    // MARK: - Distance Anomaly Detection (for doors/windows)

    /// Detect openings by analyzing distance anomalies in wall distance data
    /// A sudden jump to much farther distance = likely door opening
    /// Inconsistent/noisy readings = likely glass window
    func detectOpeningsByDistanceAnomaly() {
        guard wallDistanceByAngle.count > 10 else { return }  // Need enough data

        let sortedAngles = wallDistanceByAngle.keys.sorted()
        var candidates: [OpeningCandidate] = []

        for i in 1..<sortedAngles.count {
            let prevAngle = sortedAngles[i - 1]
            let currAngle = sortedAngles[i]
            let prevDist = wallDistanceByAngle[prevAngle]!
            let currDist = wallDistanceByAngle[currAngle]!

            // Check for sudden distance jump (>2m difference = likely opening)
            let distanceJump = currDist - prevDist
            if abs(distanceJump) > 2.0 {
                // This is a potential opening
                let openingAngle = Float(currAngle)
                let wallDist = min(prevDist, currDist)  // The closer one is the wall
                let openingDist = max(prevDist, currDist)  // The farther one sees through opening

                // Estimate position
                let angleRad = openingAngle * .pi / 180
                let origin = wallMeasurementOrigin ?? SIMD3<Float>(0, 0, 0)
                let position = origin + SIMD3<Float>(cos(angleRad), 0, sin(angleRad)) * wallDist

                // Estimate bottom height (if we have floor calibration)
                let bottomHeight = calibratedFloorHeight.map { statistics.floorHeight ?? 0 - $0 } ?? 0

                let candidate = OpeningCandidate(
                    id: UUID(),
                    position: position,
                    wallAngle: openingAngle,
                    wallDistance: wallDist,
                    openingDistance: openingDist,
                    bottomHeight: bottomHeight,
                    detectionType: .distanceJump,
                    detectionCount: 1
                )

                // Check if similar candidate exists
                if let existingIndex = candidates.firstIndex(where: {
                    abs($0.wallAngle - candidate.wallAngle) < 15  // Within 15 degrees
                }) {
                    candidates[existingIndex].detectionCount += 1
                } else {
                    candidates.append(candidate)
                }
            }
        }

        // Check for noise patterns (inconsistent readings = glass)
        detectGlassWindowsByNoise(&candidates)

        // Add to statistics
        for candidate in candidates where candidate.detectionCount >= 2 {
            // Only add candidates detected multiple times
            if !statistics.openingCandidates.contains(where: {
                simd_distance($0.position, candidate.position) < 0.5
            }) {
                statistics.openingCandidates.append(candidate)
                debugLog("[SurfaceClassifier] Opening candidate detected: \(candidate.detectionType.rawValue) at angle \(candidate.wallAngle)°")
            }
        }
    }

    /// Detect glass windows by analyzing noise in wall distance readings
    private func detectGlassWindowsByNoise(_ candidates: inout [OpeningCandidate]) {
        // Look for sections with high variance (glass causes inconsistent readings)
        let sortedAngles = wallDistanceByAngle.keys.sorted()
        guard sortedAngles.count > 20 else { return }

        // Analyze in windows of 20 degrees
        let windowSize = 4  // 4 buckets = 20 degrees
        for i in 0..<(sortedAngles.count - windowSize) {
            let windowAngles = sortedAngles[i..<(i + windowSize)]
            let windowDistances = windowAngles.compactMap { wallDistanceByAngle[$0] }

            guard windowDistances.count == windowSize else { continue }

            // Calculate variance
            let mean = windowDistances.reduce(0, +) / Float(windowDistances.count)
            let variance = windowDistances.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(windowDistances.count)
            let stdDev = sqrt(variance)

            // High variance (>0.5m std dev) suggests glass
            if stdDev > 0.5 {
                let centerAngle = Float(sortedAngles[i + windowSize / 2])
                let angleRad = centerAngle * .pi / 180
                let origin = wallMeasurementOrigin ?? SIMD3<Float>(0, 0, 0)
                let position = origin + SIMD3<Float>(cos(angleRad), 0, sin(angleRad)) * mean

                let candidate = OpeningCandidate(
                    id: UUID(),
                    position: position,
                    wallAngle: centerAngle,
                    wallDistance: mean,
                    openingDistance: mean + stdDev * 2,
                    bottomHeight: 0.8,  // Assume window height if glass detected
                    detectionType: .noisePattern,
                    detectionCount: 2   // Give glass detection medium confidence
                )

                if !candidates.contains(where: { abs($0.wallAngle - centerAngle) < 15 }) {
                    candidates.append(candidate)
                }
            }
        }
    }

    // MARK: - Door/Window Calibration

    /// Calibrate a door at the specified position (user pointed at it for 3s)
    func calibrateDoor(at position: SIMD3<Float>, wallNormal: SIMD3<Float>) {
        let floorY = calibratedFloorHeight ?? statistics.floorHeight ?? 0

        // Create calibrated door with estimated dimensions
        var door = DetectedDoor(
            id: UUID(),
            position: position,
            width: 0.9,   // Standard door width estimate
            height: 2.1,  // Standard door height estimate
            wallNormal: wallNormal,
            boundingBox: (
                SIMD3<Float>(position.x - 0.45, floorY, position.z - 0.1),
                SIMD3<Float>(position.x + 0.45, floorY + 2.1, position.z + 0.1)
            ),
            confidence: 1.0,
            source: .calibrated,
            isConfirmed: true
        )

        // Try to refine dimensions from nearby mesh gap data
        if let nearbyCandidate = statistics.openingCandidates.first(where: {
            simd_distance($0.position, position) < 1.0 && $0.likelyType == .door
        }) {
            // Use auto-detected candidate to refine position
            debugLog("[SurfaceClassifier] Refining door from auto-detected candidate")
        }

        // Remove any existing door at this position
        statistics.detectedDoors.removeAll { simd_distance($0.position, position) < 0.5 }

        // Add calibrated door
        statistics.detectedDoors.append(door)
        debugLog("[SurfaceClassifier] Door CALIBRATED at \(position)")

        // Remove from candidates (now confirmed)
        statistics.openingCandidates.removeAll { simd_distance($0.position, position) < 1.0 }
    }

    /// Calibrate a window at the specified position (user pointed at it for 3s)
    func calibrateWindow(at position: SIMD3<Float>, wallNormal: SIMD3<Float>, hasGlass: Bool = true) {
        let floorY = calibratedFloorHeight ?? statistics.floorHeight ?? 0
        let windowBottom = max(position.y - 0.5, floorY + 0.8)  // At least 80cm from floor

        var window = DetectedWindow(
            id: UUID(),
            position: position,
            width: 1.0,   // Estimate
            height: 1.2,  // Estimate
            heightFromFloor: windowBottom - floorY,
            wallNormal: wallNormal,
            boundingBox: (
                SIMD3<Float>(position.x - 0.5, windowBottom, position.z - 0.1),
                SIMD3<Float>(position.x + 0.5, windowBottom + 1.2, position.z + 0.1)
            ),
            confidence: 1.0,
            source: .calibrated,
            isConfirmed: true,
            hasGlass: hasGlass
        )

        // Remove any existing window at this position
        statistics.detectedWindows.removeAll { simd_distance($0.position, position) < 0.5 }

        // Add calibrated window
        statistics.detectedWindows.append(window)
        debugLog("[SurfaceClassifier] Window CALIBRATED at \(position), hasGlass=\(hasGlass)")

        // Remove from candidates
        statistics.openingCandidates.removeAll { simd_distance($0.position, position) < 1.0 }
    }

    /// Confirm an auto-detected opening candidate as door or window
    func confirmOpeningCandidate(candidateID: UUID, asDoor: Bool) {
        guard let candidateIndex = statistics.openingCandidates.firstIndex(where: { $0.id == candidateID }) else {
            return
        }

        let candidate = statistics.openingCandidates[candidateIndex]
        let wallNormal = SIMD3<Float>(cos(candidate.wallAngle * .pi / 180), 0, sin(candidate.wallAngle * .pi / 180))

        if asDoor {
            calibrateDoor(at: candidate.position, wallNormal: wallNormal)
        } else {
            let hasGlass = candidate.detectionType == .noisePattern
            calibrateWindow(at: candidate.position, wallNormal: wallNormal, hasGlass: hasGlass)
        }
    }

    /// Get the nearest opening candidate to a position (for calibration)
    func getNearestOpeningCandidate(to position: SIMD3<Float>, maxDistance: Float = 1.0) -> OpeningCandidate? {
        return statistics.openingCandidates
            .filter { simd_distance($0.position, position) < maxDistance }
            .min { simd_distance($0.position, position) < simd_distance($1.position, position) }
    }

    /// Check if pointing at a wall region that could be an opening
    /// Used during calibration to detect if user is pointing at potential door/window
    func isPointingAtPotentialOpening(position: SIMD3<Float>, normal: SIMD3<Float>) -> (isOpening: Bool, type: SurfaceType?) {
        // Must be a vertical surface (wall region)
        guard abs(normal.y) < 0.5 else {
            return (false, nil)
        }

        // Check if there's an existing candidate nearby
        if let candidate = getNearestOpeningCandidate(to: position, maxDistance: 0.8) {
            return (true, candidate.likelyType)
        }

        // Check if there's already a detected door/window nearby
        if statistics.detectedDoors.contains(where: { simd_distance($0.position, position) < 0.8 }) {
            return (true, .door)
        }
        if statistics.detectedWindows.contains(where: { simd_distance($0.position, position) < 0.8 }) {
            return (true, .window)
        }

        // Check height - if pointing at wall but above typical window bottom, could be window
        let floorY = calibratedFloorHeight ?? statistics.floorHeight ?? 0
        let heightFromFloor = position.y - floorY

        if heightFromFloor > 0.5 && heightFromFloor < 2.0 {
            // In window/door height range - could be an opening
            // Return nil type to indicate uncertainty
            return (true, nil)
        }

        return (false, nil)
    }

    // MARK: - Core ML Integration

    /// Load the indoor segmentation ML model
    func loadMLModel() -> Bool {
        // Try compiled model first (.mlmodelc)
        if let modelURL = Bundle.main.url(forResource: "IndoorSegmentation", withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                segmentationModel = try MLModel(contentsOf: modelURL, configuration: config)
                mlModelLoaded = true
                debugLog("[SurfaceClassifier] Loaded ML model: IndoorSegmentation.mlmodelc")
                return true
            } catch {
                debugLog("[SurfaceClassifier] Failed to load .mlmodelc: \(error)")
            }
        }

        // Try mlpackage
        if let modelURL = Bundle.main.url(forResource: "IndoorSegmentation", withExtension: "mlpackage") {
            do {
                let compiledURL = try MLModel.compileModel(at: modelURL)
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                segmentationModel = try MLModel(contentsOf: compiledURL, configuration: config)
                mlModelLoaded = true
                debugLog("[SurfaceClassifier] Loaded and compiled ML model: IndoorSegmentation.mlpackage")
                return true
            } catch {
                debugLog("[SurfaceClassifier] Failed to load .mlpackage: \(error)")
            }
        }

        debugLog("[SurfaceClassifier] No ML model found - using geometric heuristics only")
        return false
    }

    /// Enable/disable ML-enhanced classification
    func setMLClassificationEnabled(_ enabled: Bool) {
        mlClassificationEnabled = enabled && mlModelLoaded
        if mlClassificationEnabled {
            debugLog("[SurfaceClassifier] ML classification enabled")
        }
    }

    /// Add points for ML batch processing
    func accumulatePointsForML(vertices: [SIMD3<Float>], normals: [SIMD3<Float>], transform: simd_float4x4) {
        guard mlClassificationEnabled else { return }

        // Transform to world space and accumulate
        for i in 0..<min(vertices.count, normals.count) {
            let worldPos = transformPoint(vertices[i], by: transform)
            let worldNormal = transformNormal(normals[i], by: transform)

            accumulatedPoints.append(worldPos)
            accumulatedNormals.append(worldNormal)
        }

        // Trim if too many points
        if accumulatedPoints.count > maxAccumulatedPoints {
            // Keep most recent points with some spatial sampling
            let keepCount = maxAccumulatedPoints / 2
            accumulatedPoints = Array(accumulatedPoints.suffix(keepCount))
            accumulatedNormals = Array(accumulatedNormals.suffix(keepCount))
        }
    }

    /// Run ML inference on accumulated points (call periodically)
    func runMLInferenceIfNeeded() async {
        guard mlClassificationEnabled,
              let model = segmentationModel,
              !accumulatedPoints.isEmpty else { return }

        let now = Date()
        guard now.timeIntervalSince(lastMLInferenceTime) >= mlInferenceInterval else { return }
        lastMLInferenceTime = now

        let points = accumulatedPoints
        let normals = accumulatedNormals

        // Run inference off main thread
        let classifications = await Task.detached(priority: .userInitiated) { [weak self] in
            return self?.runMLInference(points: points, normals: normals, model: model) ?? [:]
        }.value

        // Update cache on main thread
        for (point, surfaceType) in classifications {
            mlClassifications[point] = surfaceType
        }

        // Trim cache
        if mlClassifications.count > maxAccumulatedPoints * 2 {
            mlClassifications.removeAll()
        }
    }

    /// Run ML inference on a batch of points
    private nonisolated func runMLInference(points: [SIMD3<Float>], normals: [SIMD3<Float>], model: MLModel) -> [SIMD3<Float>: SurfaceType] {
        guard points.count == normals.count, !points.isEmpty else { return [:] }

        let numPoints = points.count

        // Prepare input: [1, N, 6] - batch of 1, N points, 6 features (xyz + normals)
        let inputArray = try? MLMultiArray(shape: [1, NSNumber(value: numPoints), 6], dataType: .float32)
        guard let input = inputArray else { return [:] }

        for i in 0..<numPoints {
            let baseIndex = i * 6
            input[baseIndex + 0] = NSNumber(value: points[i].x)
            input[baseIndex + 1] = NSNumber(value: points[i].y)
            input[baseIndex + 2] = NSNumber(value: points[i].z)
            input[baseIndex + 3] = NSNumber(value: normals[i].x)
            input[baseIndex + 4] = NSNumber(value: normals[i].y)
            input[baseIndex + 5] = NSNumber(value: normals[i].z)
        }

        // Create feature provider
        let inputFeatures = try? MLDictionaryFeatureProvider(dictionary: ["points": input])
        guard let features = inputFeatures else { return [:] }

        // Run prediction
        guard let prediction = try? model.prediction(from: features) else { return [:] }

        // Parse output - expect [1, N, 4] probabilities for floor/ceiling/wall/object
        guard let outputArray = prediction.featureValue(for: "classifications")?.multiArrayValue else { return [:] }

        var results: [SIMD3<Float>: SurfaceType] = [:]

        for i in 0..<numPoints {
            let baseIndex = i * 4

            // Get probabilities
            let floorProb = outputArray[baseIndex + 0].floatValue
            let ceilingProb = outputArray[baseIndex + 1].floatValue
            let wallProb = outputArray[baseIndex + 2].floatValue
            let objectProb = outputArray[baseIndex + 3].floatValue

            // Find max probability class
            let maxProb = max(floorProb, max(ceilingProb, max(wallProb, objectProb)))
            let surfaceType: SurfaceType

            if maxProb == floorProb {
                surfaceType = .floor
            } else if maxProb == ceilingProb {
                surfaceType = .ceiling
            } else if maxProb == wallProb {
                surfaceType = .wall
            } else {
                surfaceType = .object
            }

            results[points[i]] = surfaceType
        }

        return results
    }

    /// Get ML-enhanced classification for a point (falls back to geometric if no ML result)
    func getMLEnhancedClassification(worldPoint: SIMD3<Float>, normal: SIMD3<Float>) -> SurfaceType? {
        guard mlClassificationEnabled else { return nil }

        // Look for nearby cached ML classification
        let searchRadius: Float = 0.1  // 10cm

        for (cachedPoint, classification) in mlClassifications {
            if simd_distance(cachedPoint, worldPoint) < searchRadius {
                return classification
            }
        }

        return nil
    }

    /// Classify using ML if available, otherwise geometric heuristics
    func classifySurfaceEnhanced(averageNormal: SIMD3<Float>, worldPosition: SIMD3<Float>) -> SurfaceType {
        // Try ML classification first
        if let mlResult = getMLEnhancedClassification(worldPoint: worldPosition, normal: averageNormal) {
            return mlResult
        }

        // Fall back to geometric heuristics with full position (for distance-based classification)
        return classifySurfaceWithPosition(
            averageNormal: averageNormal,
            worldPosition: worldPosition,
            cameraPosition: cameraPositions.last
        )
    }

    private func transformNormal(_ normal: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let n4 = SIMD4<Float>(normal.x, normal.y, normal.z, 0)
        let transformed = transform * n4
        return simd_normalize(SIMD3<Float>(transformed.x, transformed.y, transformed.z))
    }

    // MARK: - Reset

    /// Set the current scan phase and optionally reset distance tracking
    func setScanPhase(_ phase: RoomScanPhase, resetDistances: Bool = true) {
        currentScanPhase = phase
        if resetDistances {
            // Reset distance tracking when changing phases
            maxFloorDistance = 0
            maxCeilingDistance = 0
            maxWallDistance = 0
            debugLog("[SurfaceClassifier] Scan phase changed to \(phase.rawValue), distances reset")
        }
    }

    func reset() {
        floorHeightSamples.removeAll()
        ceilingHeightSamples.removeAll()
        protrusionCandidates.removeAll()
        edgeCandidates.removeAll()
        wallGapCandidates.removeAll()
        accumulatedPoints.removeAll()
        accumulatedNormals.removeAll()
        mlClassifications.removeAll()
        wallDistanceByAngle.removeAll()
        wallMeasurementOrigin = nil

        // Reset distance tracking
        maxFloorDistance = 0
        maxCeilingDistance = 0
        maxWallDistance = 0
        currentScanPhase = .ready
        statistics = ScanStatistics()

        // Clear calibration
        calibratedFloorHeight = nil
        calibratedFloorNormal = nil
        calibratedCeilingHeight = nil
        calibratedCeilingNormal = nil
        floorCalibrated = false
        ceilingCalibrated = false
    }

    /// Clear ML-related caches to reduce memory (called under memory pressure)
    func clearMLCache() {
        accumulatedPoints.removeAll()
        accumulatedNormals.removeAll()
        mlClassifications.removeAll()
        debugLog("[SurfaceClassifier] Cleared ML cache to reduce memory")
    }

    // MARK: - Auto Floor Detection (finds largest continuous horizontal plane at lowest Y)

    /// Horizontal surface cluster for floor detection
    private struct HorizontalCluster {
        var points: [SIMD3<Float>] = []
        var ySum: Float = 0
        var averageY: Float { points.isEmpty ? 0 : ySum / Float(points.count) }
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude

        mutating func add(_ point: SIMD3<Float>) {
            points.append(point)
            ySum += point.y
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minZ = min(minZ, point.z)
            maxZ = max(maxZ, point.z)
        }

        var area: Float {
            (maxX - minX) * (maxZ - minZ)
        }
    }

    /// Auto-detect floor from accumulated horizontal surfaces
    /// Floor = largest continuous surface with normal pointing mostly up
    /// Handles sloped floors where Y varies continuously with X,Z
    func autoDetectFloor(from vertices: [SIMD3<Float>], normals: [SIMD3<Float>], transform: simd_float4x4) -> Float? {
        // Step 1: Find all "floor-like" points (normal pointing mostly up)
        // Allow up to ~30° slope (normal.y > 0.5)
        var floorCandidates: [(point: SIMD3<Float>, normal: SIMD3<Float>)] = []

        for i in 0..<min(vertices.count, normals.count) {
            let normal = normals[i]
            if normal.y > 0.5 {  // Normal points up (allows slopes up to ~60° from vertical)
                let worldPos = transform * SIMD4<Float>(vertices[i], 1.0)
                let worldPoint = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)

                // Transform normal to world space (rotation only)
                let worldNormal = simd_normalize(SIMD3<Float>(
                    transform.columns.0.x * normal.x + transform.columns.1.x * normal.y + transform.columns.2.x * normal.z,
                    transform.columns.0.y * normal.x + transform.columns.1.y * normal.y + transform.columns.2.y * normal.z,
                    transform.columns.0.z * normal.x + transform.columns.1.z * normal.y + transform.columns.2.z * normal.z
                ))

                floorCandidates.append((worldPoint, worldNormal))
            }
        }

        guard !floorCandidates.isEmpty else { return nil }

        // Step 2: Cluster by CONNECTIVITY (nearby points = same surface)
        // This handles sloped floors where Y varies
        let connectivityRadius: Float = 0.3  // Points within 30cm are connected
        var clusters: [[Int]] = []  // Each cluster is a list of point indices
        var assigned = Set<Int>()

        for i in 0..<floorCandidates.count {
            if assigned.contains(i) { continue }

            // Start new cluster with this point
            var cluster: [Int] = [i]
            var queue: [Int] = [i]
            assigned.insert(i)

            // BFS to find all connected points
            while !queue.isEmpty && cluster.count < 10000 {  // Limit for performance
                let current = queue.removeFirst()
                let currentPoint = floorCandidates[current].point

                for j in 0..<floorCandidates.count {
                    if assigned.contains(j) { continue }

                    let candidatePoint = floorCandidates[j].point
                    let dist = simd_distance(currentPoint, candidatePoint)

                    if dist < connectivityRadius {
                        cluster.append(j)
                        queue.append(j)
                        assigned.insert(j)
                    }
                }
            }

            clusters.append(cluster)
        }

        // Step 3: Find the cluster that's:
        // - Large (many points)
        // - At the lowest average Y
        // - Has significant horizontal extent
        var bestCluster: (avgY: Float, minY: Float, pointCount: Int, area: Float)? = nil

        for cluster in clusters {
            guard cluster.count > 50 else { continue }  // Need enough points

            var sumY: Float = 0
            var minY: Float = .greatestFiniteMagnitude
            var minX: Float = .greatestFiniteMagnitude
            var maxX: Float = -.greatestFiniteMagnitude
            var minZ: Float = .greatestFiniteMagnitude
            var maxZ: Float = -.greatestFiniteMagnitude

            for idx in cluster {
                let p = floorCandidates[idx].point
                sumY += p.y
                minY = min(minY, p.y)
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
                minZ = min(minZ, p.z)
                maxZ = max(maxZ, p.z)
            }

            let avgY = sumY / Float(cluster.count)
            let area = (maxX - minX) * (maxZ - minZ)

            // Floor should have significant area (> 0.5 m²)
            guard area > 0.5 else { continue }

            // Pick the cluster with lowest average Y (floor is at bottom)
            if bestCluster == nil || avgY < bestCluster!.avgY {
                bestCluster = (avgY, minY, cluster.count, area)
            }
        }

        if let floor = bestCluster {
            debugLog("[SurfaceClassifier] Auto-detected floor: avgY=\(floor.avgY), minY=\(floor.minY), points=\(floor.pointCount), area=\(floor.area)m²")
            // Return the minimum Y of the floor cluster (lowest point of floor, even if sloped)
            return floor.minY
        }

        return nil
    }

    /// Check if a point belongs to the main floor plane
    /// Uses density-based 1mm tolerance - only true floor plane points qualify
    func isPartOfFloorPlane(point: SIMD3<Float>, normal: SIMD3<Float>) -> Bool {
        // Normal must point mostly up (allows slopes up to ~45°)
        guard normal.y > 0.5 else { return false }

        // Check against calibrated/detected floor height
        if let floorY = calibratedFloorHeight ?? statistics.floorHeight {
            // Use same 1mm tolerance as density detection
            // True floor has highest density within 1mm bin
            let heightAboveFloor = abs(point.y - floorY)
            return heightAboveFloor < heightBinSize  // 1mm tolerance
        }

        return false
    }

    /// Check if a horizontal surface is likely a table/object (not floor)
    func isLikelyTableTop(point: SIMD3<Float>, normal: SIMD3<Float>) -> Bool {
        // Must have upward-facing normal
        guard normal.y > 0.5 else { return false }

        // If we know floor height, check if this is significantly above it
        if let floorY = calibratedFloorHeight ?? statistics.floorHeight {
            let heightAboveFloor = point.y - floorY

            // Tables are typically 0.5m to 1.2m above floor
            // Below 0.5m could be a sloped floor or low platform
            // Above 1.2m could be a shelf or counter
            if heightAboveFloor > 0.5 && heightAboveFloor < 1.5 {
                return true
            }

            // Also check: is the surface small/isolated?
            // (Floor is continuous, tables are bounded objects)
            // This would require checking neighbors - simplified for now
        }

        return false
    }

    /// Estimate floor slope direction from calibrated floor normal
    var floorSlopeDirection: SIMD3<Float>? {
        guard let normal = calibratedFloorNormal else { return nil }
        // Slope direction is the horizontal component of the normal
        let horizontal = SIMD3<Float>(normal.x, 0, normal.z)
        let length = simd_length(horizontal)
        if length > 0.01 {  // Has meaningful slope
            return simd_normalize(horizontal)
        }
        return nil  // Flat floor
    }

    /// Estimate floor slope angle in degrees
    var floorSlopeAngle: Float? {
        guard let normal = calibratedFloorNormal else { return nil }
        let angleFromVertical = acos(abs(normal.y))
        return angleFromVertical * 180 / .pi
    }

    // MARK: - Auto Ceiling Detection (same logic as floor, but at highest Y with downward normal)

    /// Auto-detect ceiling from accumulated surfaces
    /// Ceiling = largest continuous surface with normal pointing mostly down, at highest Y
    func autoDetectCeiling(from vertices: [SIMD3<Float>], normals: [SIMD3<Float>], transform: simd_float4x4) -> Float? {
        // Step 1: Find all "ceiling-like" points (normal pointing mostly down)
        var ceilingCandidates: [(point: SIMD3<Float>, normal: SIMD3<Float>)] = []

        for i in 0..<min(vertices.count, normals.count) {
            let normal = normals[i]
            if normal.y < -0.5 {  // Normal points down (allows slopes up to ~60° from vertical)
                let worldPos = transform * SIMD4<Float>(vertices[i], 1.0)
                let worldPoint = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)

                // Transform normal to world space
                let worldNormal = simd_normalize(SIMD3<Float>(
                    transform.columns.0.x * normal.x + transform.columns.1.x * normal.y + transform.columns.2.x * normal.z,
                    transform.columns.0.y * normal.x + transform.columns.1.y * normal.y + transform.columns.2.y * normal.z,
                    transform.columns.0.z * normal.x + transform.columns.1.z * normal.y + transform.columns.2.z * normal.z
                ))

                ceilingCandidates.append((worldPoint, worldNormal))
            }
        }

        guard !ceilingCandidates.isEmpty else { return nil }

        // Step 2: Cluster by CONNECTIVITY (same as floor)
        let connectivityRadius: Float = 0.3
        var clusters: [[Int]] = []
        var assigned = Set<Int>()

        for i in 0..<ceilingCandidates.count {
            if assigned.contains(i) { continue }

            var cluster: [Int] = [i]
            var queue: [Int] = [i]
            assigned.insert(i)

            while !queue.isEmpty && cluster.count < 10000 {
                let current = queue.removeFirst()
                let currentPoint = ceilingCandidates[current].point

                for j in 0..<ceilingCandidates.count {
                    if assigned.contains(j) { continue }

                    let candidatePoint = ceilingCandidates[j].point
                    let dist = simd_distance(currentPoint, candidatePoint)

                    if dist < connectivityRadius {
                        cluster.append(j)
                        queue.append(j)
                        assigned.insert(j)
                    }
                }
            }

            clusters.append(cluster)
        }

        // Step 3: Find the cluster at HIGHEST Y with significant area (= ceiling)
        var bestCluster: (avgY: Float, maxY: Float, pointCount: Int, area: Float)? = nil

        for cluster in clusters {
            guard cluster.count > 50 else { continue }

            var sumY: Float = 0
            var maxY: Float = -.greatestFiniteMagnitude
            var minX: Float = .greatestFiniteMagnitude
            var maxX: Float = -.greatestFiniteMagnitude
            var minZ: Float = .greatestFiniteMagnitude
            var maxZ: Float = -.greatestFiniteMagnitude

            for idx in cluster {
                let p = ceilingCandidates[idx].point
                sumY += p.y
                maxY = max(maxY, p.y)
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
                minZ = min(minZ, p.z)
                maxZ = max(maxZ, p.z)
            }

            let avgY = sumY / Float(cluster.count)
            let area = (maxX - minX) * (maxZ - minZ)

            guard area > 0.5 else { continue }

            // Pick the cluster with HIGHEST average Y (ceiling is at top)
            if bestCluster == nil || avgY > bestCluster!.avgY {
                bestCluster = (avgY, maxY, cluster.count, area)
            }
        }

        if let ceiling = bestCluster {
            debugLog("[SurfaceClassifier] Auto-detected ceiling: avgY=\(ceiling.avgY), maxY=\(ceiling.maxY), points=\(ceiling.pointCount), area=\(ceiling.area)m²")
            return ceiling.maxY
        }

        return nil
    }

    /// Check if a point belongs to the main ceiling plane
    /// Uses density-based 1mm tolerance - only true ceiling plane points qualify
    func isPartOfCeilingPlane(point: SIMD3<Float>, normal: SIMD3<Float>) -> Bool {
        // Normal must point mostly down
        guard normal.y < -0.5 else { return false }

        if let ceilingY = calibratedCeilingHeight ?? statistics.ceilingHeight {
            // Use same 1mm tolerance as density detection
            let heightFromCeiling = abs(ceilingY - point.y)
            return heightFromCeiling < heightBinSize  // 1mm tolerance
        }

        return false
    }

    /// Ceiling slope direction
    var ceilingSlopeDirection: SIMD3<Float>? {
        guard let normal = calibratedCeilingNormal else { return nil }
        let horizontal = SIMD3<Float>(normal.x, 0, normal.z)
        let length = simd_length(horizontal)
        if length > 0.01 {
            return simd_normalize(horizontal)
        }
        return nil
    }

    /// Ceiling slope angle in degrees
    var ceilingSlopeAngle: Float? {
        guard let normal = calibratedCeilingNormal else { return nil }
        let angleFromVertical = acos(abs(normal.y))
        return angleFromVertical * 180 / .pi
    }

    // MARK: - Calibration Status

    /// Check if both floor and ceiling are calibrated (ready to measure walls)
    var isFullyCalibrated: Bool {
        return floorCalibrated && ceilingCalibrated
    }

    /// Room height based on calibrated floor/ceiling
    var calibratedRoomHeight: Float? {
        guard let floorY = calibratedFloorHeight,
              let ceilingY = calibratedCeilingHeight else { return nil }
        return ceilingY - floorY
    }

    /// Classification confidence based on calibration state
    var classificationConfidence: String {
        if isFullyCalibrated {
            return "High (floor + ceiling calibrated)"
        } else if floorCalibrated {
            return "Medium (floor only)"
        } else if ceilingCalibrated {
            return "Medium (ceiling only)"
        } else {
            return "Low (no calibration)"
        }
    }

    // MARK: - Wall Detection (farthest surface = wall, closer = object)

    /// Record wall distances from current camera position looking horizontally
    /// Call this when device is pointing horizontally to map wall positions
    func recordWallDistances(from cameraPosition: SIMD3<Float>, surfaces: [(position: SIMD3<Float>, normal: SIMD3<Float>)]) {
        // Only record when looking mostly horizontal
        guard deviceOrientation == .lookingHorizontal ||
              deviceOrientation == .lookingSlightlyUp ||
              deviceOrientation == .lookingSlightlyDown else { return }

        wallMeasurementOrigin = cameraPosition

        for surface in surfaces {
            // Only consider vertical surfaces (potential walls)
            guard abs(surface.normal.y) < 0.5 else { continue }

            // Calculate horizontal angle from camera to surface
            let dx = surface.position.x - cameraPosition.x
            let dz = surface.position.z - cameraPosition.z
            let horizontalDistance = sqrt(dx * dx + dz * dz)
            let angle = atan2(dz, dx) * 180 / .pi  // -180 to 180 degrees

            // Bucket to nearest 5 degrees
            let angleBucket = Int(round(angle / 5)) * 5

            // Track farthest distance at this angle
            if let existingDistance = wallDistanceByAngle[angleBucket] {
                wallDistanceByAngle[angleBucket] = max(existingDistance, horizontalDistance)
            } else {
                wallDistanceByAngle[angleBucket] = horizontalDistance
            }
        }

        debugLog("[SurfaceClassifier] Recorded wall distances at \(wallDistanceByAngle.count) angle buckets")
    }

    /// Record wall distances from mesh data
    func recordWallDistancesFromMesh(
        cameraPosition: SIMD3<Float>,
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        transform: simd_float4x4
    ) {
        // Only record when looking mostly horizontal
        guard deviceOrientation == .lookingHorizontal ||
              deviceOrientation == .lookingSlightlyUp ||
              deviceOrientation == .lookingSlightlyDown else { return }

        wallMeasurementOrigin = cameraPosition

        // Sample vertices to avoid processing too many
        let sampleStride = max(1, vertices.count / 500)

        for i in stride(from: 0, to: min(vertices.count, normals.count), by: sampleStride) {
            let normal = normals[i]

            // Only consider vertical surfaces (normal mostly horizontal)
            guard abs(normal.y) < 0.5 else { continue }

            // Transform to world coordinates
            let worldPos = transform * SIMD4<Float>(vertices[i], 1.0)
            let position = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)

            // Calculate horizontal angle from camera to surface
            let dx = position.x - cameraPosition.x
            let dz = position.z - cameraPosition.z
            let horizontalDistance = sqrt(dx * dx + dz * dz)

            // Skip very close surfaces (within 0.5m might be noise or the device itself)
            guard horizontalDistance > 0.5 else { continue }

            let angle = atan2(dz, dx) * 180 / .pi  // -180 to 180 degrees

            // Bucket to nearest 5 degrees
            let angleBucket = Int(round(angle / 5)) * 5

            // Track farthest distance at this angle
            if let existingDistance = wallDistanceByAngle[angleBucket] {
                wallDistanceByAngle[angleBucket] = max(existingDistance, horizontalDistance)
            } else {
                wallDistanceByAngle[angleBucket] = horizontalDistance
            }
        }
    }

    /// Classify a vertical surface as wall or object based on distance
    /// Returns true if it's at wall distance (farthest), false if it's an object (closer)
    /// Returns nil if we don't have enough data to determine
    func isWallDistance(surfacePosition: SIMD3<Float>, cameraPosition: SIMD3<Float>?) -> Bool? {
        let origin = cameraPosition ?? wallMeasurementOrigin ?? SIMD3<Float>(0, 0, 0)

        let dx = surfacePosition.x - origin.x
        let dz = surfacePosition.z - origin.z
        let horizontalDistance = sqrt(dx * dx + dz * dz)
        let angle = atan2(dz, dx) * 180 / .pi
        let angleBucket = Int(round(angle / 5)) * 5

        // Check nearby angle buckets (in case of slight angle differences)
        for bucketOffset in [-5, 0, 5] {
            let checkBucket = angleBucket + bucketOffset
            if let wallDistance = wallDistanceByAngle[checkBucket] {
                // Surface is a wall if it's at or near the farthest distance
                if horizontalDistance >= wallDistance - wallDistanceTolerance {
                    return true
                }
                // Surface is closer than wall distance = object
                return false
            }
        }

        // If we have no wall distance data, return nil (unknown)
        if wallDistanceByAngle.isEmpty {
            return nil  // Can't determine without wall data
        }

        // Check if there's any wall distance data at all for this direction
        let nearbyBuckets = (-15...15).map { angleBucket + $0 }
        let hasDataNearby = nearbyBuckets.contains { wallDistanceByAngle[$0] != nil }

        if !hasDataNearby {
            return nil  // No data for this direction
        }

        // We have data for nearby angles but this surface is closer = object
        return false
    }

    /// Classify a vertical surface as wall or object (single point, no height range)
    /// Without height range info, we can only check if point is within room bounds
    /// This is a fallback - prefer classifyVerticalSurfaceWithBounds when possible
    func classifyVerticalSurface(
        position: SIMD3<Float>,
        normal: SIMD3<Float>,
        cameraPosition: SIMD3<Float>?
    ) -> SurfaceType {
        // Must be a vertical surface
        guard abs(normal.y) < 0.5 else {
            return .unknown
        }

        // Without height range, we can't verify floor-ceiling intersection
        // Default to object - let the mesh-level classification decide
        return .object
    }

    /// Classify a vertical surface with height range (for mesh-level classification)
    /// Uses distance-based classification: farthest horizontal points = walls
    func classifyVerticalSurfaceWithBounds(
        position: SIMD3<Float>,
        normal: SIMD3<Float>,
        heightRange: (min: Float, max: Float),
        cameraPosition: SIMD3<Float>?
    ) -> SurfaceType {
        // Check if this is a vertical surface by normal direction
        let horizontalMag = sqrt(normal.x * normal.x + normal.z * normal.z)

        // Must have mostly horizontal normal to be considered a wall
        guard horizontalMag > 0.5 && abs(normal.y) < 0.7 else {
            return .object
        }

        // Calculate distance from camera for distance-based classification
        let camPos = cameraPosition ?? cameraPositions.last ?? SIMD3<Float>(0, 0, 0)
        let distanceFromCamera = simd_length(position - camPos)

        // Track max wall distance
        if distanceFromCamera > maxWallDistance {
            maxWallDistance = distanceFromCamera
        }

        // Farthest horizontal points = walls, closer = furniture/objects
        if maxWallDistance > 0 {
            if distanceFromCamera >= maxWallDistance - distanceTolerance {
                return .wall
            } else {
                return .object  // Furniture against walls
            }
        }

        // No max distance yet, assume wall
        return .wall
    }

    /// Check if a vertical surface intersects the floor plane
    func intersectsFloor(heightRange: (min: Float, max: Float)) -> Bool {
        guard let floorY = calibratedFloorHeight ?? statistics.floorHeight else {
            return false
        }
        return heightRange.min <= floorY + 0.15  // Within 15cm of floor
    }

    /// Check if a vertical surface intersects the ceiling plane
    func intersectsCeiling(heightRange: (min: Float, max: Float)) -> Bool {
        guard let ceilingY = calibratedCeilingHeight ?? statistics.ceilingHeight else {
            return false
        }
        return heightRange.max >= ceilingY - 0.15  // Within 15cm of ceiling
    }

    /// Check if a vertical surface spans from floor to ceiling (true wall)
    func spansFloorToCeiling(heightRange: (min: Float, max: Float)) -> Bool {
        return intersectsFloor(heightRange: heightRange) && intersectsCeiling(heightRange: heightRange)
    }

    /// Get the detected wall boundary at a specific angle
    func getWallDistanceAt(angleDegrees: Float) -> Float? {
        let bucket = Int(round(angleDegrees / 5)) * 5
        return wallDistanceByAngle[bucket]
    }

    /// Get all recorded wall distances (for debugging/visualization)
    var wallBoundaryPoints: [(angle: Float, distance: Float)] {
        return wallDistanceByAngle.map { (Float($0.key), $0.value) }.sorted { $0.angle < $1.angle }
    }

    /// Clear wall distance data (call when starting a new scan or changing rooms)
    func clearWallDistances() {
        wallDistanceByAngle.removeAll()
        wallMeasurementOrigin = nil
        debugLog("[SurfaceClassifier] Cleared wall distance data")
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
