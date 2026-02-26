import Foundation
import simd

/// Generates feature descriptors for shape matching and comparison
class FeatureDescriptor {

    // MARK: - Shape Histogram

    /// Generate a shape distribution histogram (D2 descriptor)
    /// Based on distance between random point pairs on the surface
    func generateD2Histogram(meshData: MeshData, bins: Int = 64) -> [Float] {
        let sampleCount = min(meshData.vertexCount, 1000)
        var distances: [Float] = []

        // Sample random vertex pairs
        for _ in 0..<(sampleCount * 10) {
            let i1 = Int.random(in: 0..<meshData.vertexCount)
            let i2 = Int.random(in: 0..<meshData.vertexCount)

            if i1 != i2 {
                let v1 = getVertex(meshData, index: i1)
                let v2 = getVertex(meshData, index: i2)
                distances.append(simd_length(v2 - v1))
            }
        }

        return createHistogram(values: distances, bins: bins)
    }

    /// Generate angle histogram (A3 descriptor)
    /// Based on angles formed by random point triplets
    func generateA3Histogram(meshData: MeshData, bins: Int = 64) -> [Float] {
        let sampleCount = min(meshData.vertexCount, 500)
        var angles: [Float] = []

        for _ in 0..<(sampleCount * 5) {
            let i1 = Int.random(in: 0..<meshData.vertexCount)
            let i2 = Int.random(in: 0..<meshData.vertexCount)
            let i3 = Int.random(in: 0..<meshData.vertexCount)

            if i1 != i2 && i2 != i3 && i1 != i3 {
                let v1 = getVertex(meshData, index: i1)
                let v2 = getVertex(meshData, index: i2)
                let v3 = getVertex(meshData, index: i3)

                let edge1 = simd_normalize(v1 - v2)
                let edge2 = simd_normalize(v3 - v2)
                let angle = acos(min(max(simd_dot(edge1, edge2), -1), 1))
                angles.append(angle)
            }
        }

        return createHistogram(values: angles, bins: bins)
    }

    /// Generate area histogram (D3 descriptor)
    /// Based on square root of area of random triangles
    func generateD3Histogram(meshData: MeshData, bins: Int = 64) -> [Float] {
        let sampleCount = min(meshData.vertexCount, 500)
        var areas: [Float] = []

        for _ in 0..<(sampleCount * 5) {
            let i1 = Int.random(in: 0..<meshData.vertexCount)
            let i2 = Int.random(in: 0..<meshData.vertexCount)
            let i3 = Int.random(in: 0..<meshData.vertexCount)

            if i1 != i2 && i2 != i3 && i1 != i3 {
                let v1 = getVertex(meshData, index: i1)
                let v2 = getVertex(meshData, index: i2)
                let v3 = getVertex(meshData, index: i3)

                let area = simd_length(simd_cross(v2 - v1, v3 - v1)) / 2
                areas.append(sqrt(area))
            }
        }

        return createHistogram(values: areas, bins: bins)
    }

    // MARK: - Combined Descriptor

    /// Generate combined shape descriptor
    func generateCombinedDescriptor(
        meshData: MeshData,
        metrics: ObjectMetrics
    ) -> ShapeDescriptor {
        let d2 = generateD2Histogram(meshData: meshData, bins: 32)
        let a3 = generateA3Histogram(meshData: meshData, bins: 32)
        let d3 = generateD3Histogram(meshData: meshData, bins: 32)

        // Normalized dimensions
        let maxDim = max(metrics.dimensions.x, max(metrics.dimensions.y, metrics.dimensions.z))
        let normalizedDims = metrics.dimensions / max(maxDim, 0.001)

        return ShapeDescriptor(
            d2Histogram: d2,
            a3Histogram: a3,
            d3Histogram: d3,
            normalizedDimensions: normalizedDims,
            volume: metrics.volume,
            surfaceArea: metrics.surfaceArea,
            primitiveType: metrics.primitiveType
        )
    }

    // MARK: - Descriptor Comparison

