import ARKit
import RealityKit

extension ARMeshGeometry {
    /// Access individual vertices from the vertex buffer
    func vertex(at index: Int) -> SIMD3<Float> {
        let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + vertices.stride * index)
        return vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    /// Access individual normals from the normal buffer
    func normal(at index: Int) -> SIMD3<Float> {
        let normalPointer = normals.buffer.contents().advanced(by: normals.offset + normals.stride * index)
        return normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    /// Access face indices (returns 3 vertex indices for each triangle)
    func faceIndices(at faceIndex: Int) -> [UInt32] {
        let indexOffset = faceIndex * faces.indexCountPerPrimitive * faces.bytesPerIndex
        let facePointer = faces.buffer.contents().advanced(by: indexOffset)

        var indices: [UInt32] = []
        for i in 0..<faces.indexCountPerPrimitive {
            if faces.bytesPerIndex == 4 {
                let ptr = facePointer.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self)
                indices.append(ptr.pointee)
            } else {
                let ptr = facePointer.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self)
                indices.append(UInt32(ptr.pointee))
            }
        }
        return indices
    }
}

extension MeshResource {
    /// Generate MeshResource from ARMeshGeometry for visualization (solid mesh)
    static func generate(from arGeometry: ARMeshGeometry) throws -> MeshResource {
        var descriptor = MeshDescriptor()

        // Extract positions
        var positions: [SIMD3<Float>] = []
        for i in 0..<arGeometry.vertices.count {
            positions.append(arGeometry.vertex(at: i))
        }
        descriptor.positions = MeshBuffer(positions)

        // Extract normals
        var normals: [SIMD3<Float>] = []
        for i in 0..<arGeometry.normals.count {
            normals.append(arGeometry.normal(at: i))
        }
        descriptor.normals = MeshBuffer(normals)

        // Extract face indices
        var indices: [UInt32] = []
        for i in 0..<arGeometry.faces.count {
            let face = arGeometry.faceIndices(at: i)
            indices.append(contentsOf: face)
        }
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }

    /// Generate wireframe MeshResource from ARMeshGeometry (edge lines only)
    static func generateWireframe(from arGeometry: ARMeshGeometry) throws -> MeshResource {
        var descriptor = MeshDescriptor()

        // Extract positions
        var positions: [SIMD3<Float>] = []
        for i in 0..<arGeometry.vertices.count {
            positions.append(arGeometry.vertex(at: i))
        }
        descriptor.positions = MeshBuffer(positions)

        // Convert triangles to line segments (edges)
        // Each triangle has 3 edges: (0,1), (1,2), (2,0)
        var lineIndices: [UInt32] = []
        var edgeSet = Set<String>()

        for i in 0..<arGeometry.faces.count {
            let face = arGeometry.faceIndices(at: i)
            let edges = [
                (min(face[0], face[1]), max(face[0], face[1])),
                (min(face[1], face[2]), max(face[1], face[2])),
                (min(face[2], face[0]), max(face[2], face[0]))
            ]

            for edge in edges {
                let key = "\(edge.0)-\(edge.1)"
                if !edgeSet.contains(key) {
                    edgeSet.insert(key)
                    lineIndices.append(edge.0)
                    lineIndices.append(edge.1)
                }
            }
        }

        descriptor.primitives = .lines(lineIndices)

        return try MeshResource.generate(from: [descriptor])
    }
}
