import Foundation
import ModelIO
import MetalKit
import ARKit

/// Exports scanned mesh data to various file formats
class MeshExporter {

    // MARK: - Export to OBJ

    /// Export mesh data to OBJ format
    static func exportToOBJ(meshData: MeshData, filename: String) throws -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent("\(filename).obj")

        var objContent = "# LiDAR Scanner Export\n"
        objContent += "# Vertices: \(meshData.vertexCount)\n"
        objContent += "# Triangles: \(meshData.triangleCount)\n\n"

        // Write vertices
        for i in stride(from: 0, to: meshData.vertices.count, by: 3) {
            let x = meshData.vertices[i]
            let y = meshData.vertices[i + 1]
            let z = meshData.vertices[i + 2]
            objContent += "v \(x) \(y) \(z)\n"
        }

        objContent += "\n"

        // Write normals
        for i in stride(from: 0, to: meshData.normals.count, by: 3) {
            let x = meshData.normals[i]
            let y = meshData.normals[i + 1]
            let z = meshData.normals[i + 2]
            objContent += "vn \(x) \(y) \(z)\n"
        }

        objContent += "\n"

        // Write faces (1-indexed for OBJ format)
        for i in stride(from: 0, to: meshData.indices.count, by: 3) {
            let i1 = meshData.indices[i] + 1
            let i2 = meshData.indices[i + 1] + 1
            let i3 = meshData.indices[i + 2] + 1
            objContent += "f \(i1)//\(i1) \(i2)//\(i2) \(i3)//\(i3)\n"
        }

        try objContent.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Export to STL

    /// Export mesh data to binary STL format
    static func exportToSTL(meshData: MeshData, filename: String) throws -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent("\(filename).stl")

        var data = Data()

        // Header (80 bytes)
        let header = "LiDAR Scanner Export".padding(toLength: 80, withPad: " ", startingAt: 0)
        data.append(header.data(using: .ascii)!)

        // Number of triangles (4 bytes, little-endian)
        var triangleCount = UInt32(meshData.triangleCount)
        data.append(Data(bytes: &triangleCount, count: 4))

        // Write each triangle
        for i in stride(from: 0, to: meshData.indices.count, by: 3) {
            let i1 = Int(meshData.indices[i])
            let i2 = Int(meshData.indices[i + 1])
            let i3 = Int(meshData.indices[i + 2])

            // Get vertices
            let v1 = SIMD3<Float>(
                meshData.vertices[i1 * 3],
                meshData.vertices[i1 * 3 + 1],
                meshData.vertices[i1 * 3 + 2]
            )
            let v2 = SIMD3<Float>(
                meshData.vertices[i2 * 3],
                meshData.vertices[i2 * 3 + 1],
                meshData.vertices[i2 * 3 + 2]
            )
            let v3 = SIMD3<Float>(
                meshData.vertices[i3 * 3],
                meshData.vertices[i3 * 3 + 1],
                meshData.vertices[i3 * 3 + 2]
            )

            // Calculate face normal
            let edge1 = v2 - v1
            let edge2 = v3 - v1
            let normal = simd_normalize(simd_cross(edge1, edge2))

            // Write normal (12 bytes)
            var n = normal
            data.append(Data(bytes: &n, count: 12))

            // Write vertices (36 bytes)
            var vertex1 = v1
            var vertex2 = v2
            var vertex3 = v3
            data.append(Data(bytes: &vertex1, count: 12))
            data.append(Data(bytes: &vertex2, count: 12))
            data.append(Data(bytes: &vertex3, count: 12))

            // Attribute byte count (2 bytes, usually 0)
            var attrByteCount: UInt16 = 0
            data.append(Data(bytes: &attrByteCount, count: 2))
        }

        try data.write(to: fileURL)
        return fileURL
    }

    // MARK: - Export to USDZ

    /// Export mesh data to USDZ format using ModelIO
    @MainActor
    static func exportToUSDZ(meshData: MeshData, filename: String) throws -> URL {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExportError.metalNotAvailable
        }

        let allocator = MTKMeshBufferAllocator(device: device)

        // Create vertex descriptor
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: 0,
            bufferIndex: 1
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        vertexDescriptor.layouts[1] = MDLVertexBufferLayout(stride: 12)

        // Create mesh
        let mesh = MDLMesh(
            vertexBuffer: allocator.newBuffer(with: Data(bytes: meshData.vertices, count: meshData.vertices.count * 4), type: .vertex),
            vertexCount: meshData.vertexCount,
            descriptor: vertexDescriptor,
            submeshes: []
        )

        // Add normals buffer
        mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)

        // Create submesh with indices
        let indexBuffer = allocator.newBuffer(
            with: Data(bytes: meshData.indices, count: meshData.indices.count * 4),
            type: .index
        )
        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: meshData.indices.count,
            indexType: .uint32,
            geometryType: .triangles,
            material: nil
        )
        mesh.submeshes = [submesh] as NSMutableArray

        // Create asset and export
        let asset = MDLAsset()
        asset.add(mesh)

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent("\(filename).usdz")

        try asset.export(to: fileURL)

        return fileURL
    }

    // MARK: - Export from ARMeshAnchors

    /// Export ARMeshAnchors directly to USDZ
    @MainActor
    static func exportAnchorsToUSDZ(anchors: [ARMeshAnchor], filename: String) throws -> URL {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExportError.metalNotAvailable
        }

        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset()

        for (index, anchor) in anchors.enumerated() {
            let geometry = anchor.geometry

            // Create MDLMesh from ARMeshGeometry
            let vertexBuffer = allocator.newBuffer(
                with: Data(
                    bytesNoCopy: geometry.vertices.buffer.contents(),
                    count: geometry.vertices.buffer.length,
                    deallocator: .none
                ),
                type: .vertex
            )

            let indexBuffer = allocator.newBuffer(
                with: Data(
                    bytesNoCopy: geometry.faces.buffer.contents(),
                    count: geometry.faces.buffer.length,
                    deallocator: .none
                ),
                type: .index
            )

            let vertexDescriptor = MDLVertexDescriptor()
            vertexDescriptor.attributes[0] = MDLVertexAttribute(
                name: MDLVertexAttributePosition,
                format: .float3,
                offset: 0,
                bufferIndex: 0
            )
            vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: geometry.vertices.stride)

            let submesh = MDLSubmesh(
                indexBuffer: indexBuffer,
                indexCount: geometry.faces.count * 3,
                indexType: .uint32,
                geometryType: .triangles,
                material: nil
            )

            let mesh = MDLMesh(
                vertexBuffer: vertexBuffer,
                vertexCount: geometry.vertices.count,
                descriptor: vertexDescriptor,
                submeshes: [submesh]
            )
            mesh.name = "mesh_\(index)"

            // Apply transform
            mesh.transform = MDLTransform(matrix: anchor.transform)

            asset.add(mesh)
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent("\(filename).usdz")

        try asset.export(to: fileURL)

        return fileURL
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case metalNotAvailable
        case invalidMeshData
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .metalNotAvailable:
                return "Metal is not available on this device."
            case .invalidMeshData:
                return "Invalid mesh data provided."
            case .writeFailed(let message):
                return "Failed to write file: \(message)"
            }
        }
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable {
    case obj = "OBJ"
    case stl = "STL"
    case usdz = "USDZ"

    var fileExtension: String {
        rawValue.lowercased()
    }

    var description: String {
        switch self {
        case .obj: return "Wavefront OBJ - widely compatible"
        case .stl: return "STL - for 3D printing"
        case .usdz: return "USDZ - Apple native format"
        }
    }
}
