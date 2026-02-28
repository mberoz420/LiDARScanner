import Foundation
import simd
import ARKit
import UIKit

/// RGB color for a vertex
struct VertexColor {
    let r: Float
    let g: Float
    let b: Float

    static let white = VertexColor(r: 1, g: 1, b: 1)

    init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(uiColor: UIColor) {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: nil)
        self.r = Float(red)
        self.g = Float(green)
        self.b = Float(blue)
    }
}

/// Represents a single mesh anchor's geometry data
struct CapturedMeshData {
    let vertices: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let colors: [VertexColor]
    let faces: [[UInt32]]
    let transform: simd_float4x4
    let identifier: UUID
    var surfaceType: SurfaceType?
    var faceClassifications: [SurfaceType]?  // Per-face classification

    var hasColors: Bool {
        !colors.isEmpty && colors.count == vertices.count
    }

    init(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        colors: [VertexColor] = [],
        faces: [[UInt32]],
        transform: simd_float4x4,
        identifier: UUID,
        surfaceType: SurfaceType? = nil,
        faceClassifications: [SurfaceType]? = nil
    ) {
        self.vertices = vertices
        self.normals = normals
        self.colors = colors
        self.faces = faces
        self.transform = transform
        self.identifier = identifier
        self.surfaceType = surfaceType
        self.faceClassifications = faceClassifications
    }
}

/// User-classified object for export grouping
struct ExportClassifiedObject {
    let id: UUID
    let category: String           // "Appliance", "Cabinet", "Furniture", etc.
    let exportGroup: String        // Group name for OBJ export
    let position: SIMD3<Float>
    let boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)
    let expectedEdges: Int
}

/// Window/glass plane for filtering LiDAR artifacts beyond glass
struct ExportWindowPlane {
    let id: UUID
    let position: SIMD3<Float>       // Center of window/glass
    let normal: SIMD3<Float>         // Outward-facing normal (through glass)
    let width: Float
    let height: Float
    let bottomY: Float

    /// Check if a point is beyond this glass plane
    func isOutside(_ point: SIMD3<Float>) -> Bool {
        let toPoint = point - position
        return simd_dot(toPoint, normal) > 0.1  // 10cm tolerance
    }

    /// Check if point is within the horizontal/vertical bounds of the window
    func isWithinBounds(_ point: SIMD3<Float>) -> Bool {
        let toPoint = point - position

        // Get right vector (perpendicular to normal and up)
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(up, normal))

        let horizontalDist = abs(simd_dot(toPoint, right))
        let verticalPos = point.y

        return horizontalDist < width / 2 &&
               verticalPos >= bottomY &&
               verticalPos <= bottomY + height
    }

    /// Check if a point should be filtered (outside glass and within window projection)
    func shouldFilter(_ point: SIMD3<Float>) -> Bool {
        return isOutside(point) && isWithinBounds(point)
    }
}

/// Container for entire scan session
struct CapturedScan {
    var meshes: [CapturedMeshData] = []
    var classifiedObjects: [ExportClassifiedObject] = []
    var windowPlanes: [ExportWindowPlane] = []
    let startTime: Date
    var endTime: Date?
    var statistics: ScanStatistics?

    var vertexCount: Int {
        meshes.reduce(0) { $0 + $1.vertices.count }
    }

    var faceCount: Int {
        meshes.reduce(0) { $0 + $1.faces.count }
    }

    var hasColors: Bool {
        meshes.first?.hasColors ?? false
    }

    // Surface type breakdown
    var floorMeshCount: Int {
        meshes.filter { $0.surfaceType == .floor }.count
    }

    var ceilingMeshCount: Int {
        meshes.filter { $0.surfaceType == .ceiling }.count
    }

    var wallMeshCount: Int {
        meshes.filter { $0.surfaceType == .wall }.count
    }

    var protrusionCount: Int {
        statistics?.detectedProtrusions.count ?? 0
    }

    var edgeCount: Int {
        statistics?.detectedEdges.count ?? 0
    }

    var roomSummary: String? {
        statistics?.summary
    }
}
