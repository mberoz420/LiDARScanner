import Foundation
import simd
import ARKit

/// Represents a single mesh anchor's geometry data
struct CapturedMeshData {
    let vertices: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let faces: [[UInt32]]
    let transform: simd_float4x4
    let identifier: UUID
}

/// Container for entire scan session
struct CapturedScan {
    var meshes: [CapturedMeshData] = []
    let startTime: Date
    var endTime: Date?

    var vertexCount: Int {
        meshes.reduce(0) { $0 + $1.vertices.count }
    }

    var faceCount: Int {
        meshes.reduce(0) { $0 + $1.faces.count }
    }
}
