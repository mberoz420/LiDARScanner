import Foundation
import CoreML
import simd
import Accelerate

/// Extracts architectural elements (walls, floor, ceiling) from organic scans
/// Uses geometric analysis as foundation, designed to be enhanced with Core ML model
@MainActor
class ArchitecturalExtractor: ObservableObject {

    // MARK: - Published State

    @Published var isProcessing = false
    @Published var progress: Float = 0
    @Published var statusMessage = ""

    // Extracted elements
    @Published var extractedFloor: ExtractedSurface?
    @Published var extractedCeiling: ExtractedSurface?
    @Published var extractedWalls: [ExtractedSurface] = []
    @Published var extractedObjects: [ExtractedObject] = []

    // MARK: - Data Structures

    /// A classified surface extracted from the scan
    struct ExtractedSurface: Identifiable {
        let id = UUID()
        let type: SurfaceCategory
        let vertices: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let faces: [[UInt32]]
        let plane: PlaneEquation
        let area: Float
        let confidence: Float  // 0-1, how confident the classification is
    }

    /// A detected object (non-architectural element)
    struct ExtractedObject: Identifiable {
        let id = UUID()
        let category: ObjectCategory
        let boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
        let vertices: [SIMD3<Float>]
        let confidence: Float
    }

    enum SurfaceCategory: String, CaseIterable {
        case floor = "Floor"
        case ceiling = "Ceiling"
        case wall = "Wall"
        case unknown = "Unknown"
    }

    enum ObjectCategory: String, CaseIterable {
        case furniture = "Furniture"
        case appliance = "Appliance"
        case clutter = "Clutter"
        case unknown = "Unknown"
    }

    struct PlaneEquation {
        let point: SIMD3<Float>   // Point on plane
        let normal: SIMD3<Float>  // Unit normal
        let d: Float              // Distance from origin

        init(point: SIMD3<Float>, normal: SIMD3<Float>) {
            self.point = point
            self.normal = simd_normalize(normal)
            self.d = -simd_dot(self.normal, point)
        }

        func distance(to point: SIMD3<Float>) -> Float {
            return abs(simd_dot(normal, point) + d)
        }
    }

    // MARK: - ML Model (placeholder for future Core ML integration)

    /// Core ML model for semantic segmentation (nil = use geometric heuristics)
    private var segmentationModel: MLModel?

    // MARK: - Configuration

    struct Config {
        // Plane detection
        var planeDistanceThreshold: Float = 0.05  // 5cm tolerance for plane membership
        var minPlaneArea: Float = 0.5             // Minimum 0.5 m² to be considered
        var minPlanePoints: Int = 100             // Minimum points for a plane

        // Classification thresholds
        var floorNormalThreshold: Float = 0.9     // Normal.y > 0.9 = floor
        var ceilingNormalThreshold: Float = -0.9  // Normal.y < -0.9 = ceiling
        var wallNormalThreshold: Float = 0.3      // |Normal.y| < 0.3 = wall

        // Room bounds estimation
        var heightPercentileFloor: Float = 0.05   // Bottom 5% of Y = floor level
        var heightPercentileCeiling: Float = 0.95 // Top 5% of Y = ceiling level

        // Object detection
        var minObjectVolume: Float = 0.01         // Minimum 0.01 m³
        var maxObjectVolume: Float = 10.0         // Maximum 10 m³ (larger = architecture)
    }

    var config = Config()

    // MARK: - Main Processing

