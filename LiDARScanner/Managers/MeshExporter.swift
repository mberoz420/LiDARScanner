import Foundation
import ModelIO
import SceneKit
import simd

enum ExportFormat: String, CaseIterable, Identifiable {
    case usdz = "USDZ"
    case ply = "PLY"
    case obj = "OBJ"

    var id: String { rawValue }
    var fileExtension: String { rawValue.lowercased() }
}

@MainActor
class MeshExporter: ObservableObject {
    @Published var isExporting = false
    @Published var exportProgress: Float = 0.0
    @Published var lastError: String?

    /// Export scan to specified format
    func export(_ scan: CapturedScan, format: ExportFormat) async -> URL? {
        isExporting = true
        exportProgress = 0.0
        lastError = nil

        defer { isExporting = false }

        let timestamp = ISO8601DateFormatter().string(from: scan.startTime)
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "scan_\(timestamp).\(format.fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            switch format {
            case .usdz:
                try await exportUSDZ(scan, to: fileURL)
            case .ply:
                try await exportPLY(scan, to: fileURL)
            case .obj:
                try await exportOBJ(scan, to: fileURL)
            }
            exportProgress = 1.0
            return fileURL
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Export all formats at once
    func exportAll(_ scan: CapturedScan) async -> [ExportFormat: URL] {
        var results: [ExportFormat: URL] = [:]

        for (index, format) in ExportFormat.allCases.enumerated() {
            if let url = await export(scan, format: format) {
                results[format] = url
            }
            exportProgress = Float(index + 1) / Float(ExportFormat.allCases.count)
        }

        return results
    }

    // MARK: - USDZ Export
    private func exportUSDZ(_ scan: CapturedScan, to url: URL) async throws {
        let combinedMesh = combineMeshes(scan)

        let allocator = MDLMeshBufferDataAllocator()
        let mdlMesh = createMDLMesh(from: combinedMesh, allocator: allocator)

        let asset = MDLAsset()
        asset.add(mdlMesh)

        // Export to temporary USDA first
        let tempURL = url.deletingPathExtension().appendingPathExtension("usda")
        try asset.export(to: tempURL)

        // Convert to USDZ using SceneKit
        let scene = try SCNScene(url: tempURL)
        scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)

        // Clean up temp file
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - PLY Export (with vertex colors)
    private func exportPLY(_ scan: CapturedScan, to url: URL) async throws {
        let combined = combineMeshes(scan)
        let hasColors = combined.hasColors

        // Build header - PLY requires strict format with no extra blank lines
        var headerLines = [
            "ply",
            "format ascii 1.0",
            "element vertex \(combined.vertices.count)",
            "property float x",
            "property float y",
            "property float z",
            "property float nx",
            "property float ny",
            "property float nz"
        ]

        if hasColors {
            headerLines.append(contentsOf: [
                "property uchar red",
                "property uchar green",
                "property uchar blue"
            ])
        }

        headerLines.append(contentsOf: [
            "element face \(combined.faces.count)",
            "property list uchar int vertex_indices",
            "end_header"
        ])

        var plyContent = headerLines.joined(separator: "\n") + "\n"

        // Write vertices with normals and colors
        // Use explicit formatting to avoid locale issues with decimal separators
        for i in 0..<combined.vertices.count {
            let v = combined.vertices[i]
            let n = i < combined.normals.count ? combined.normals[i] : SIMD3<Float>(0, 1, 0)

            if hasColors && i < combined.colors.count {
                let c = combined.colors[i]
                let r = Int(max(0, min(255, c.r * 255)))
                let g = Int(max(0, min(255, c.g * 255)))
                let b = Int(max(0, min(255, c.b * 255)))
                plyContent += String(format: "%.6f %.6f %.6f %.6f %.6f %.6f %d %d %d\n",
                                     v.x, v.y, v.z, n.x, n.y, n.z, r, g, b)
            } else {
                plyContent += String(format: "%.6f %.6f %.6f %.6f %.6f %.6f\n",
                                     v.x, v.y, v.z, n.x, n.y, n.z)
            }
        }

        // Write faces
        for face in combined.faces {
            plyContent += "3 \(face[0]) \(face[1]) \(face[2])\n"
        }

        // Write with Unix line endings (LF only)
        let data = plyContent.data(using: .utf8)!
        try data.write(to: url)
    }

