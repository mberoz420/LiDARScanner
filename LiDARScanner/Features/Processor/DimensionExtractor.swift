import Foundation
import simd
import Accelerate

/// Extracts dimensions and metrics from mesh data
class DimensionExtractor {

    // MARK: - Main Extraction

    /// Extract all metrics from mesh data
    func extractMetrics(from meshData: MeshData) -> ObjectMetrics {
        let vertices = extractVertices(from: meshData)

        // Calculate oriented bounding box
        let obb = calculateOBB(vertices: vertices)

        // Calculate volume and surface area
        let volume = calculateVolume(meshData: meshData)
        let surfaceArea = calculateSurfaceArea(meshData: meshData)

        // Detect primitive shape
        let primitiveType = detectPrimitiveShape(meshData: meshData, obb: obb)

        // Generate feature descriptor
        let featureDescriptor = generateFeatureDescriptor(
            meshData: meshData,
            obb: obb,
            volume: volume,
            surfaceArea: surfaceArea
        )

        return ObjectMetrics(
            dimensions: obb.extent,
            volume: volume,
            surfaceArea: surfaceArea,
            primitiveType: primitiveType,
            featureDescriptor: featureDescriptor,
            center: obb.center,
            rotation: obb.rotation
        )
    }

    // MARK: - Vertex Extraction

    private func extractVertices(from meshData: MeshData) -> [SIMD3<Float>] {
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(meshData.vertexCount)

        for i in stride(from: 0, to: meshData.vertices.count, by: 3) {
            vertices.append(SIMD3<Float>(
                meshData.vertices[i],
                meshData.vertices[i + 1],
                meshData.vertices[i + 2]
            ))
        }

        return vertices
    }

    // MARK: - Oriented Bounding Box