    /// Process an organic scan and extract architectural elements
    func processOrganicScan(_ scan: CapturedScan) async -> ExtractionResult {
        isProcessing = true
        progress = 0
        statusMessage = "Preparing scan data..."

        // Reset previous results
        extractedFloor = nil
        extractedCeiling = nil
        extractedWalls = []
        extractedObjects = []

        // Step 1: Collect all vertices and normals from meshes
        statusMessage = "Collecting geometry..."
        progress = 0.1

        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allFaces: [[UInt32]] = []
        var vertexOffset: UInt32 = 0

        for mesh in scan.meshes {
            // Transform vertices to world space
            for vertex in mesh.vertices {
                let worldPos = mesh.transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
                allVertices.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
            }

            // Transform normals to world space (rotation only)
            for normal in mesh.normals {
                let worldNormal = mesh.transform * SIMD4<Float>(normal.x, normal.y, normal.z, 0)
                allNormals.append(simd_normalize(SIMD3<Float>(worldNormal.x, worldNormal.y, worldNormal.z)))
            }

            // Offset face indices
            for face in mesh.faces {
                allFaces.append(face.map { $0 + vertexOffset })
            }
            vertexOffset += UInt32(mesh.vertices.count)
        }

        guard !allVertices.isEmpty else {
            isProcessing = false
            return ExtractionResult(success: false, message: "No geometry found in scan")
        }

        // Step 2: Estimate room bounds
        statusMessage = "Estimating room bounds..."
        progress = 0.2

        let roomBounds = estimateRoomBounds(vertices: allVertices)

        // Step 3: Classify vertices using ML or heuristics
        statusMessage = "Classifying surfaces..."
        progress = 0.3

        let classifications: [SurfaceCategory]
        if let model = segmentationModel {
            // Use Core ML model
            classifications = await classifyWithML(
                vertices: allVertices,
                normals: allNormals,
                model: model
            )
        } else {
            // Use geometric heuristics
            classifications = classifyGeometric(
                vertices: allVertices,
                normals: allNormals,
                roomBounds: roomBounds
            )
        }

        progress = 0.5

        // Step 4: Extract planes using RANSAC
        statusMessage = "Detecting planes..."
        progress = 0.6

        let planes = detectPlanes(
            vertices: allVertices,
            normals: allNormals,
            classifications: classifications
        )

        // Step 5: Build extracted surfaces
        statusMessage = "Building surfaces..."
        progress = 0.8

        buildExtractedSurfaces(
            planes: planes,
            vertices: allVertices,
            normals: allNormals,
            faces: allFaces,
            roomBounds: roomBounds
        )

        // Step 6: Identify objects (non-architectural elements)
        statusMessage = "Identifying objects..."
        progress = 0.9

        identifyObjects(
            vertices: allVertices,
            classifications: classifications,
            roomBounds: roomBounds
        )

        statusMessage = "Complete!"
        progress = 1.0
        isProcessing = false

        let wallCount = extractedWalls.count
        let objectCount = extractedObjects.count

        return ExtractionResult(
            success: true,
            message: "Extracted: 1 floor, 1 ceiling, \(wallCount) walls, \(objectCount) objects"
        )
    }

    struct ExtractionResult {
        let success: Bool
        let message: String
    }

    // MARK: - Room Bounds Estimation

    private func estimateRoomBounds(vertices: [SIMD3<Float>]) -> RoomBounds {
        guard !vertices.isEmpty else {
            return RoomBounds(
                minY: 0, maxY: 2.5,
                floorY: 0, ceilingY: 2.5,
                minX: -5, maxX: 5,
                minZ: -5, maxZ: 5
            )
        }

        // Sort Y values to find floor/ceiling
        let yValues = vertices.map { $0.y }.sorted()
        let floorIndex = Int(Float(yValues.count) * config.heightPercentileFloor)
        let ceilingIndex = Int(Float(yValues.count) * config.heightPercentileCeiling)

        let floorY = yValues[max(0, floorIndex)]
        let ceilingY = yValues[min(yValues.count - 1, ceilingIndex)]

        // Get XZ bounds
        let xValues = vertices.map { $0.x }
        let zValues = vertices.map { $0.z }

        return RoomBounds(
            minY: yValues.first ?? 0,
            maxY: yValues.last ?? 2.5,
            floorY: floorY,
            ceilingY: ceilingY,
            minX: xValues.min() ?? -5,
            maxX: xValues.max() ?? 5,
            minZ: zValues.min() ?? -5,
            maxZ: zValues.max() ?? 5
        )
    }

    struct RoomBounds {
        let minY, maxY: Float
        let floorY, ceilingY: Float
        let minX, maxX: Float
        let minZ, maxZ: Float

        var roomHeight: Float { ceilingY - floorY }
        var roomWidth: Float { maxX - minX }
        var roomDepth: Float { maxZ - minZ }
    }

