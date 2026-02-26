import Foundation
import simd

/// Analyzes mesh shape characteristics for classification
class ShapeAnalyzer {

    // MARK: - Shape Analysis

    /// Analyze mesh and return detailed shape characteristics
    func analyze(meshData: MeshData) -> ShapeAnalysis {
        let vertices = extractVertices(from: meshData)
        let normals = extractNormals(from: meshData)

        let curvatureAnalysis = analyzeCurvature(meshData: meshData, normals: normals)
        let symmetryAnalysis = analyzeSymmetry(vertices: vertices)
        let edgeAnalysis = analyzeEdges(meshData: meshData)

        return ShapeAnalysis(
            curvature: curvatureAnalysis,
            symmetry: symmetryAnalysis,
            edges: edgeAnalysis
        )
    }

    // MARK: - Vertex/Normal Extraction

    private func extractVertices(from meshData: MeshData) -> [SIMD3<Float>] {
        var vertices: [SIMD3<Float>] = []
        for i in stride(from: 0, to: meshData.vertices.count, by: 3) {
            vertices.append(SIMD3<Float>(
                meshData.vertices[i],
                meshData.vertices[i + 1],
                meshData.vertices[i + 2]
            ))
        }
        return vertices
    }

    private func extractNormals(from meshData: MeshData) -> [SIMD3<Float>] {
        var normals: [SIMD3<Float>] = []
        for i in stride(from: 0, to: meshData.normals.count, by: 3) {
            normals.append(SIMD3<Float>(
                meshData.normals[i],
                meshData.normals[i + 1],
                meshData.normals[i + 2]
            ))
        }
        return normals
    }

    // MARK: - Curvature Analysis

    private func analyzeCurvature(meshData: MeshData, normals: [SIMD3<Float>]) -> CurvatureAnalysis {
        // Build adjacency information
        var vertexNormals: [Int: [SIMD3<Float>]] = [:]

        for i in stride(from: 0, to: meshData.indices.count, by: 3) {
            let indices = [
                Int(meshData.indices[i]),
                Int(meshData.indices[i + 1]),
                Int(meshData.indices[i + 2])
            ]

            // Calculate face normal
            let v0 = getVertex(meshData, index: indices[0])
            let v1 = getVertex(meshData, index: indices[1])
            let v2 = getVertex(meshData, index: indices[2])
            let faceNormal = simd_normalize(simd_cross(v1 - v0, v2 - v0))

            for idx in indices {
                if vertexNormals[idx] == nil {
                    vertexNormals[idx] = []
                }
                vertexNormals[idx]?.append(faceNormal)
            }
        }

        // Calculate curvature at each vertex based on normal variation
        var curvatures: [Float] = []

        for (_, faceNormals) in vertexNormals {
            if faceNormals.count > 1 {
                var maxAngle: Float = 0
                for i in 0..<faceNormals.count {
                    for j in (i+1)..<faceNormals.count {
                        let dot = simd_dot(faceNormals[i], faceNormals[j])
                        let angle = acos(min(max(dot, -1), 1))
                        maxAngle = max(maxAngle, angle)
                    }
                }
                curvatures.append(maxAngle)
            }
        }

        guard !curvatures.isEmpty else {
            return CurvatureAnalysis(
                meanCurvature: 0,
                maxCurvature: 0,
                minCurvature: 0,
                curvatureVariance: 0,
                flatRegionRatio: 1.0
            )
        }

        let meanCurvature = curvatures.reduce(0, +) / Float(curvatures.count)
        let maxCurvature = curvatures.max() ?? 0
        let minCurvature = curvatures.min() ?? 0

        let variance = curvatures.reduce(0) { $0 + pow($1 - meanCurvature, 2) } / Float(curvatures.count)

        let flatThreshold: Float = 0.1 // ~5.7 degrees
        let flatCount = curvatures.filter { $0 < flatThreshold }.count
        let flatRegionRatio = Float(flatCount) / Float(curvatures.count)

        return CurvatureAnalysis(
            meanCurvature: meanCurvature,
            maxCurvature: maxCurvature,
            minCurvature: minCurvature,
            curvatureVariance: variance,
            flatRegionRatio: flatRegionRatio
        )
    }

    private func getVertex(_ meshData: MeshData, index: Int) -> SIMD3<Float> {
        SIMD3<Float>(
            meshData.vertices[index * 3],
            meshData.vertices[index * 3 + 1],
            meshData.vertices[index * 3 + 2]
        )
    }

    // MARK: - Symmetry Analysis

    private func analyzeSymmetry(vertices: [SIMD3<Float>]) -> SymmetryAnalysis {
        guard !vertices.isEmpty else {
            return SymmetryAnalysis(
                hasXSymmetry: false,
                hasYSymmetry: false,
                hasZSymmetry: false,
                rotationalSymmetryOrder: 1,
                symmetryScore: 0
            )
        }

        // Calculate centroid
        let centroid = vertices.reduce(.zero, +) / Float(vertices.count)
        let centered = vertices.map { $0 - centroid }

        // Check reflection symmetry for each axis
        let xSymmetry = checkReflectionSymmetry(centered, axis: SIMD3<Float>(1, 0, 0))
        let ySymmetry = checkReflectionSymmetry(centered, axis: SIMD3<Float>(0, 1, 0))
        let zSymmetry = checkReflectionSymmetry(centered, axis: SIMD3<Float>(0, 0, 1))

        // Check rotational symmetry
        let rotationalOrder = checkRotationalSymmetry(centered)

        // Calculate overall symmetry score
        let symmetryScore = (
            (xSymmetry ? 1.0 : 0.0) +
            (ySymmetry ? 1.0 : 0.0) +
            (zSymmetry ? 1.0 : 0.0) +
            Float(rotationalOrder - 1) * 0.5
        ) / 4.5

        return SymmetryAnalysis(
            hasXSymmetry: xSymmetry,
            hasYSymmetry: ySymmetry,
            hasZSymmetry: zSymmetry,
            rotationalSymmetryOrder: rotationalOrder,
            symmetryScore: symmetryScore
        )
    }

