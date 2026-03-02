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

    // MARK: - OBJ Export (with groups for Blender layers)
    private func exportOBJ(_ scan: CapturedScan, to url: URL) async throws {
        // Group meshes by surface type
        var groupedMeshes: [String: [CapturedMeshData]] = [
            "Floor": [],
            "Ceiling": [],
            "Walls": [],
            "Objects": []
        ]

        let windowPlanes = scan.windowPlanes

        for mesh in scan.meshes {
            // Determine group based on surface type
            let groupName: String
            switch mesh.surfaceType {
            case .floor:
                groupName = "Floor"
            case .ceiling, .ceilingProtrusion:
                groupName = "Ceiling"
            case .wall:
                groupName = "Walls"
            default:
                groupName = "Objects"
            }

            groupedMeshes[groupName, default: []].append(mesh)
        }

        var objContent = "# LiDAR Scanner Export\n"
        objContent += "# Groups: Floor, Ceiling, Walls, Objects\n"
        objContent += "# Use View > Outliner in Blender to show/hide groups\n\n"

        var globalVertexOffset: UInt32 = 0

        // Process each group
        let groupOrder = ["Floor", "Ceiling", "Walls", "Objects"]

        for groupName in groupOrder {
            guard let meshes = groupedMeshes[groupName], !meshes.isEmpty else { continue }

            // Write group header
            objContent += "\n# \(groupName) surfaces\n"
            objContent += "g \(groupName)\n"
            objContent += "o \(groupName)\n\n"

            var groupVertices: [SIMD3<Float>] = []
            var groupNormals: [SIMD3<Float>] = []
            var groupFaces: [[UInt32]] = []
            var localVertexOffset: UInt32 = 0

            for mesh in meshes {
                // Transform vertices to world space
                var meshWorldVertices: [SIMD3<Float>] = []
                for vertex in mesh.vertices {
                    let worldPos = mesh.transform * SIMD4<Float>(vertex, 1)
                    let wp = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)
                    meshWorldVertices.append(wp)
                    groupVertices.append(wp)
                }

                // Transform normals
                let normalMatrix = simd_float3x3(
                    SIMD3<Float>(mesh.transform.columns.0.x, mesh.transform.columns.0.y, mesh.transform.columns.0.z),
                    SIMD3<Float>(mesh.transform.columns.1.x, mesh.transform.columns.1.y, mesh.transform.columns.1.z),
                    SIMD3<Float>(mesh.transform.columns.2.x, mesh.transform.columns.2.y, mesh.transform.columns.2.z)
                )
                for normal in mesh.normals {
                    groupNormals.append(normalize(normalMatrix * normal))
                }

                // Process faces with glass filtering
                for face in mesh.faces {
                    let idx0 = Int(face[0])
                    let idx1 = Int(face[1])
                    let idx2 = Int(face[2])

                    guard idx0 < meshWorldVertices.count,
                          idx1 < meshWorldVertices.count,
                          idx2 < meshWorldVertices.count else { continue }

                    let v0 = meshWorldVertices[idx0]
                    let v1 = meshWorldVertices[idx1]
                    let v2 = meshWorldVertices[idx2]

                    // Filter faces beyond glass
                    var shouldFilter = false
                    for plane in windowPlanes {
                        if plane.shouldFilter(v0) && plane.shouldFilter(v1) && plane.shouldFilter(v2) {
                            shouldFilter = true
                            break
                        }
                    }
                    if shouldFilter { continue }

                    groupFaces.append([
                        face[0] + localVertexOffset,
                        face[1] + localVertexOffset,
                        face[2] + localVertexOffset
                    ])
                }

                localVertexOffset += UInt32(mesh.vertices.count)
            }

            // Write vertices for this group
            for v in groupVertices {
                objContent += String(format: "v %.6f %.6f %.6f\n", v.x, v.y, v.z)
            }

            // Write normals for this group
            for n in groupNormals {
                objContent += String(format: "vn %.6f %.6f %.6f\n", n.x, n.y, n.z)
            }

            objContent += "\n"

            // Write faces (OBJ uses 1-based indexing, offset by global vertex count)
            for face in groupFaces {
                let i0 = face[0] + globalVertexOffset + 1
                let i1 = face[1] + globalVertexOffset + 1
                let i2 = face[2] + globalVertexOffset + 1
                objContent += "f \(i0)//\(i0) \(i1)//\(i1) \(i2)//\(i2)\n"
            }

            globalVertexOffset += UInt32(groupVertices.count)
        }

        // Write with Unix line endings (LF only)
        let data = objContent.data(using: .utf8)!
        try data.write(to: url)

        print("[MeshExporter] OBJ exported with groups: \(groupedMeshes.filter { !$0.value.isEmpty }.keys.joined(separator: ", "))")
    }

    // MARK: - Helpers

    /// Combine all mesh anchors into single mesh with world-space transforms applied
    /// Also filters out faces that are beyond glass/window planes
    /// And filters out objectTop and backReflection surfaces (both mesh-level and face-level)
    /// Only includes vertices that are actually used by non-filtered faces
    private func combineMeshes(_ scan: CapturedScan) -> CapturedMeshData {
        // First pass: collect all valid faces and track which vertices are used
        var tempFaces: [(meshIndex: Int, localIndices: [UInt32], worldVerts: [SIMD3<Float>])] = []
        var skippedMeshCount = 0
        var filteredFaceCount = 0
        var filteredByClassificationCount = 0

        let windowPlanes = scan.windowPlanes

        for (meshIndex, mesh) in scan.meshes.enumerated() {
            // Skip entire meshes classified as objectTop or backReflection at mesh level
            if let surfaceType = mesh.surfaceType {
                if surfaceType == .objectTop || surfaceType == .backReflection {
                    skippedMeshCount += 1
                    continue
                }
            }

            // Transform all vertices to world space for this mesh
            var meshWorldVertices: [SIMD3<Float>] = []
            for vertex in mesh.vertices {
                let worldPos = mesh.transform * SIMD4<Float>(vertex, 1)
                meshWorldVertices.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
            }

            // Get per-face classifications if available
            let faceClassifications = mesh.faceClassifications

            // Check each face
            for (faceIndex, face) in mesh.faces.enumerated() {
                let idx0 = Int(face[0])
                let idx1 = Int(face[1])
                let idx2 = Int(face[2])

                guard idx0 < meshWorldVertices.count,
                      idx1 < meshWorldVertices.count,
                      idx2 < meshWorldVertices.count else { continue }

                // Check per-face classification - skip objectTop and backReflection faces
                if let classifications = faceClassifications, faceIndex < classifications.count {
                    let faceType = classifications[faceIndex]
                    if faceType == .objectTop || faceType == .backReflection {
                        filteredByClassificationCount += 1
                        continue
                    }
                }

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
                    continue
                }

                // This face is valid - store it with world vertices
                tempFaces.append((meshIndex: meshIndex, localIndices: face, worldVerts: [v0, v1, v2]))
            }
        }

        // Second pass: build final vertex/normal/color arrays with only used vertices
        var allVertices: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allColors: [VertexColor] = []
        var allFaces: [[UInt32]] = []

        // Map from (meshIndex, localVertexIndex) to global vertex index
        var vertexMap: [String: UInt32] = [:]

        for (meshIndex, mesh) in scan.meshes.enumerated() {
            // Skip meshes we already skipped
            if let surfaceType = mesh.surfaceType {
                if surfaceType == .objectTop || surfaceType == .backReflection {
                    continue
                }
            }

            // Precompute normal transform matrix
            let normalMatrix = simd_float3x3(
                SIMD3<Float>(mesh.transform.columns.0.x, mesh.transform.columns.0.y, mesh.transform.columns.0.z),
                SIMD3<Float>(mesh.transform.columns.1.x, mesh.transform.columns.1.y, mesh.transform.columns.1.z),
                SIMD3<Float>(mesh.transform.columns.2.x, mesh.transform.columns.2.y, mesh.transform.columns.2.z)
            )

            // Process faces for this mesh
            for tempFace in tempFaces where tempFace.meshIndex == meshIndex {
                var newFaceIndices: [UInt32] = []

                for (i, localIdx) in tempFace.localIndices.enumerated() {
                    let key = "\(meshIndex)_\(localIdx)"

                    if let existingGlobalIdx = vertexMap[key] {
                        newFaceIndices.append(existingGlobalIdx)
                    } else {
                        // Add this vertex
                        let globalIdx = UInt32(allVertices.count)
                        vertexMap[key] = globalIdx

                        allVertices.append(tempFace.worldVerts[i])

                        // Add normal
                        let localNormal = Int(localIdx) < mesh.normals.count ? mesh.normals[Int(localIdx)] : SIMD3<Float>(0, 1, 0)
                        allNormals.append(normalize(normalMatrix * localNormal))

                        // Add color
                        if Int(localIdx) < mesh.colors.count {
                            allColors.append(mesh.colors[Int(localIdx)])
                        }

                        newFaceIndices.append(globalIdx)
                    }
                }

                allFaces.append(newFaceIndices)
            }
        }

        if filteredFaceCount > 0 {
            print("[MeshExporter] Filtered \(filteredFaceCount) faces beyond glass/windows")
        }
        if filteredByClassificationCount > 0 {
            print("[MeshExporter] Filtered \(filteredByClassificationCount) faces classified as objectTop/backReflection")
        }
        if skippedMeshCount > 0 {
            print("[MeshExporter] Skipped \(skippedMeshCount) entire meshes classified as objectTop/backReflection")
        }
        print("[MeshExporter] Final: \(allVertices.count) vertices, \(allFaces.count) faces")

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