    // MARK: - Geometric Classification (Heuristic Fallback)

    private func classifyGeometric(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        roomBounds: RoomBounds
    ) -> [SurfaceCategory] {

        var classifications: [SurfaceCategory] = []

        for i in 0..<vertices.count {
            let vertex = vertices[i]
            let normal = i < normals.count ? normals[i] : SIMD3<Float>(0, 1, 0)

            let classification = classifyPoint(
                vertex: vertex,
                normal: normal,
                roomBounds: roomBounds
            )
            classifications.append(classification)
        }

        return classifications
    }

    private func classifyPoint(
        vertex: SIMD3<Float>,
        normal: SIMD3<Float>,
        roomBounds: RoomBounds
    ) -> SurfaceCategory {

        let normalY = normal.y
        let vertexY = vertex.y

        // Floor: pointing up + near floor level
        if normalY > config.floorNormalThreshold {
            if abs(vertexY - roomBounds.floorY) < 0.3 {
                return .floor
            }
        }

        // Ceiling: pointing down + near ceiling level
        if normalY < config.ceilingNormalThreshold {
            if abs(vertexY - roomBounds.ceilingY) < 0.3 {
                return .ceiling
            }
        }

        // Wall: horizontal normal + spans significant height
        if abs(normalY) < config.wallNormalThreshold {
            // Check if it's near room boundaries (not a cabinet in the middle)
            let distFromXBounds = min(
                abs(vertex.x - roomBounds.minX),
                abs(vertex.x - roomBounds.maxX)
            )
            let distFromZBounds = min(
                abs(vertex.z - roomBounds.minZ),
                abs(vertex.z - roomBounds.maxZ)
            )

            // If close to room boundaries, likely a wall
            if distFromXBounds < 0.5 || distFromZBounds < 0.5 {
                return .wall
            }

            // If it spans most of the room height, also likely a wall
            if vertexY > roomBounds.floorY + 0.3 && vertexY < roomBounds.ceilingY - 0.3 {
                // Could be a wall or furniture - needs more context
                // For now, classify as unknown (will be object)
            }
        }

        return .unknown
    }

    // MARK: - Core ML Classification

    private func classifyWithML(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        model: MLModel
    ) async -> [SurfaceCategory] {
        // Use the ML model for classification
        return await classifyWithMLModel(vertices: vertices, normals: normals, model: model)
    }

    // MARK: - RANSAC Plane Detection

    private func detectPlanes(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        classifications: [SurfaceCategory]
    ) -> [DetectedPlane] {

        var planes: [DetectedPlane] = []

        // Detect planes for each category separately
        for category in [SurfaceCategory.floor, .ceiling, .wall] {
            let categoryIndices = classifications.enumerated()
                .filter { $0.element == category }
                .map { $0.offset }

            guard categoryIndices.count >= config.minPlanePoints else { continue }

            let categoryVertices = categoryIndices.map { vertices[$0] }
            let categoryNormals = categoryIndices.map { normals[$0] }

            // Run RANSAC to find dominant plane(s)
            let detectedPlanes = ransacPlaneDetection(
                vertices: categoryVertices,
                normals: categoryNormals,
                category: category
            )

            planes.append(contentsOf: detectedPlanes)
        }

        return planes
    }

    struct DetectedPlane {
        let plane: PlaneEquation
        let category: SurfaceCategory
        let inlierIndices: [Int]
        let confidence: Float
    }