    // MARK: - OBJ Export (with MTL for colors)
    private func exportOBJ(_ scan: CapturedScan, to url: URL) async throws {
        let combined = combineMeshes(scan)

        var objContent = "# LiDAR Scanner Export\n"
        objContent += "# Vertices: \(combined.vertices.count)\n"
        objContent += "# Faces: \(combined.faces.count)\n\n"

        // Write vertices with explicit formatting to avoid locale issues
        for v in combined.vertices {
            objContent += String(format: "v %.6f %.6f %.6f\n", v.x, v.y, v.z)
        }

        objContent += "\n"

        // Write normals
        for n in combined.normals {
            objContent += String(format: "vn %.6f %.6f %.6f\n", n.x, n.y, n.z)
        }

        objContent += "\n"

        // Write faces (OBJ uses 1-based indexing)
        for face in combined.faces {
            let i0 = face[0] + 1
            let i1 = face[1] + 1
            let i2 = face[2] + 1
            objContent += "f \(i0)//\(i0) \(i1)//\(i1) \(i2)//\(i2)\n"
        }

        // Write with Unix line endings (LF only)
        let data = objContent.data(using: .utf8)!
        try data.write(to: url)
    }

    // MARK: - Helpers

    /// Combine all mesh anchors into single mesh with world-space transforms applied
    /// Also filters out faces that are beyond glass/window planes
    private func combineMeshes(_ scan: CapturedScan) -> CapturedMeshData {
        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allColors: [VertexColor] = []
        var allFaces: [[UInt32]] = []
        var vertexOffset: UInt32 = 0

        let windowPlanes = scan.windowPlanes
        var filteredFaceCount = 0

        for mesh in scan.meshes {
            // Transform vertices to world space
            var meshWorldVertices: [SIMD3<Float>] = []
            for vertex in mesh.vertices {
                let worldPos = mesh.transform * SIMD4<Float>(vertex, 1)
                let worldVertex = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)
                meshWorldVertices.append(worldVertex)
                allVertices.append(worldVertex)
            }

            // Transform normals (rotation only)
            let normalMatrix = simd_float3x3(
                SIMD3<Float>(mesh.transform.columns.0.x, mesh.transform.columns.0.y, mesh.transform.columns.0.z),
                SIMD3<Float>(mesh.transform.columns.1.x, mesh.transform.columns.1.y, mesh.transform.columns.1.z),
                SIMD3<Float>(mesh.transform.columns.2.x, mesh.transform.columns.2.y, mesh.transform.columns.2.z)
            )
            for normal in mesh.normals {
                allNormals.append(normalize(normalMatrix * normal))
            }

            // Copy colors
            allColors.append(contentsOf: mesh.colors)

            // Offset face indices, filtering out faces beyond glass
            for face in mesh.faces {
                let idx0 = Int(face[0])
                let idx1 = Int(face[1])
                let idx2 = Int(face[2])

                // Get world-space vertices for this face
                guard idx0 < meshWorldVertices.count,
                      idx1 < meshWorldVertices.count,
                      idx2 < meshWorldVertices.count else { continue }

                let v0 = meshWorldVertices[idx0]
                let v1 = meshWorldVertices[idx1]
                let v2 = meshWorldVertices[idx2]

                // Check if face should be filtered (all vertices beyond any window plane)
                var shouldFilterFace = false
                for plane in windowPlanes {
                    if plane.shouldFilter(v0) && plane.shouldFilter(v1) && plane.shouldFilter(v2) {
                        shouldFilterFace = true
                        break
                    }
                }

                if shouldFilterFace {
                    filteredFaceCount += 1
                    continue  // Skip this face
                }

                allFaces.append([
                    face[0] + vertexOffset,
                    face[1] + vertexOffset,
                    face[2] + vertexOffset
                ])
            }

            vertexOffset += UInt32(mesh.vertices.count)
        }

        if filteredFaceCount > 0 {
            print("[MeshExporter] Filtered \(filteredFaceCount) faces beyond glass/windows")
        }

        return CapturedMeshData(
            vertices: allVertices,
            normals: allNormals,
            colors: allColors,
            faces: allFaces,
            transform: matrix_identity_float4x4,
            identifier: UUID()
        )
    }

    private func createMDLMesh(from mesh: CapturedMeshData, allocator: MDLMeshBufferAllocator) -> MDLMesh {
        // Create vertex data
        let vertexData = mesh.vertices.withUnsafeBytes { Data($0) }
        let normalData = mesh.normals.withUnsafeBytes { Data($0) }

        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
        let normalBuffer = allocator.newBuffer(with: normalData, type: .vertex)

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
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
        vertexDescriptor.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        // Create index data
        let indices = mesh.faces.flatMap { $0 }
        let indexData = indices.withUnsafeBytes { Data($0) }
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: indices.count,
            indexType: .uint32,
            geometryType: .triangles,
            material: nil
        )

        return MDLMesh(
            vertexBuffers: [vertexBuffer, normalBuffer],
            vertexCount: mesh.vertices.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )
    }
}
