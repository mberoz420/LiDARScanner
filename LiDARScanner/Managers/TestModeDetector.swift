import Foundation
import simd
import ARKit
import UIKit
import Speech
import AVFoundation

/// Test Mode: Hybrid ceiling boundary detection
/// Handles both sharp 90° corners AND rounded cove corners
class TestModeDetector: ObservableObject {

    // MARK: - Published State
    @Published var ceilingPlane: CeilingPlane?
    @Published var ceilingBoundary: [SIMD3<Float>] = []  // Final boundary points
    @Published var isPaused: Bool = false
    @Published var isListening: Bool = false
    @Published var isReceivingAudio: Bool = false
    @Published var statusMessage: String = "Point at ceiling"
    @Published var wallCount: Int = 0
    @Published var edgeCount: Int = 0
    @Published var detectionMethod: String = "Hybrid"  // Shows which method found edges

    // MARK: - Data Structures

    struct CeilingPlane {
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let y: Float  // Height of ceiling
    }

    struct WallIntersection {
        let point1: SIMD3<Float>
        let point2: SIMD3<Float>
        let direction: SIMD3<Float>  // Wall direction (horizontal)
        let confidence: Float        // 0-1, how confident we are
    }

    /// A point on the ceiling boundary with metadata
    struct BoundaryPoint {
        let position: SIMD3<Float>
        let source: DetectionSource
        let confidence: Float
        let normal: SIMD3<Float>?  // Surface normal at this point (for coves)
    }

    enum DetectionSource: String {
        case arkitPlane = "ARKit Plane"          // Sharp corner from ARPlaneAnchor
        case normalThreshold = "Normal 45°"       // Rounded cove - 45° threshold
        case meshSlice = "Height Slice"           // Horizontal slice at ceiling
        case tangentExtrapolation = "Extrapolated" // Extrapolated from flat regions
    }

    // MARK: - Internal State

    private var detectedWallIntersections: [UUID: WallIntersection] = [:]
    private var rawCeilingY: [Float] = []

    // Mesh-based detection storage
    private var meshBoundaryPoints: [BoundaryPoint] = []
    private var transitionZonePoints: [SIMD3<Float>] = []  // Points in curved cove region
    private var flatCeilingPoints: [SIMD3<Float>] = []     // Points on flat ceiling
    private var flatWallPoints: [SIMD3<Float>] = []        // Points on flat walls

    // MARK: - Configuration

    // Plane detection thresholds
    private let ceilingDetectionThreshold: Float = 0.85  // Normal Y < -0.85 for ceiling
    private let wallDetectionThreshold: Float = 0.25     // abs(Normal Y) < 0.25 for walls
    private let ceilingProximity: Float = 0.30           // 30cm proximity

    // Cove detection thresholds (for rounded corners)
    private let coveTransitionLow: Float = -0.5   // Normal.y where cove starts
    private let coveTransitionHigh: Float = -0.8  // Normal.y where ceiling starts
    private let boundaryNormalY: Float = -0.707   // 45° angle = boundary

    // Boundary building
    private let minEdgeLength: Float = 0.20       // 20cm minimum edge
    private let mergeDistance: Float = 0.15       // 15cm merge radius
    private let sliceThickness: Float = 0.05      // 5cm slice for height-based detection

    // MARK: - Voice Recognition

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var permissionGranted: Bool = false

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Frame Processing (ARKit Planes)

    /// Camera state
    private var cameraPosition: SIMD3<Float> = .zero
    private var cameraForward: SIMD3<Float> = .init(0, 0, -1)

    /// Captured boundary points
    private var capturedBoundaryPoints: [SIMD3<Float>] = []

    func processFrame(_ frame: ARFrame) {
        guard !isPaused else { return }

        // Get camera position and direction
        let transform = frame.camera.transform
        cameraPosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        cameraForward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)

        let pointingUp = cameraForward.y > 0.3