    private func ransacPlaneDetection(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        category: SurfaceCategory
    ) -> [DetectedPlane] {

        guard vertices.count >= 3 else { return [] }

        var detectedPlanes: [DetectedPlane] = []
        var remainingIndices = Set(0..<vertices.count)
        let iterations = 100

        // Find multiple planes (for walls, we might have 4+)
        let maxPlanes = category == .wall ? 10 : 1

        for _ in 0..<maxPlanes {
            guard remainingIndices.count >= config.minPlanePoints else { break }

            var bestPlane: PlaneEquation?
            var bestInliers: [Int] = []

            // RANSAC iterations
            for _ in 0..<iterations {
                // Random sample 3 points
                let sample = Array(remainingIndices.shuffled().prefix(3))
                guard sample.count == 3 else { continue }

                let p0 = vertices[sample[0]]
                let p1 = vertices[sample[1]]
                let p2 = vertices[sample[2]]

                // Compute plane from 3 points
                let v1 = p1 - p0
                let v2 = p2 - p0
                var normal = simd_cross(v1, v2)
                let normalLength = simd_length(normal)

                guard normalLength > 0.001 else { continue }
                normal = normal / normalLength

                let plane = PlaneEquation(point: p0, normal: normal)

                // Count inliers
                var inliers: [Int] = []
                for idx in remainingIndices {
                    let dist = plane.distance(to: vertices[idx])
                    if dist < config.planeDistanceThreshold {
                        inliers.append(idx)
                    }
                }

                if inliers.count > bestInliers.count {
                    bestInliers = inliers
                    bestPlane = plane
                }
            }

            // Accept plane if enough inliers
            if let plane = bestPlane, bestInliers.count >= config.minPlanePoints {
                let confidence = Float(bestInliers.count) / Float(vertices.count)

                detectedPlanes.append(DetectedPlane(
                    plane: plane,
                    category: category,
                    inlierIndices: bestInliers,
                    confidence: confidence
                ))

                // Remove inliers from remaining points
                for idx in bestInliers {
                    remainingIndices.remove(idx)
                }
            } else {
                break  // No more planes found
            }
        }

        return detectedPlanes
    }

    // MARK: - Build Extracted Surfaces

    private func buildExtractedSurfaces(
        planes: [DetectedPlane],
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        faces: [[UInt32]],
        roomBounds: RoomBounds
    ) {
        for plane in planes {
            let surfaceVertices = plane.inlierIndices.map { vertices[$0] }
            let surfaceNormals = plane.inlierIndices.map { normals[$0] }

            // Calculate area (approximate from bounding box)
            let xRange = surfaceVertices.map { $0.x }
            let yRange = surfaceVertices.map { $0.y }
            let zRange = surfaceVertices.map { $0.z }

            let width = (xRange.max() ?? 0) - (xRange.min() ?? 0)
            let height = (yRange.max() ?? 0) - (yRange.min() ?? 0)
            let depth = (zRange.max() ?? 0) - (zRange.min() ?? 0)

            // Area depends on orientation
            let area: Float
            switch plane.category {
            case .floor, .ceiling:
                area = width * depth
            case .wall:
                area = max(width, depth) * height
            default:
                area = width * height
            }

            guard area >= config.minPlaneArea else { continue }

            let surface = ExtractedSurface(
                type: plane.category,
                vertices: surfaceVertices,
                normals: surfaceNormals,
                faces: [],  // TODO: Extract relevant faces
                plane: plane.plane,
                area: area,
                confidence: plane.confidence
            )

            switch plane.category {
            case .floor:
                if extractedFloor == nil || area > (extractedFloor?.area ?? 0) {
                    extractedFloor = surface
                }
            case .ceiling:
                if extractedCeiling == nil || area > (extractedCeiling?.area ?? 0) {
                    extractedCeiling = surface
                }
            case .wall:
                extractedWalls.append(surface)
            default:
                break
            }
        }
    }

    // MARK: - Object Identification

