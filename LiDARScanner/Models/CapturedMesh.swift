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

/// Container for entire scan session
struct CapturedScan {
    var meshes: [CapturedMeshData] = []
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