    private func checkReflectionSymmetry(_ vertices: [SIMD3<Float>], axis: SIMD3<Float>) -> Bool {
        let tolerance: Float = 0.01 // 1cm tolerance

        var matchCount = 0
        for v in vertices {
            // Reflect vertex
            let reflected = v - 2 * simd_dot(v, axis) * axis

            // Check if reflected point exists
            let hasMatch = vertices.contains { other in
                simd_length(other - reflected) < tolerance
            }
            if hasMatch {
                matchCount += 1
            }
        }

        return Float(matchCount) / Float(vertices.count) > 0.8
    }

    private func checkRotationalSymmetry(_ vertices: [SIMD3<Float>]) -> Int {
        // Check common rotational symmetry orders (2, 3, 4, 6)
        let orders = [6, 4, 3, 2]
        let tolerance: Float = 0.02

        for order in orders {
            let angle = 2 * Float.pi / Float(order)
            let rotation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0)) // Y-axis rotation

            var matchCount = 0
            for v in vertices {
                let rotated = rotation.act(v)
                let hasMatch = vertices.contains { other in
                    simd_length(other - rotated) < tolerance
                }
                if hasMatch {
                    matchCount += 1
                }
            }

            if Float(matchCount) / Float(vertices.count) > 0.7 {
                return order
            }
        }

        return 1 // No rotational symmetry
    }

    // MARK: - Edge Analysis

    private func analyzeEdges(meshData: MeshData) -> EdgeAnalysis {
        // Build edge map
        var edges: [Edge: Int] = [:]

        for i in stride(from: 0, to: meshData.indices.count, by: 3) {
            let indices = [
                Int(meshData.indices[i]),
                Int(meshData.indices[i + 1]),
                Int(meshData.indices[i + 2])
            ]

            for j in 0..<3 {
                let edge = Edge(min(indices[j], indices[(j + 1) % 3]),
                               max(indices[j], indices[(j + 1) % 3]))
                edges[edge, default: 0] += 1
            }
        }

        // Count edge types
        let boundaryEdges = edges.filter { $0.value == 1 }.count
        let manifoldEdges = edges.filter { $0.value == 2 }.count
        let nonManifoldEdges = edges.filter { $0.value > 2 }.count

        // Calculate sharp edges (based on normal angle)
        var sharpEdgeCount = 0
        let sharpThreshold: Float = 0.7 // ~45 degrees

        for (edge, count) in edges where count == 2 {
            let v0 = getVertex(meshData, index: edge.v0)
            let v1 = getVertex(meshData, index: edge.v1)
            let edgeDir = simd_normalize(v1 - v0)

            // Get adjacent face normals (simplified)
            let n0 = getNormal(meshData, index: edge.v0)
            let n1 = getNormal(meshData, index: edge.v1)

            let dot = simd_dot(n0, n1)
            if dot < sharpThreshold {
                sharpEdgeCount += 1
            }
        }

        return EdgeAnalysis(
            totalEdges: edges.count,
            boundaryEdges: boundaryEdges,
            sharpEdges: sharpEdgeCount,
            manifoldEdges: manifoldEdges,
            nonManifoldEdges: nonManifoldEdges,
            isWatertight: boundaryEdges == 0
        )
    }

    private func getNormal(_ meshData: MeshData, index: Int) -> SIMD3<Float> {
        guard index * 3 + 2 < meshData.normals.count else { return .zero }
        return SIMD3<Float>(
            meshData.normals[index * 3],
            meshData.normals[index * 3 + 1],
            meshData.normals[index * 3 + 2]
        )
    }
}

// MARK: - Supporting Types

struct ShapeAnalysis {
    let curvature: CurvatureAnalysis
    let symmetry: SymmetryAnalysis
    let edges: EdgeAnalysis
}

struct CurvatureAnalysis {
    let meanCurvature: Float
    let maxCurvature: Float
    let minCurvature: Float
    let curvatureVariance: Float
    let flatRegionRatio: Float

    var isHighlyCurved: Bool {
        meanCurvature > 0.5 // ~28 degrees average
    }

    var isMostlyFlat: Bool {
        flatRegionRatio > 0.7
    }
}

struct SymmetryAnalysis {
    let hasXSymmetry: Bool
    let hasYSymmetry: Bool
    let hasZSymmetry: Bool
    let rotationalSymmetryOrder: Int
    let symmetryScore: Float

    var symmetryAxesCount: Int {
        [hasXSymmetry, hasYSymmetry, hasZSymmetry].filter { $0 }.count
    }

    var isHighlySymmetric: Bool {
        symmetryScore > 0.7
    }
}

struct EdgeAnalysis {
    let totalEdges: Int
    let boundaryEdges: Int
    let sharpEdges: Int
    let manifoldEdges: Int
    let nonManifoldEdges: Int
    let isWatertight: Bool

    var sharpEdgeRatio: Float {
        Float(sharpEdges) / max(Float(totalEdges), 1)
    }
}

struct Edge: Hashable {
    let v0: Int
    let v1: Int

    init(_ v0: Int, _ v1: Int) {
        self.v0 = v0
        self.v1 = v1
    }
}