    private func identifyObjects(
        vertices: [SIMD3<Float>],
        classifications: [SurfaceCategory],
        roomBounds: RoomBounds
    ) {
        // Find clusters of "unknown" vertices (likely objects)
        let unknownIndices = classifications.enumerated()
            .filter { $0.element == .unknown }
            .map { $0.offset }

        guard !unknownIndices.isEmpty else { return }

        // Simple clustering: group by spatial proximity
        let unknownVertices = unknownIndices.map { vertices[$0] }

        // Use grid-based clustering
        let cellSize: Float = 0.3  // 30cm cells
        var cells: [String: [Int]] = [:]

        for (localIdx, vertex) in unknownVertices.enumerated() {
            let cellX = Int(floor(vertex.x / cellSize))
            let cellY = Int(floor(vertex.y / cellSize))
            let cellZ = Int(floor(vertex.z / cellSize))
            let key = "\(cellX)_\(cellY)_\(cellZ)"

            if cells[key] == nil {
                cells[key] = []
            }
            cells[key]?.append(localIdx)
        }

        // Merge adjacent cells into objects
        var visitedCells: Set<String> = []

        for (cellKey, _) in cells {
            guard !visitedCells.contains(cellKey) else { continue }

            // BFS to find connected cells
            var objectIndices: [Int] = []
            var queue = [cellKey]
            visitedCells.insert(cellKey)

            while !queue.isEmpty {
                let current = queue.removeFirst()
                if let indices = cells[current] {
                    objectIndices.append(contentsOf: indices)
                }

                // Check 26 neighbors (3D)
                let parts = current.split(separator: "_").compactMap { Int($0) }
                guard parts.count == 3 else { continue }

                for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 {
                            if dx == 0 && dy == 0 && dz == 0 { continue }
                            let neighborKey = "\(parts[0] + dx)_\(parts[1] + dy)_\(parts[2] + dz)"
                            if cells[neighborKey] != nil && !visitedCells.contains(neighborKey) {
                                visitedCells.insert(neighborKey)
                                queue.append(neighborKey)
                            }
                        }
                    }
                }
            }

            // Create object from cluster
            guard objectIndices.count >= 10 else { continue }

            let objectVertices = objectIndices.map { unknownVertices[$0] }

            let minPt = SIMD3<Float>(
                objectVertices.map { $0.x }.min() ?? 0,
                objectVertices.map { $0.y }.min() ?? 0,
                objectVertices.map { $0.z }.min() ?? 0
            )
            let maxPt = SIMD3<Float>(
                objectVertices.map { $0.x }.max() ?? 0,
                objectVertices.map { $0.y }.max() ?? 0,
                objectVertices.map { $0.z }.max() ?? 0
            )

            let size = maxPt - minPt
            let volume = size.x * size.y * size.z

            guard volume >= config.minObjectVolume && volume <= config.maxObjectVolume else { continue }

            // Classify object type based on size/position
            let category: ObjectCategory
            if volume > 0.5 && size.y > 0.5 {
                category = .furniture
            } else if volume > 0.3 {
                category = .appliance
            } else {
                category = .clutter
            }

