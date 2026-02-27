import Foundation
import simd

enum ImportError: LocalizedError {
    case unsupportedFormat
    case fileNotReadable
    case invalidFormat(String)
    case noVertices

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Unsupported file format. Use PLY or OBJ."
        case .fileNotReadable:
            return "Could not read file."
        case .invalidFormat(let detail):
            return "Invalid file format: \(detail)"
        case .noVertices:
            return "No vertices found in file."
        }
    }
}

@MainActor
class MeshImporter: ObservableObject {
    @Published var isImporting = false
    @Published var importProgress: Float = 0.0
    @Published var lastError: String?

    /// Import mesh from file URL
    func importMesh(from url: URL) async throws -> CapturedScan {
        isImporting = true
        importProgress = 0.0
        lastError = nil

        defer { isImporting = false }

        // Start accessing security-scoped resource
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let ext = url.pathExtension.lowercased()

        do {
            let scan: CapturedScan
            switch ext {
            case "ply":
                scan = try await importPLY(from: url)
            case "obj":
                scan = try await importOBJ(from: url)
            default:
                throw ImportError.unsupportedFormat
            }

            importProgress = 1.0
            return scan
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: - PLY Import

    private func importPLY(from url: URL) async throws -> CapturedScan {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw ImportError.fileNotReadable
        }

        let lines = content.components(separatedBy: .newlines)
        var lineIndex = 0

        // Parse header
        var vertexCount = 0
        var faceCount = 0
        var hasNormals = false
        var hasColors = false
        var inHeader = true

        while lineIndex < lines.count && inHeader {
            let line = lines[lineIndex].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("element vertex") {
                let parts = line.split(separator: " ")
                if parts.count >= 3, let count = Int(parts[2]) {
                    vertexCount = count
                }
            } else if line.hasPrefix("element face") {
                let parts = line.split(separator: " ")
                if parts.count >= 3, let count = Int(parts[2]) {
                    faceCount = count
                }
            } else if line.contains("property") && line.contains("nx") {
                hasNormals = true
            } else if line.contains("property") && (line.contains("red") || line.contains("diffuse_red")) {
                hasColors = true
            } else if line == "end_header" {
                inHeader = false
            }

            lineIndex += 1
        }

        guard vertexCount > 0 else {
            throw ImportError.noVertices
        }

        // Parse vertices
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [VertexColor] = []

        for i in 0..<vertexCount {
            guard lineIndex + i < lines.count else { break }
            let line = lines[lineIndex + i]
            let parts = line.split(separator: " ").compactMap { Float($0) }

            guard parts.count >= 3 else { continue }

            vertices.append(SIMD3<Float>(parts[0], parts[1], parts[2]))

            if hasNormals && parts.count >= 6 {
                normals.append(SIMD3<Float>(parts[3], parts[4], parts[5]))
            }

            if hasColors {
                let colorOffset = hasNormals ? 6 : 3
                if parts.count >= colorOffset + 3 {
                    // Colors might be 0-255 or 0-1
                    let r = parts[colorOffset]
                    let g = parts[colorOffset + 1]
                    let b = parts[colorOffset + 2]

                    if r > 1 || g > 1 || b > 1 {
                        // 0-255 range
                        colors.append(VertexColor(r: r / 255.0, g: g / 255.0, b: b / 255.0))
                    } else {
                        colors.append(VertexColor(r: r, g: g, b: b))
                    }
                }
            }

            // Update progress
            if i % 1000 == 0 {
                importProgress = Float(i) / Float(vertexCount + faceCount) * 0.8
            }
        }

        lineIndex += vertexCount

        // Fill in normals if missing
        if normals.isEmpty {
            normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: vertices.count)
        }

        // Parse faces
        var faces: [[UInt32]] = []

        for i in 0..<faceCount {
            guard lineIndex + i < lines.count else { break }
            let line = lines[lineIndex + i]
            let parts = line.split(separator: " ").compactMap { Int($0) }

            guard parts.count >= 4 else { continue }

            let faceVertexCount = parts[0]
            if faceVertexCount == 3 && parts.count >= 4 {
                faces.append([UInt32(parts[1]), UInt32(parts[2]), UInt32(parts[3])])
            } else if faceVertexCount == 4 && parts.count >= 5 {
                // Quad - split into two triangles
                faces.append([UInt32(parts[1]), UInt32(parts[2]), UInt32(parts[3])])
                faces.append([UInt32(parts[1]), UInt32(parts[3]), UInt32(parts[4])])
            }

            if i % 1000 == 0 {
                importProgress = 0.8 + Float(i) / Float(faceCount) * 0.2
            }
        }

        let meshData = CapturedMeshData(
            vertices: vertices,
            normals: normals,
            colors: colors,
            faces: faces,
            transform: matrix_identity_float4x4,
            identifier: UUID()
        )

        return CapturedScan(meshes: [meshData], startTime: Date())
    }

    // MARK: - OBJ Import

    private func importOBJ(from url: URL) async throws -> CapturedScan {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw ImportError.fileNotReadable
        }

        let lines = content.components(separatedBy: .newlines)

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [[UInt32]] = []

        let totalLines = lines.count

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("v ") {
                // Vertex
                let parts = trimmed.dropFirst(2).split(separator: " ").compactMap { Float($0) }
                if parts.count >= 3 {
                    vertices.append(SIMD3<Float>(parts[0], parts[1], parts[2]))
                }
            } else if trimmed.hasPrefix("vn ") {
                // Normal
                let parts = trimmed.dropFirst(3).split(separator: " ").compactMap { Float($0) }
                if parts.count >= 3 {
                    normals.append(SIMD3<Float>(parts[0], parts[1], parts[2]))
                }
            } else if trimmed.hasPrefix("f ") {
                // Face - OBJ uses 1-based indexing
                // Format can be: f v1 v2 v3, f v1/vt1 v2/vt2, f v1/vt1/vn1, or f v1//vn1
                let parts = trimmed.dropFirst(2).split(separator: " ")
                var faceIndices: [UInt32] = []

                for part in parts {
                    // Take only the vertex index (first number before any /)
                    let indexStr = part.split(separator: "/").first ?? part
                    if let idx = Int(indexStr), idx > 0 {
                        faceIndices.append(UInt32(idx - 1))  // Convert to 0-based
                    }
                }

                if faceIndices.count == 3 {
                    faces.append(faceIndices)
                } else if faceIndices.count == 4 {
                    // Quad - split into two triangles
                    faces.append([faceIndices[0], faceIndices[1], faceIndices[2]])
                    faces.append([faceIndices[0], faceIndices[2], faceIndices[3]])
                } else if faceIndices.count > 4 {
                    // N-gon - fan triangulation
                    for i in 1..<(faceIndices.count - 1) {
                        faces.append([faceIndices[0], faceIndices[i], faceIndices[i + 1]])
                    }
                }
            }

            if index % 1000 == 0 {
                importProgress = Float(index) / Float(totalLines)
            }
        }

        guard !vertices.isEmpty else {
            throw ImportError.noVertices
        }

        // Fill in normals if missing or wrong count
        if normals.isEmpty || normals.count != vertices.count {
            normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: vertices.count)
        }

        let meshData = CapturedMeshData(
            vertices: vertices,
            normals: normals,
            colors: [],
            faces: faces,
            transform: matrix_identity_float4x4,
            identifier: UUID()
        )

        return CapturedScan(meshes: [meshData], startTime: Date())
    }
}
