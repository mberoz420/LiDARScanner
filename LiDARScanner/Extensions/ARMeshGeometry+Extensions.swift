import ARKit
import RealityKit
import simd

extension ARMeshGeometry {
    /// Safely extract all vertices at once to avoid buffer deallocation issues
    func extractAllVertices() -> [SIMD3<Float>] {
        let count = vertices.count
        guard count > 0 else { return [] }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)

        // Copy all data at once while buffer is valid
        let bufferPointer = vertices.buffer.contents().advanced(by: vertices.offset)
        for i in 0..<count {
            let vertexPointer = bufferPointer.advanced(by: vertices.stride * i)
            let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            // Validate the vertex data
            if vertex.x.isFinite && vertex.y.isFinite && vertex.z.isFinite {
                result.append(vertex)
            } else {
                result.append(SIMD3<Float>(0, 0, 0))
            }
        }
        return result
    }

    /// Safely extract all normals at once
    func extractAllNormals() -> [SIMD3<Float>] {
        let count = normals.count
        guard count > 0 else { return [] }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)

        let bufferPointer = normals.buffer.contents().advanced(by: normals.offset)
        for i in 0..<count {
            let normalPointer = bufferPointer.advanced(by: normals.stride * i)
            let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            if normal.x.isFinite && normal.y.isFinite && normal.z.isFinite {
                result.append(normal)
            } else {
                result.append(SIMD3<Float>(0, 1, 0))
            }
        }
        return result
    }

    /// Safely extract all face indices at once
    func extractAllFaceIndices() -> [[UInt32]] {
        let faceCount = faces.count
        guard faceCount > 0 else { return [] }

        var result: [[UInt32]] = []
        result.reserveCapacity(faceCount)

        let bufferPointer = faces.buffer.contents()
        let bytesPerIndex = faces.bytesPerIndex
        let indicesPerFace = faces.indexCountPerPrimitive

        for faceIndex in 0..<faceCount {
            let indexOffset = faceIndex * indicesPerFace * bytesPerIndex
            let facePointer = bufferPointer.advanced(by: indexOffset)

            var indices: [UInt32] = []
            for i in 0..<indicesPerFace {
                if bytesPerIndex == 4 {
                    let ptr = facePointer.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self)
                    indices.append(ptr.pointee)
                } else {
                    let ptr = facePointer.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self)
                    indices.append(UInt32(ptr.pointee))
                }
            }
            result.append(indices)
        }
        return result
    }

    /// Access individual vertices from the vertex buffer (legacy - use extractAllVertices for safety)
    func vertex(at index: Int) -> SIMD3<Float> {
        guard index >= 0 && index < vertices.count else {
            return SIMD3<Float>(0, 0, 0)
        }
        let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + vertices.stride * index)
        let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
        // Validate
        if vertex.x.isFinite && vertex.y.isFinite && vertex.z.isFinite {
            return vertex
        }
        return SIMD3<Float>(0, 0, 0)
    }

    /// Access individual normals from the normal buffer (legacy - use extractAllNormals for safety)
    func normal(at index: Int) -> SIMD3<Float> {
        guard index >= 0 && index < normals.count else {
            return SIMD3<Float>(0, 1, 0)
        }
        let normalPointer = normals.buffer.contents().advanced(by: normals.offset + normals.stride * index)
        let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
        if normal.x.isFinite && normal.y.isFinite && normal.z.isFinite {
            return normal
        }
        return SIMD3<Float>(0, 1, 0)
    }

    /// Access face indices (returns 3 vertex indices for each triangle)
    func faceIndices(at faceIndex: Int) -> [UInt32] {
        guard faceIndex >= 0 && faceIndex < faces.count else {
            return []
        }
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

        // Extract all data at once to avoid buffer deallocation issues
        let positions = arGeometry.extractAllVertices()
        let normals = arGeometry.extractAllNormals()
        let faceIndices = arGeometry.extractAllFaceIndices()

        guard !positions.isEmpty else {
            throw NSError(domain: "MeshResource", code: 1, userInfo: [NSLocalizedDescriptionKey: "No vertices in geometry"])
        }

        descriptor.positions = MeshBuffer(positions)

        if !normals.isEmpty {
            descriptor.normals = MeshBuffer(normals)
        }

        // Flatten face indices and validate
        var indices: [UInt32] = []
        let maxIndex = UInt32(positions.count - 1)
        for face in faceIndices {
            // Validate indices are within bounds
            let validFace = face.allSatisfy { $0 <= maxIndex }
            if validFace {
                indices.append(contentsOf: face)
            }
        }

        guard !indices.isEmpty else {
            throw NSError(domain: "MeshResource", code: 2, userInfo: [NSLocalizedDescriptionKey: "No valid faces in geometry"])
        }

        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }

    /// Generate mesh from ARFaceGeometry
    static func generate(from faceGeometry: ARFaceGeometry) throws -> MeshResource {
        var descriptor = MeshDescriptor()

        // Extract positions
        var positions: [SIMD3<Float>] = []
        for i in 0..<faceGeometry.vertices.count {
            positions.append(faceGeometry.vertices[i])
        }
        descriptor.positions = MeshBuffer(positions)

        // Extract triangle indices
        var indices: [UInt32] = []
        let indexCount = faceGeometry.triangleCount * 3
        for i in 0..<indexCount {
            indices.append(UInt32(faceGeometry.triangleIndices[i]))
        }
        descriptor.primitives = .triangles(indices)

        return try MeshResource.generate(from: [descriptor])
    }
}