            let object = ExtractedObject(
                category: category,
                boundingBox: (min: minPt, max: maxPt),
                vertices: objectVertices,
                confidence: 0.7
            )
            extractedObjects.append(object)
        }
    }

    // MARK: - Export Clean Architecture

    /// Generate a clean mesh containing only architectural elements
    func generateCleanArchitecturalMesh() -> CapturedScan? {
        guard extractedFloor != nil || extractedCeiling != nil || !extractedWalls.isEmpty else {
            return nil
        }

        var meshes: [CapturedMeshData] = []

        // Add floor
        if let floor = extractedFloor {
            let mesh = surfaceToMesh(floor, identifier: UUID())
            meshes.append(mesh)
        }

        // Add ceiling
        if let ceiling = extractedCeiling {
            let mesh = surfaceToMesh(ceiling, identifier: UUID())
            meshes.append(mesh)
        }

        // Add walls
        for wall in extractedWalls {
            let mesh = surfaceToMesh(wall, identifier: UUID())
            meshes.append(mesh)
        }

        var scan = CapturedScan(startTime: Date())
        scan.meshes = meshes
        scan.endTime = Date()

        return scan
    }

    private func surfaceToMesh(_ surface: ExtractedSurface, identifier: UUID) -> CapturedMeshData {
        return CapturedMeshData(
            vertices: surface.vertices,
            normals: surface.normals,
            colors: [],
            faces: surface.faces,
            transform: matrix_identity_float4x4,
            identifier: identifier,
            surfaceType: surfaceTypeToSurfaceType(surface.type)
        )
    }

    private func surfaceTypeToSurfaceType(_ category: SurfaceCategory) -> SurfaceType? {
        switch category {
        case .floor: return .floor
        case .ceiling: return .ceiling
        case .wall: return .wall
        default: return nil
        }
    }

    // MARK: - Core ML Model Loading

    /// Load a trained Core ML model for semantic segmentation
    func loadMLModel(named modelName: String) -> Bool {
        // Try to load compiled model from bundle
        if let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine  // Use Neural Engine when available
                segmentationModel = try MLModel(contentsOf: modelURL, configuration: config)
                print("[ArchitecturalExtractor] Loaded ML model: \(modelName)")
                return true
            } catch {
                print("[ArchitecturalExtractor] Failed to load model: \(error)")
            }
        }

        // Try mlpackage
        if let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlpackage") {
            do {
                let compiledURL = try MLModel.compileModel(at: modelURL)
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                segmentationModel = try MLModel(contentsOf: compiledURL, configuration: config)
                print("[ArchitecturalExtractor] Loaded and compiled ML model: \(modelName)")
                return true
            } catch {
                print("[ArchitecturalExtractor] Failed to compile/load model: \(error)")
            }
        }

        print("[ArchitecturalExtractor] Model not found: \(modelName)")
        return false
    }

    /// Check if ML model is loaded
    var hasMLModel: Bool {
        segmentationModel != nil
    }

    // MARK: - Core ML Inference

    /// Classify points using Core ML model
    private func classifyWithMLModel(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        model: MLModel
    ) async -> [SurfaceCategory] {

        // Prepare input: N x 6 array (x, y, z, nx, ny, nz)
        let numPoints = vertices.count
        guard numPoints > 0 else { return [] }

        do {
            // Create MLMultiArray for input
            let inputArray = try MLMultiArray(shape: [1, NSNumber(value: numPoints), 6], dataType: .float32)

            // Fill input data
            for i in 0..<numPoints {
                let vertex = vertices[i]
                let normal = i < normals.count ? normals[i] : SIMD3<Float>(0, 1, 0)

                inputArray[[0, i, 0] as [NSNumber]] = NSNumber(value: vertex.x)
                inputArray[[0, i, 1] as [NSNumber]] = NSNumber(value: vertex.y)
                inputArray[[0, i, 2] as [NSNumber]] = NSNumber(value: vertex.z)
                inputArray[[0, i, 3] as [NSNumber]] = NSNumber(value: normal.x)
                inputArray[[0, i, 4] as [NSNumber]] = NSNumber(value: normal.y)
                inputArray[[0, i, 5] as [NSNumber]] = NSNumber(value: normal.z)
            }

            // Create feature provider
            let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["points": inputArray])

            // Run inference
            let output = try model.prediction(from: inputFeatures)

            // Parse output (N x 4 probabilities)
            guard let outputArray = output.featureValue(for: "classifications")?.multiArrayValue else {
                print("[ArchitecturalExtractor] Failed to get output array")
                return classifyGeometric(vertices: vertices, normals: normals, roomBounds: estimateRoomBounds(vertices: vertices))
            }

            // Convert to classifications
            var classifications: [SurfaceCategory] = []
            for i in 0..<numPoints {
                // Get probabilities for this point
                let floorProb = outputArray[[0, i, 0] as [NSNumber]].floatValue
                let ceilingProb = outputArray[[0, i, 1] as [NSNumber]].floatValue
                let wallProb = outputArray[[0, i, 2] as [NSNumber]].floatValue
                let objectProb = outputArray[[0, i, 3] as [NSNumber]].floatValue

                // Find max probability
                let probs = [floorProb, ceilingProb, wallProb, objectProb]
                let maxIdx = probs.enumerated().max(by: { $0.element < $1.element })?.offset ?? 3

                let category: SurfaceCategory
                switch maxIdx {
                case 0: category = .floor
                case 1: category = .ceiling
                case 2: category = .wall
                default: category = .unknown
                }
                classifications.append(category)
            }

            print("[ArchitecturalExtractor] ML classification complete: \(numPoints) points")
            return classifications

        } catch {
            print("[ArchitecturalExtractor] ML inference failed: \(error)")
            // Fallback to geometric
            return classifyGeometric(vertices: vertices, normals: normals, roomBounds: estimateRoomBounds(vertices: vertices))
        }
    }
}