        for anchor in frame.anchors {
            guard let planeAnchor = anchor as? ARPlaneAnchor else { continue }

            let planeY = planeAnchor.transform.columns.3.y
            let planeCenter = SIMD3<Float>(
                planeAnchor.transform.columns.3.x,
                planeAnchor.transform.columns.3.y,
                planeAnchor.transform.columns.3.z
            )
            let normal = SIMD3<Float>(
                planeAnchor.transform.columns.1.x,
                planeAnchor.transform.columns.1.y,
                planeAnchor.transform.columns.1.z
            )

            // STEP 1: Detect ceiling and extract ITS boundary directly
            if (planeAnchor.classification == .ceiling || normal.y < -0.7) &&
               planeY > cameraPosition.y + 0.3 {

                rawCeilingY.append(planeY)
                if rawCeilingY.count > 10 { rawCeilingY.removeFirst() }
                let medianY = rawCeilingY.sorted()[rawCeilingY.count / 2]

                let wasNil = ceilingPlane == nil
                ceilingPlane = CeilingPlane(
                    center: planeCenter,
                    normal: SIMD3<Float>(0, -1, 0),
                    y: medianY
                )

                if wasNil { hapticFeedback() }

                // Extract ceiling's own boundary vertices from ARKit
                let geometry = planeAnchor.geometry
                let vertices = geometry.boundaryVertices

                // Transform boundary vertices to world space
                for vertex in vertices {
                    let localPos = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
                    let worldPos = planeAnchor.transform * localPos
                    let boundaryPoint = SIMD3<Float>(worldPos.x, medianY, worldPos.z)
                    addBoundaryPoint(boundaryPoint)
                }
            }

            // Ceiling boundary is extracted directly from ceiling plane above
            // No need for wall-based detection - ARKit provides the boundary
        }

