import Foundation
import simd

// MARK: - Serializable Mesh Data

/// Codable wrapper for CapturedMeshData that can be saved to disk
struct SerializableMesh: Codable {
    let identifier: UUID
    let vertices: [[Float]]       // SIMD3<Float> → [x, y, z]
    let normals: [[Float]]
    let colors: [[Float]]?        // Optional RGB values
    let faces: [[UInt32]]
    let transform: [Float]        // 4x4 matrix flattened to 16 floats
    let surfaceType: String?
    let qualityScore: Float
    let capturedAt: Date

    /// Convert from CapturedMeshData
    init(from mesh: CapturedMeshData, qualityScore: Float = 0.5) {
        self.identifier = mesh.identifier
        self.vertices = mesh.vertices.map { [$0.x, $0.y, $0.z] }
        self.normals = mesh.normals.map { [$0.x, $0.y, $0.z] }
        self.colors = mesh.colors.isEmpty ? nil : mesh.colors.map { [$0.r, $0.g, $0.b] }
        self.faces = mesh.faces
        self.transform = mesh.transform.flattenedArray
        self.surfaceType = mesh.surfaceType?.rawValue
        self.qualityScore = qualityScore
        self.capturedAt = Date()
    }

    /// Convert back to CapturedMeshData
    func toCapturedMeshData() -> CapturedMeshData {
        let simdVertices = vertices.map { SIMD3<Float>($0[0], $0[1], $0[2]) }
        let simdNormals = normals.map { SIMD3<Float>($0[0], $0[1], $0[2]) }
        let vertexColors = colors?.map { VertexColor(r: $0[0], g: $0[1], b: $0[2]) } ?? []
        let simdTransform = simd_float4x4(fromArray: transform)
        let surfaceTypeEnum = surfaceType.flatMap { SurfaceType(rawValue: $0) }

        return CapturedMeshData(
            vertices: simdVertices,
            normals: simdNormals,
            colors: vertexColors,
            faces: faces,
            transform: simdTransform,
            identifier: identifier,
            surfaceType: surfaceTypeEnum,
            faceClassifications: nil
        )
    }
}

// MARK: - Saved Scan Session

/// Represents a saved scan session that can be persisted and reloaded
struct SavedScanSession: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var lastModifiedAt: Date
    let scanMode: String          // ScanMode.rawValue

    // Serialized data (stored separately for efficiency)
    var meshesData: Data          // Encoded [SerializableMesh]
    var statisticsData: Data?     // Encoded ScanStatistics
    var roomBuilderData: Data?    // Encoded room state

    // Quick stats for list display (cached)
    let vertexCount: Int
    let meshCount: Int
    var thumbnailData: Data?

    /// Create a new session from a captured scan
    init(
        name: String,
        scan: CapturedScan,
        mode: ScanMode,
        qualityScores: [UUID: Float] = [:]
    ) throws {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.lastModifiedAt = Date()
        self.scanMode = mode.rawValue

        // Serialize meshes
        let serializableMeshes = scan.meshes.map { mesh in
            SerializableMesh(from: mesh, qualityScore: qualityScores[mesh.identifier] ?? 0.5)
        }
        self.meshesData = try JSONEncoder().encode(serializableMeshes)

        // Serialize statistics if available (using Codable wrapper)
        if let stats = scan.statistics {
            let codableStats = CodableScanStatistics(from: stats)
            self.statisticsData = try? JSONEncoder().encode(codableStats)
        } else {
            self.statisticsData = nil
        }

        self.roomBuilderData = nil  // TODO: Serialize room builder state

        // Cache quick stats
        self.vertexCount = scan.vertexCount
        self.meshCount = scan.meshes.count
        self.thumbnailData = nil
    }

    /// Load meshes from serialized data
    func loadMeshes() throws -> [CapturedMeshData] {
        let serializableMeshes = try JSONDecoder().decode([SerializableMesh].self, from: meshesData)
        return serializableMeshes.map { $0.toCapturedMeshData() }
    }

    /// Load statistics from serialized data
    func loadStatistics() -> ScanStatistics? {
        guard let data = statisticsData else { return nil }
        guard let codableStats = try? JSONDecoder().decode(CodableScanStatistics.self, from: data) else {
            return nil
        }
        return codableStats.toScanStatistics()
    }

    /// Convert to CapturedScan for editing/exporting
    func toCapturedScan() throws -> CapturedScan {
        let meshes = try loadMeshes()
        var scan = CapturedScan(startTime: createdAt)
        scan.meshes = meshes
        scan.endTime = lastModifiedAt
        scan.statistics = loadStatistics()
        return scan
    }

    /// Update session with new scan data
    mutating func update(with scan: CapturedScan, qualityScores: [UUID: Float] = [:]) throws {
        let serializableMeshes = scan.meshes.map { mesh in
            SerializableMesh(from: mesh, qualityScore: qualityScores[mesh.identifier] ?? 0.5)
        }
        self.meshesData = try JSONEncoder().encode(serializableMeshes)

        if let stats = scan.statistics {
            let codableStats = CodableScanStatistics(from: stats)
            self.statisticsData = try? JSONEncoder().encode(codableStats)
        }

        self.lastModifiedAt = Date()
    }
}