    /// Calculate oriented bounding box using PCA
    func calculateOBB(vertices: [SIMD3<Float>]) -> OBB {
        guard !vertices.isEmpty else {
            return OBB(center: .zero, extent: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        }

        // Calculate centroid
        let centroid = vertices.reduce(.zero, +) / Float(vertices.count)

        // Center the vertices
        let centered = vertices.map { $0 - centroid }

        // Calculate covariance matrix
        var covariance = simd_float3x3(0)
        for v in centered {
            covariance[0][0] += v.x * v.x
            covariance[0][1] += v.x * v.y
            covariance[0][2] += v.x * v.z
            covariance[1][0] += v.y * v.x
            covariance[1][1] += v.y * v.y
            covariance[1][2] += v.y * v.z
            covariance[2][0] += v.z * v.x
            covariance[2][1] += v.z * v.y
            covariance[2][2] += v.z * v.z
        }
        covariance = covariance * (1.0 / Float(vertices.count))

        // Perform eigendecomposition (simplified - using power iteration)
        let (eigenVectors, _) = eigenDecomposition(covariance)

        // Create rotation quaternion from eigenvectors
        let rotation = simd_quatf(eigenVectors)

        // Transform vertices to OBB space
        let invRotation = rotation.inverse
        let transformedVertices = centered.map { invRotation.act($0) }

        // Calculate axis-aligned extent in OBB space
        var minBound = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBound = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        for v in transformedVertices {
            minBound = simd_min(minBound, v)
            maxBound = simd_max(maxBound, v)
        }

        let extent = maxBound - minBound
        let obbCenter = centroid + rotation.act((minBound + maxBound) / 2)

        return OBB(center: obbCenter, extent: extent, rotation: rotation)
    }

    /// Simplified eigendecomposition using power iteration
    private func eigenDecomposition(_ matrix: simd_float3x3) -> (simd_float3x3, SIMD3<Float>) {
        // Power iteration to find principal eigenvector
        var v1 = SIMD3<Float>(1, 0, 0)
        for _ in 0..<20 {
            v1 = simd_normalize(matrix * v1)
        }

        // Deflate and find second eigenvector
        let lambda1 = simd_dot(v1, matrix * v1)
        let deflated1 = matrix - lambda1 * simd_float3x3(columns: (
            v1 * v1.x, v1 * v1.y, v1 * v1.z
        ))

        var v2 = SIMD3<Float>(0, 1, 0)
        for _ in 0..<20 {
            v2 = simd_normalize(deflated1 * v2)
        }

        // Third eigenvector is cross product
        let v3 = simd_cross(v1, v2)
        let lambda2 = simd_dot(v2, matrix * v2)
        let lambda3 = simd_dot(v3, matrix * v3)

        return (simd_float3x3(columns: (v1, v2, v3)), SIMD3<Float>(lambda1, lambda2, lambda3))
    }

    // MARK: - Volume Calculation

    /// Calculate mesh volume using signed tetrahedron method
    func calculateVolume(meshData: MeshData) -> Float {
        var volume: Float = 0

        for i in stride(from: 0, to: meshData.indices.count, by: 3) {
            let i1 = Int(meshData.indices[i])
            let i2 = Int(meshData.indices[i + 1])
            let i3 = Int(meshData.indices[i + 2])

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

            // Signed volume of tetrahedron with origin
            volume += simd_dot(v1, simd_cross(v2, v3)) / 6.0
        }

        return abs(volume)
    }

    // MARK: - Surface Area Calculation

    /// Calculate total surface area
    func calculateSurfaceArea(meshData: MeshData) -> Float {
        var area: Float = 0

        for i in stride(from: 0, to: meshData.indices.count, by: 3) {
            let i1 = Int(meshData.indices[i])
            let i2 = Int(meshData.indices[i + 1])
            let i3 = Int(meshData.indices[i + 2])

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

            // Triangle area = 0.5 * |cross product of edges|
            let edge1 = v2 - v1
            let edge2 = v3 - v1
            area += simd_length(simd_cross(edge1, edge2)) / 2.0
        }

        return area
    }

    // MARK: - Primitive Shape Detection

    /// Detect primitive shape type
    func detectPrimitiveShape(meshData: MeshData, obb: OBB) -> PrimitiveShape {
        let extent = obb.extent

        // Calculate aspect ratios
        let sortedExtent = [extent.x, extent.y, extent.z].sorted()
        let aspectRatio1 = sortedExtent[2] / max(sortedExtent[1], 0.001)
        let aspectRatio2 = sortedExtent[1] / max(sortedExtent[0], 0.001)

        // Calculate sphericity
        let volume = calculateVolume(meshData: meshData)
        let surfaceArea = calculateSurfaceArea(meshData: meshData)
        let sphericity = calculateSphericity(volume: volume, surfaceArea: surfaceArea)

        // Analyze normal distribution
        let normalVariance = analyzeNormalDistribution(meshData: meshData)

        // Classification rules
        if sphericity > 0.9 && normalVariance > 0.8 {
            return .sphere
        }

        if aspectRatio1 > 3.0 && aspectRatio2 < 1.5 {
            // Long and thin - could be cylinder
            if normalVariance > 0.5 {
                return .cylinder
            }
        }

        if aspectRatio1 < 1.3 && aspectRatio2 < 1.3 && sphericity > 0.5 {
            return .box
        }

        if sortedExtent[0] < 0.01 { // Very thin in one dimension
            return .plane
        }

        return .complex
    }

    /// Calculate sphericity (how sphere-like the object is)
    private func calculateSphericity(volume: Float, surfaceArea: Float) -> Float {
        // Sphericity = (π^(1/3) * (6V)^(2/3)) / A
        let numerator = pow(Float.pi, 1.0/3.0) * pow(6.0 * volume, 2.0/3.0)
        return numerator / max(surfaceArea, 0.001)
    }

    /// Analyze variance in normal directions
    private func analyzeNormalDistribution(meshData: MeshData) -> Float {
        guard meshData.normals.count >= 3 else { return 0 }

        var normals: [SIMD3<Float>] = []
        for i in stride(from: 0, to: meshData.normals.count, by: 3) {
            normals.append(SIMD3<Float>(
                meshData.normals[i],
                meshData.normals[i + 1],
                meshData.normals[i + 2]
            ))
        }

        // Calculate mean normal
        let meanNormal = simd_normalize(normals.reduce(.zero, +))

        // Calculate variance from mean
        var variance: Float = 0
        for normal in normals {
            let diff = simd_length(normal - meanNormal)
            variance += diff * diff
        }
        variance /= Float(normals.count)

        // Normalize to 0-1 range (max variance is 4 for opposite normals)
        return min(variance / 4.0, 1.0)
    }

    // MARK: - Feature Descriptor

    /// Generate feature descriptor for shape matching
    func generateFeatureDescriptor(
        meshData: MeshData,
        obb: OBB,
        volume: Float,
        surfaceArea: Float
    ) -> [Float] {
        var features: [Float] = []

        // Normalized dimensions (sorted)
        let extent = obb.extent
        let maxDim = max(extent.x, max(extent.y, extent.z))
        let normalizedExtent = extent / max(maxDim, 0.001)
        let sortedDims = [normalizedExtent.x, normalizedExtent.y, normalizedExtent.z].sorted()
        features.append(contentsOf: sortedDims)

        // Aspect ratios
        features.append(sortedDims[2] / max(sortedDims[1], 0.001))
        features.append(sortedDims[1] / max(sortedDims[0], 0.001))

        // Volume ratio (actual volume / OBB volume)
        let obbVolume = extent.x * extent.y * extent.z
        features.append(volume / max(obbVolume, 0.001))

        // Sphericity
        features.append(calculateSphericity(volume: volume, surfaceArea: surfaceArea))

        // Normal distribution variance
        features.append(analyzeNormalDistribution(meshData: meshData))

        // Vertex density (vertices per unit volume)
        features.append(Float(meshData.vertexCount) / max(volume * 1e6, 1.0))

        return features
    }
}

// MARK: - OBB Structure

struct OBB {
    let center: SIMD3<Float>
    let extent: SIMD3<Float>
    let rotation: simd_quatf

    /// Get corner points of the OBB
    var corners: [SIMD3<Float>] {
        let halfExtent = extent / 2
        let offsets: [SIMD3<Float>] = [
            SIMD3<Float>(-1, -1, -1),
            SIMD3<Float>(-1, -1,  1),
            SIMD3<Float>(-1,  1, -1),
            SIMD3<Float>(-1,  1,  1),
            SIMD3<Float>( 1, -1, -1),
            SIMD3<Float>( 1, -1,  1),
            SIMD3<Float>( 1,  1, -1),
            SIMD3<Float>( 1,  1,  1)
        ]

        return offsets.map { offset in
            center + rotation.act(offset * halfExtent)
        }
    }

    /// Check if point is inside OBB
    func contains(_ point: SIMD3<Float>) -> Bool {
        let local = rotation.inverse.act(point - center)
        let halfExtent = extent / 2
        return abs(local.x) <= halfExtent.x &&
               abs(local.y) <= halfExtent.y &&
               abs(local.z) <= halfExtent.z
    }
}