    /// Compare two shape descriptors and return similarity score (0-1)
    func compare(_ desc1: ShapeDescriptor, _ desc2: ShapeDescriptor) -> Float {
        // Histogram comparison using Earth Mover's Distance approximation
        let d2Similarity = histogramSimilarity(desc1.d2Histogram, desc2.d2Histogram)
        let a3Similarity = histogramSimilarity(desc1.a3Histogram, desc2.a3Histogram)
        let d3Similarity = histogramSimilarity(desc1.d3Histogram, desc2.d3Histogram)

        // Dimension similarity
        let dimDiff = simd_length(desc1.normalizedDimensions - desc2.normalizedDimensions)
        let dimSimilarity = max(0, 1 - dimDiff)

        // Primitive type match
        let typeSimilarity: Float = desc1.primitiveType == desc2.primitiveType ? 1.0 : 0.5

        // Weighted combination
        let weights: [Float] = [0.25, 0.2, 0.2, 0.2, 0.15]
        let similarities = [d2Similarity, a3Similarity, d3Similarity, dimSimilarity, typeSimilarity]

        return zip(weights, similarities).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// Calculate histogram intersection similarity
    private func histogramSimilarity(_ h1: [Float], _ h2: [Float]) -> Float {
        guard h1.count == h2.count else { return 0 }

        var intersection: Float = 0
        var union: Float = 0

        for i in 0..<h1.count {
            intersection += min(h1[i], h2[i])
            union += max(h1[i], h2[i])
        }

        return union > 0 ? intersection / union : 0
    }

    // MARK: - Helpers

    private func getVertex(_ meshData: MeshData, index: Int) -> SIMD3<Float> {
        SIMD3<Float>(
            meshData.vertices[index * 3],
            meshData.vertices[index * 3 + 1],
            meshData.vertices[index * 3 + 2]
        )
    }

    private func createHistogram(values: [Float], bins: Int) -> [Float] {
        guard !values.isEmpty else { return Array(repeating: 0, count: bins) }

        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 1
        let range = maxVal - minVal

        guard range > 0 else { return Array(repeating: 0, count: bins) }

        var histogram = Array(repeating: Float(0), count: bins)

        for value in values {
            let normalizedValue = (value - minVal) / range
            let binIndex = min(Int(normalizedValue * Float(bins)), bins - 1)
            histogram[binIndex] += 1
        }

        // Normalize histogram
        let total = histogram.reduce(0, +)
        if total > 0 {
            histogram = histogram.map { $0 / total }
        }

        return histogram
    }
}

// MARK: - Shape Descriptor

struct ShapeDescriptor: Codable {
    let d2Histogram: [Float]
    let a3Histogram: [Float]
    let d3Histogram: [Float]
    let normalizedDimensions: SIMD3<Float>
    let volume: Float
    let surfaceArea: Float
    let primitiveType: PrimitiveShape

    /// Combined feature vector for ML/search
    var featureVector: [Float] {
        var vector = d2Histogram
        vector.append(contentsOf: a3Histogram)
        vector.append(contentsOf: d3Histogram)
        vector.append(contentsOf: [normalizedDimensions.x, normalizedDimensions.y, normalizedDimensions.z])
        vector.append(volume)
        vector.append(surfaceArea)
        return vector
    }
}

// MARK: - Descriptor Database

/// Simple in-memory descriptor database for matching
class DescriptorDatabase {
    private var entries: [(id: String, name: String, descriptor: ShapeDescriptor)] = []
    private let featureDescriptor = FeatureDescriptor()

    func addEntry(id: String, name: String, descriptor: ShapeDescriptor) {
        entries.append((id, name, descriptor))
    }

    func findMatches(for descriptor: ShapeDescriptor, topK: Int = 5, threshold: Float = 0.5) -> [(id: String, name: String, similarity: Float)] {
        var matches: [(id: String, name: String, similarity: Float)] = []

        for entry in entries {
            let similarity = featureDescriptor.compare(descriptor, entry.descriptor)
            if similarity >= threshold {
                matches.append((entry.id, entry.name, similarity))
            }
        }

        // Sort by similarity descending
        matches.sort { $0.similarity > $1.similarity }

        return Array(matches.prefix(topK))
    }

    func clear() {
        entries.removeAll()
    }

    var count: Int {
        entries.count
    }
}