// MARK: - Codable Statistics (simplified version for storage)

/// Codable wrapper for the essential statistics that can be saved
struct CodableScanStatistics: Codable {
    var floorArea: Float
    var ceilingArea: Float
    var wallArea: Float
    var objectArea: Float
    var protrusionArea: Float
    var floorHeight: Float?
    var ceilingHeight: Float?
    var protrusionCount: Int
    var edgeCount: Int
    var doorCount: Int
    var windowCount: Int

    init(from stats: ScanStatistics) {
        self.floorArea = stats.floorArea
        self.ceilingArea = stats.ceilingArea
        self.wallArea = stats.wallArea
        self.objectArea = stats.objectArea
        self.protrusionArea = stats.protrusionArea
        self.floorHeight = stats.floorHeight
        self.ceilingHeight = stats.ceilingHeight
        self.protrusionCount = stats.detectedProtrusions.count
        self.edgeCount = stats.detectedEdges.count
        self.doorCount = stats.detectedDoors.count
        self.windowCount = stats.detectedWindows.count
    }

    func toScanStatistics() -> ScanStatistics {
        var stats = ScanStatistics()
        stats.floorArea = floorArea
        stats.ceilingArea = ceilingArea
        stats.wallArea = wallArea
        stats.objectArea = objectArea
        stats.protrusionArea = protrusionArea
        stats.floorHeight = floorHeight
        stats.ceilingHeight = ceilingHeight
        // Note: detailed protrusions/edges/doors/windows are not preserved
        // They will be re-detected when scanning resumes
        return stats
    }
}

// MARK: - Session Metadata (for list display without loading full data)

struct SessionMetadata: Codable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    let lastModifiedAt: Date
    let scanMode: String
    let vertexCount: Int
    let meshCount: Int
    let hasThumbnail: Bool

    init(from session: SavedScanSession) {
        self.id = session.id
        self.name = session.name
        self.createdAt = session.createdAt
        self.lastModifiedAt = session.lastModifiedAt
        self.scanMode = session.scanMode
        self.vertexCount = session.vertexCount
        self.meshCount = session.meshCount
        self.hasThumbnail = session.thumbnailData != nil
    }
}

// MARK: - Matrix Extensions

extension simd_float4x4 {
    /// Flatten 4x4 matrix to 16-element array (column-major)
    var flattenedArray: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w
        ]
    }

    /// Create matrix from 16-element array (column-major)
    init(fromArray array: [Float]) {
        guard array.count == 16 else {
            self = matrix_identity_float4x4
            return
        }
        self.init(
            SIMD4<Float>(array[0], array[1], array[2], array[3]),
            SIMD4<Float>(array[4], array[5], array[6], array[7]),
            SIMD4<Float>(array[8], array[9], array[10], array[11]),
            SIMD4<Float>(array[12], array[13], array[14], array[15])
        )
    }
}