        // Build boundary from captured points
        buildCeilingBoundaryFromPoints()
        updateStatus()
    }

    /// Add a boundary point (with duplicate filtering)
    private func addBoundaryPoint(_ point: SIMD3<Float>) {
        // Check if too close to existing point
        for i in 0..<capturedBoundaryPoints.count {
            let existing = capturedBoundaryPoints[i]
            if simd_distance(existing, point) < 0.25 {  // 25cm threshold
                // Average with existing point for better accuracy
                capturedBoundaryPoints[i] = (existing + point) / 2
                return
            }
        }

        capturedBoundaryPoints.append(point)
        wallCount = capturedBoundaryPoints.count
        hapticFeedback()
    }

    /// Build boundary from captured points
    private func buildCeilingBoundaryFromPoints() {
        guard capturedBoundaryPoints.count >= 3 else {
            ceilingBoundary = capturedBoundaryPoints
            edgeCount = capturedBoundaryPoints.count
            return
        }

        // Order points clockwise to form a closed boundary
        let ordered = orderPointsClockwise(capturedBoundaryPoints)
        ceilingBoundary = ordered
        edgeCount = ordered.count
    }

    // MARK: - Mesh Processing (Raw LiDAR Data)

    /// Process raw mesh data for cove detection
    /// Call this from MeshManager when mesh updates
    func processMesh(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        transform: simd_float4x4
    ) {
        guard !isPaused, let ceiling = ceilingPlane else { return }

        // Transform vertices to world space
        for i in 0..<min(vertices.count, normals.count) {
            let localPos = vertices[i]
            let worldPos4 = transform * SIMD4<Float>(localPos.x, localPos.y, localPos.z, 1)
            let worldPos = SIMD3<Float>(worldPos4.x, worldPos4.y, worldPos4.z)

            // Transform normal to world space (rotation only)
            let localNormal = normals[i]
            let worldNormal4 = transform * SIMD4<Float>(localNormal.x, localNormal.y, localNormal.z, 0)
            let worldNormal = simd_normalize(SIMD3<Float>(worldNormal4.x, worldNormal4.y, worldNormal4.z))

            // Only process points near ceiling height
            let distanceToCeiling = abs(worldPos.y - ceiling.y)
            guard distanceToCeiling < ceilingProximity else { continue }

            // Classify by normal direction
            if worldNormal.y < coveTransitionHigh {
                // This is flat ceiling
                flatCeilingPoints.append(worldPos)
            } else if abs(worldNormal.y) < wallDetectionThreshold {
                // This is flat wall
                flatWallPoints.append(worldPos)
            } else if worldNormal.y < coveTransitionLow && worldNormal.y > coveTransitionHigh {
                // This is transition zone (cove)
                transitionZonePoints.append(worldPos)

                // Method 2: 45° Normal Threshold Crossing
                // Points where normal.y ≈ -0.707 are the "effective" boundary
                if abs(worldNormal.y - boundaryNormalY) < 0.1 {
                    let boundaryPoint = BoundaryPoint(
                        position: worldPos,
                        source: .normalThreshold,
                        confidence: 1.0 - abs(worldNormal.y - boundaryNormalY) / 0.1,
                        normal: worldNormal
                    )
                    meshBoundaryPoints.append(boundaryPoint)
                }
            }
        }

        // Limit storage
        if flatCeilingPoints.count > 5000 { flatCeilingPoints.removeFirst(1000) }
        if flatWallPoints.count > 5000 { flatWallPoints.removeFirst(1000) }
        if transitionZonePoints.count > 2000 { transitionZonePoints.removeFirst(500) }
        if meshBoundaryPoints.count > 1000 { meshBoundaryPoints.removeFirst(200) }
    }

    // MARK: - ARKit Plane Processing

    private func processPlaneAnchor(_ anchor: ARPlaneAnchor) {
        let transform = anchor.transform
        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let normal = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)

        // Detect ceiling
        if anchor.classification == .ceiling || normal.y < -ceilingDetectionThreshold {
            rawCeilingY.append(center.y)
            if rawCeilingY.count > 20 { rawCeilingY.removeFirst() }

            let sortedY = rawCeilingY.sorted()
            let medianY = sortedY[sortedY.count / 2]

            let wasNil = ceilingPlane == nil
            ceilingPlane = CeilingPlane(
                center: SIMD3<Float>(center.x, medianY, center.z),
                normal: SIMD3<Float>(0, -1, 0),
                y: medianY
            )

            if wasNil { hapticFeedback() }
        }
        // Detect walls near ceiling
        else if anchor.classification == .wall || abs(normal.y) < wallDetectionThreshold {
            guard let ceiling = ceilingPlane else { return }

            let wallTopY = center.y + (anchor.planeExtent.height / 2)
            let distanceToCeiling = abs(wallTopY - ceiling.y)

            if distanceToCeiling <= ceilingProximity {
                if let intersection = calculateWallCeilingIntersection(
                    wallCenter: center,
                    wallNormal: normal,
                    wallExtent: anchor.planeExtent,
                    ceilingY: ceiling.y
                ) {
                    let isNew = detectedWallIntersections[anchor.identifier] == nil
                    detectedWallIntersections[anchor.identifier] = intersection
                    if isNew { hapticFeedback() }
                }
            }
        }

        wallCount = detectedWallIntersections.count
    }

    private func calculateWallCeilingIntersection(
        wallCenter: SIMD3<Float>,
        wallNormal: SIMD3<Float>,
        wallExtent: ARPlaneExtent,
        ceilingY: Float
    ) -> WallIntersection? {
        let wallDirection = simd_normalize(SIMD3<Float>(-wallNormal.z, 0, wallNormal.x))
        let halfWidth = wallExtent.width / 2
        let intersectionCenter = SIMD3<Float>(wallCenter.x, ceilingY, wallCenter.z)

        let point1 = intersectionCenter - wallDirection * halfWidth
        let point2 = intersectionCenter + wallDirection * halfWidth

        let length = simd_distance(point1, point2)
        guard length >= minEdgeLength else { return nil }

        return WallIntersection(
            point1: point1,
            point2: point2,
            direction: wallDirection,
            confidence: min(1.0, length / 1.0)  // Higher confidence for longer edges
        )
    }

    // MARK: - Hybrid Boundary Building

    private func buildHybridCeilingBoundary() {
        var allBoundaryPoints: [BoundaryPoint] = []

        // Source 1: ARKit plane intersections (highest priority for sharp corners)
        for (_, intersection) in detectedWallIntersections {
            allBoundaryPoints.append(BoundaryPoint(
                position: intersection.point1,
                source: .arkitPlane,
                confidence: intersection.confidence,
                normal: nil
            ))
            allBoundaryPoints.append(BoundaryPoint(
                position: intersection.point2,
                source: .arkitPlane,
                confidence: intersection.confidence,
                normal: nil
            ))
        }

        // Source 2: Mesh-based 45° threshold points (for coves)
        allBoundaryPoints.append(contentsOf: meshBoundaryPoints)

        // Source 3: Height slice (fallback) - if we have few points
        if allBoundaryPoints.count < 4 && !transitionZonePoints.isEmpty {
            let slicePoints = extractHeightSlice()
            for pos in slicePoints {
                allBoundaryPoints.append(BoundaryPoint(
                    position: pos,
                    source: .meshSlice,
                    confidence: 0.7,
                    normal: nil
                ))
            }
        }

        // Source 4: Tangent extrapolation (if we have flat regions but gaps)
        if allBoundaryPoints.count >= 2 && hasGapsInBoundary(allBoundaryPoints) {
            let extrapolated = extrapolateTangentIntersections()
            for pos in extrapolated {
                allBoundaryPoints.append(BoundaryPoint(
                    position: pos,
                    source: .tangentExtrapolation,
                    confidence: 0.6,
                    normal: nil
                ))
            }
        }

        // Convert to positions
        var positions = allBoundaryPoints.map { $0.position }

        // Merge nearby points (weighted by confidence)
        positions = mergeNearbyPoints(positions)

        // Order clockwise
        positions = orderPointsClockwise(positions)

        // Optional: Simplify using Douglas-Peucker
        if positions.count > 8 {
            positions = douglasPeuckerSimplify(positions, epsilon: 0.1)
        }

        ceilingBoundary = positions
        edgeCount = positions.count

        // Update detection method indicator
        updateDetectionMethod(allBoundaryPoints)
    }

    // MARK: - Detection Methods

    /// Method 3: Height-based slice - extract perimeter at ceiling height
    private func extractHeightSlice() -> [SIMD3<Float>] {
        guard let ceiling = ceilingPlane else { return [] }

        // Collect all points within slice thickness of ceiling
        let sliceY = ceiling.y - sliceThickness
        var slicePoints: [SIMD3<Float>] = []

        for point in transitionZonePoints {
            if abs(point.y - sliceY) < sliceThickness {
                slicePoints.append(SIMD3<Float>(point.x, ceiling.y, point.z))
            }
        }

        // Find convex hull of slice points (XZ plane)
        return convexHull2D(slicePoints)
    }

    /// Method 4: Extrapolate where flat ceiling and flat wall planes would intersect
    private func extrapolateTangentIntersections() -> [SIMD3<Float>] {
        guard let ceiling = ceilingPlane else { return [] }
        guard flatCeilingPoints.count > 10 && flatWallPoints.count > 10 else { return [] }

        var extrapolatedPoints: [SIMD3<Float>] = []

        // Fit plane to flat ceiling points (should confirm our ceiling.y)
        // Cluster wall points by direction and fit planes
        let wallClusters = clusterByDirection(flatWallPoints)

        for cluster in wallClusters {
            guard cluster.count > 5 else { continue }

            // Fit plane to wall cluster using RANSAC-lite
            if let wallPlane = fitPlaneRANSAC(cluster) {
                // Calculate intersection line between wall plane and ceiling plane
                if let intersection = intersectPlanes(
                    ceilingNormal: SIMD3<Float>(0, -1, 0),
                    ceilingPoint: SIMD3<Float>(0, ceiling.y, 0),
                    wallNormal: wallPlane.normal,
                    wallPoint: wallPlane.point
                ) {
                    // Project intersection points to boundary
                    extrapolatedPoints.append(intersection)
                }
            }
        }

        return extrapolatedPoints
    }

    // MARK: - Helper Algorithms

    /// Cluster points by their horizontal direction from centroid
    private func clusterByDirection(_ points: [SIMD3<Float>]) -> [[SIMD3<Float>]] {
        guard points.count > 2 else { return [points] }

        // Calculate centroid
        var centroid = SIMD3<Float>(0, 0, 0)
        for p in points { centroid += p }
        centroid /= Float(points.count)

        // Group by angle sectors (8 directions)
        var sectors: [[SIMD3<Float>]] = Array(repeating: [], count: 8)

        for point in points {
            let dx = point.x - centroid.x
            let dz = point.z - centroid.z
            let angle = atan2(dz, dx)  // -π to π
            let sector = Int((angle + .pi) / (.pi / 4)) % 8
            sectors[sector].append(point)
        }

        return sectors.filter { $0.count >= 3 }
    }

    /// Simple RANSAC plane fitting
    private func fitPlaneRANSAC(_ points: [SIMD3<Float>]) -> (normal: SIMD3<Float>, point: SIMD3<Float>)? {
        guard points.count >= 3 else { return nil }

        // For simplicity, use least-squares instead of full RANSAC
        // Calculate centroid
        var centroid = SIMD3<Float>(0, 0, 0)
        for p in points { centroid += p }
        centroid /= Float(points.count)

        // Use first 3 points to estimate normal
        let p0 = points[0]
        let p1 = points[min(1, points.count - 1)]
        let p2 = points[min(2, points.count - 1)]

        let v1 = p1 - p0
        let v2 = p2 - p0
        var normal = simd_cross(v1, v2)

        if simd_length(normal) < 0.001 { return nil }
        normal = simd_normalize(normal)

        return (normal: normal, point: centroid)
    }

    /// Calculate intersection point of two planes
    private func intersectPlanes(
        ceilingNormal: SIMD3<Float>,
        ceilingPoint: SIMD3<Float>,
        wallNormal: SIMD3<Float>,
        wallPoint: SIMD3<Float>
    ) -> SIMD3<Float>? {
        // Line direction is perpendicular to both normals
        let lineDir = simd_cross(ceilingNormal, wallNormal)
        guard simd_length(lineDir) > 0.001 else { return nil }

        // Find a point on the intersection line
        // Using the formula for plane-plane intersection
        let d1 = -simd_dot(ceilingNormal, ceilingPoint)
        let d2 = -simd_dot(wallNormal, wallPoint)

        // Solve for a point (use X=0 or Z=0 depending on line direction)
        if abs(lineDir.x) > abs(lineDir.z) {
            // Solve with z = 0
            let denom = ceilingNormal.x * wallNormal.y - ceilingNormal.y * wallNormal.x
            guard abs(denom) > 0.001 else { return nil }

            let x = (ceilingNormal.y * d2 - wallNormal.y * d1) / denom
            let y = (wallNormal.x * d1 - ceilingNormal.x * d2) / denom
            return SIMD3<Float>(x, y, 0)
        } else {
            // Solve with x = 0
            let denom = ceilingNormal.z * wallNormal.y - ceilingNormal.y * wallNormal.z
            guard abs(denom) > 0.001 else { return nil }

            let z = (ceilingNormal.y * d2 - wallNormal.y * d1) / denom
            let y = (wallNormal.z * d1 - ceilingNormal.z * d2) / denom
            return SIMD3<Float>(0, y, z)
        }
    }

    /// 2D Convex Hull (XZ plane)
    private func convexHull2D(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }

        // Sort by X, then by Z
        let sorted = points.sorted { ($0.x, $0.z) < ($1.x, $1.z) }

        // Build lower hull
        var lower: [SIMD3<Float>] = []
        for point in sorted {
            while lower.count >= 2 && cross2D(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        // Build upper hull
        var upper: [SIMD3<Float>] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross2D(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }

        // Concatenate (remove duplicates)
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private func cross2D(_ o: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
    }

    /// Douglas-Peucker line simplification
    private func douglasPeuckerSimplify(_ points: [SIMD3<Float>], epsilon: Float) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }

        // Find point with max distance from line between first and last
        var maxDist: Float = 0
        var maxIndex = 0

        let first = points[0]
        let last = points[points.count - 1]

        for i in 1..<(points.count - 1) {
            let dist = perpendicularDistance(points[i], lineStart: first, lineEnd: last)
            if dist > maxDist {
                maxDist = dist
                maxIndex = i
            }
        }

        // If max distance > epsilon, recursively simplify
        if maxDist > epsilon {
            let left = douglasPeuckerSimplify(Array(points[0...maxIndex]), epsilon: epsilon)
            let right = douglasPeuckerSimplify(Array(points[maxIndex...]), epsilon: epsilon)

            // Concatenate (remove duplicate at split point)
            return Array(left.dropLast()) + right
        } else {
            return [first, last]
        }
    }

    private func perpendicularDistance(_ point: SIMD3<Float>, lineStart: SIMD3<Float>, lineEnd: SIMD3<Float>) -> Float {
        let dx = lineEnd.x - lineStart.x
        let dz = lineEnd.z - lineStart.z
        let lineLengthSq = dx * dx + dz * dz

        if lineLengthSq < 0.001 {
            return simd_distance(point, lineStart)
        }

        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.z - lineStart.z) * dz) / lineLengthSq))
        let projection = SIMD3<Float>(lineStart.x + t * dx, point.y, lineStart.z + t * dz)
        return simd_distance(point, projection)
    }

    /// Check if boundary has gaps (large angles between consecutive points)
    private func hasGapsInBoundary(_ points: [BoundaryPoint]) -> Bool {
        guard points.count >= 3 else { return true }

        let positions = orderPointsClockwise(points.map { $0.position })
        guard positions.count >= 3 else { return true }

        // Find centroid
        var centroid = SIMD3<Float>(0, 0, 0)
        for p in positions { centroid += p }
        centroid /= Float(positions.count)

        // Check angle gaps
        var angles: [Float] = []
        for p in positions {
            angles.append(atan2(p.z - centroid.z, p.x - centroid.x))
        }
        angles.sort()

        // Check for large gaps (> 90°)
        for i in 0..<angles.count {
            let nextI = (i + 1) % angles.count
            var gap = angles[nextI] - angles[i]
            if gap < 0 { gap += 2 * .pi }
            if gap > .pi / 2 { return true }
        }

        return false
    }

    private func updateDetectionMethod(_ points: [BoundaryPoint]) {
        var sources: Set<String> = []
        for p in points {
            sources.insert(p.source.rawValue)
        }
        detectionMethod = sources.joined(separator: " + ")
    }

    // MARK: - Point Processing

    private func mergeNearbyPoints(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []

        for point in points {
            var merged = false
            for i in 0..<result.count {
                if simd_distance(result[i], point) < mergeDistance {
                    result[i] = (result[i] + point) / 2.0
                    merged = true
                    break
                }
            }
            if !merged {
                result.append(point)
            }
        }

        return result
    }

    private func orderPointsClockwise(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }

        var centroid = SIMD3<Float>(0, 0, 0)
        for p in points { centroid += p }
        centroid /= Float(points.count)

        return points.sorted { p1, p2 in
            let angle1 = atan2(p1.z - centroid.z, p1.x - centroid.x)
            let angle2 = atan2(p2.z - centroid.z, p2.x - centroid.x)
            return angle1 < angle2
        }
    }

    // MARK: - Voice Control

    func startListening() {
        // Check current permission status first (non-blocking)
        let audioSession = AVAudioSession.sharedInstance()

        // Check if we already have permission
        switch audioSession.recordPermission {
        case .granted:
            // Already have mic permission, check speech
            checkSpeechPermissionAndStart()
        case .denied:
            DispatchQueue.main.async {
                self.statusMessage = "Mic denied - check Settings"
            }
        case .undetermined:
            // Request permission
            audioSession.requestRecordPermission { [weak self] micGranted in
                DispatchQueue.main.async {
                    if micGranted {
                        self?.checkSpeechPermissionAndStart()
                    } else {
                        self?.statusMessage = "Mic not authorized"
                    }
                }
            }
        @unknown default:
            break
        }
    }

    private func checkSpeechPermissionAndStart() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            permissionGranted = true
            startAudioEngine()
        case .denied, .restricted:
            statusMessage = "Speech denied - check Settings"
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        self?.permissionGranted = true
                        self?.startAudioEngine()
                    } else {
                        self?.statusMessage = "Voice not authorized"
                    }
                }
            }
        @unknown default:
            break
        }
    }

    private func startAudioEngine() {
        // Safety: stop any existing engine first
        stopAudioEngine()

        // Verify permissions and availability
        guard permissionGranted else {
            print("[TestMode] Audio engine: permission not granted")
            return
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("[TestMode] Audio engine: speech recognizer not available")
            DispatchQueue.main.async {
                self.statusMessage = "Speech not available"
            }
            return
        }

        do {
            // Configure audio session with error handling
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // Create new audio engine
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else {
                print("[TestMode] Audio engine: failed to create engine")
                return
            }

            // Create recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                print("[TestMode] Audio engine: failed to create request")
                return
            }
            recognitionRequest.shouldReportPartialResults = true

            // Validate audio format
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                print("[TestMode] Audio engine: invalid format - rate=\(recordingFormat.sampleRate) channels=\(recordingFormat.channelCount)")
                DispatchQueue.main.async {
                    self.statusMessage = "Audio format error"
                }
                return
            }

            // Install audio tap
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                self?.checkAudioLevel(buffer: buffer)
            }

            // Start engine
            audioEngine.prepare()
            try audioEngine.start()

            DispatchQueue.main.async {
                self.isListening = true
            }

            // Start recognition task
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                if let result = result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    DispatchQueue.main.async {
                        self?.processVoiceCommand(text)
                    }
                }

                if error != nil || (result?.isFinal ?? false) {
                    // Restart after brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self, self.isListening else { return }
                        self.startAudioEngine()
                    }
                }
            }

            print("[TestMode] Audio engine started successfully")

        } catch {
            print("[TestMode] Audio engine error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isListening = false
                self.statusMessage = "Audio error"
            }
        }
    }

    private func checkAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength { sum += abs(channelData[i]) }
        let average = sum / Float(frameLength)

        DispatchQueue.main.async { [weak self] in
            self?.isReceivingAudio = average > 0.01
        }
    }

    private func processVoiceCommand(_ text: String) {
        let words = text.lowercased().components(separatedBy: " ")
        guard let lastWord = words.last else { return }

        if lastWord.contains("pause") || lastWord.contains("stop") || lastWord.contains("wait") {
            if !isPaused {
                isPaused = true
                hapticFeedback()
                updateStatus()
            }
        } else if lastWord.contains("go") || lastWord.contains("continue") || lastWord.contains("start") || lastWord.contains("resume") {
            if isPaused {
                isPaused = false
                hapticFeedback()
                updateStatus()
            }
        }
    }

    private func stopAudioEngine() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
    }

    func stopListening() {
        stopAudioEngine()
        isListening = false
        isReceivingAudio = false
    }

    func togglePause() {
        isPaused.toggle()
        updateStatus()
        hapticFeedback()
    }

    private func hapticFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func updateStatus() {
        if isPaused {
            statusMessage = "PAUSED"
        } else if ceilingPlane == nil {
            statusMessage = "Point UP at ceiling"
        } else if capturedBoundaryPoints.isEmpty {
            statusMessage = "Scan ceiling edges - \(String(format: "%.1fm", ceilingPlane!.y)) high"
        } else {
            statusMessage = "\(capturedBoundaryPoints.count) boundary points"
        }
    }

    func reset() {
        stopListening()
        ceilingPlane = nil
        ceilingBoundary = []
        capturedBoundaryPoints = []
        detectedWallIntersections = [:]
        rawCeilingY = []
        isPaused = false
        wallCount = 0
        edgeCount = 0
        statusMessage = "Point UP at ceiling"
        detectionMethod = "Ray-Plane"
    }
}
