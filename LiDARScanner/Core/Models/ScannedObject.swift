import Foundation
import simd
import ModelIO

/// Represents a 3D object captured via LiDAR scanning
struct ScannedObject: Identifiable, Codable {
    let id: UUID
    let captureDate: Date
    var metrics: ObjectMetrics
    var meshData: MeshData?
    var capturedImage: Data? // JPEG data of the scanned object
    var exportedFileURL: URL?

    init(
        id: UUID = UUID(),
        captureDate: Date = Date(),
        metrics: ObjectMetrics,
        meshData: MeshData? = nil,
        capturedImage: Data? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.metrics = metrics
        self.meshData = meshData
        self.capturedImage = capturedImage
    }
}

/// Extracted measurements and shape characteristics
struct ObjectMetrics: Codable {
    /// Dimensions in meters (length, width, height)
    var dimensions: SIMD3<Float>

    /// Calculated volume in cubic meters
    var volume: Float

    /// Surface area in square meters
    var surfaceArea: Float

    /// Detected primitive shape type
    var primitiveType: PrimitiveShape

    /// Feature descriptor for shape matching (normalized values)
    var featureDescriptor: [Float]

    /// Bounding box center point
    var center: SIMD3<Float>

    /// Bounding box rotation (quaternion)
    var rotation: simd_quatf

    init(
        dimensions: SIMD3<Float> = .zero,
        volume: Float = 0,
        surfaceArea: Float = 0,
        primitiveType: PrimitiveShape = .unknown,
        featureDescriptor: [Float] = [],
        center: SIMD3<Float> = .zero,
        rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    ) {
        self.dimensions = dimensions
        self.volume = volume
        self.surfaceArea = surfaceArea
        self.primitiveType = primitiveType
        self.featureDescriptor = featureDescriptor
        self.center = center
        self.rotation = rotation
    }

    /// Dimensions in millimeters
    var dimensionsMM: SIMD3<Float> {
        dimensions * 1000
    }

    /// Dimensions in inches
    var dimensionsInches: SIMD3<Float> {
        dimensions * 39.3701
    }

    /// Human-readable dimension string
    func dimensionString(unit: String = "mm") -> String {
        let dims: SIMD3<Float>
        switch unit {
        case "in":
            dims = dimensionsInches
        case "cm":
            dims = dimensions * 100
        default:
            dims = dimensionsMM
        }
        return String(format: "%.1f × %.1f × %.1f %@", dims.x, dims.y, dims.z, unit)
    }
}

/// Detected primitive shape categories
enum PrimitiveShape: String, Codable, CaseIterable {
    case box
    case cylinder
    case sphere
    case cone
    case torus
    case plane
    case complex // Non-primitive shape
    case unknown

    var displayName: String {
        switch self {
        case .box: return "Box/Rectangular"
        case .cylinder: return "Cylinder"
        case .sphere: return "Sphere"
        case .cone: return "Cone"
        case .torus: return "Torus/Ring"
        case .plane: return "Flat Surface"
        case .complex: return "Complex Shape"
        case .unknown: return "Unknown"
        }
    }

    var iconName: String {
        switch self {
        case .box: return "cube"
        case .cylinder: return "cylinder"
        case .sphere: return "circle.fill"
        case .cone: return "cone"
        case .torus: return "circle"
        case .plane: return "square"
        case .complex: return "cube.transparent"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Raw mesh data from LiDAR scan
struct MeshData: Codable {
    /// Vertex positions (x, y, z triplets)
    var vertices: [Float]

    /// Vertex normals (x, y, z triplets)
    var normals: [Float]

    /// Triangle indices
    var indices: [UInt32]

    /// Number of vertices
    var vertexCount: Int {
        vertices.count / 3
    }

    /// Number of triangles
    var triangleCount: Int {
        indices.count / 3
    }
}

// MARK: - SIMD3 Codable Extension
extension SIMD3: Codable where Scalar: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        let z = try container.decode(Scalar.self)
        self.init(x, y, z)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
    }
}

// MARK: - simd_quatf Codable Extension
extension simd_quatf: Codable {
    enum CodingKeys: String, CodingKey {
        case ix, iy, iz, r
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ix = try container.decode(Float.self, forKey: .ix)
        let iy = try container.decode(Float.self, forKey: .iy)
        let iz = try container.decode(Float.self, forKey: .iz)
        let r = try container.decode(Float.self, forKey: .r)
        self.init(ix: ix, iy: iy, iz: iz, r: r)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(imag.x, forKey: .ix)
        try container.encode(imag.y, forKey: .iy)
        try container.encode(imag.z, forKey: .iz)
        try container.encode(real, forKey: .r)
    }
}
