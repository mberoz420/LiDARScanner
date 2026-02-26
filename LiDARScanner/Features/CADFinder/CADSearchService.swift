import Foundation

/// Orchestrates CAD file search across multiple providers
class CADSearchService {

    // MARK: - Providers
    private let providers: [CADProvider]

    // MARK: - Configuration
    struct Configuration {
        var enabledSources: Set<CADSource> = [.grabcad, .traceparts, .thingiverse]
        var maxResultsPerSource = 10
        var preferredFormats: [CADFormat] = [.step, .stl, .obj]
        var searchTimeout: TimeInterval = 30
    }

    var configuration = Configuration()

    // MARK: - Initialization

    init() {
        providers = [
            GrabCADProvider(),
            TracePartsProvider(),
            ThingiverseProvider()
        ]
    }

    // MARK: - Search

    /// Search for CAD files matching the identification results
    func search(
        identificationResults: [IdentificationResult],
        metrics: ObjectMetrics? = nil
    ) async throws -> [CADSearchResult] {
        // Generate search queries from identification results
        let queries = generateSearchQueries(from: identificationResults, metrics: metrics)

        var allResults: [CADSearchResult] = []

        // Search all enabled providers in parallel
        await withTaskGroup(of: [CADSearchResult].self) { group in
            for provider in providers {
                guard configuration.enabledSources.contains(provider.source) else { continue }

                for query in queries {
                    group.addTask {
                        do {
                            let files = try await provider.search(
                                query: query.text,
                                maxResults: self.configuration.maxResultsPerSource
                            )

                            return files.map { file in
                                CADSearchResult(
                                    file: file,
                                    relevanceScore: self.calculateRelevance(
                                        file: file,
                                        query: query,
                                        metrics: metrics
                                    ),
                                    matchType: query.matchType
                                )
                            }
                        } catch {
                            print("Search failed for \(provider.source.rawValue): \(error)")
                            return []
                        }
                    }
                }
            }

            for await results in group {
                allResults.append(contentsOf: results)
            }
        }

        // Remove duplicates and sort by relevance
        let uniqueResults = removeDuplicates(allResults)
        return uniqueResults.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    /// Search by specific dimensions
    func searchByDimensions(
        dimensions: SIMD3<Float>,
        tolerance: Float = 0.1,
        category: ObjectCategory? = nil
    ) async throws -> [CADSearchResult] {
        // Build dimension-based query
        let dimsMM = dimensions * 1000
        var query = "\(Int(dimsMM.x))x\(Int(dimsMM.y))x\(Int(dimsMM.z))mm"

        if let cat = category {
            query += " \(cat.rawValue)"
        }

        var allResults: [CADSearchResult] = []

        for provider in providers {
            guard configuration.enabledSources.contains(provider.source) else { continue }

            do {
                let files = try await provider.search(
                    query: query,
                    maxResults: configuration.maxResultsPerSource
                )

                let results = files.compactMap { file -> CADSearchResult? in
                    // Filter by dimension match if file has dimensions
                    if let fileDims = file.dimensions {
                        let diff = simd_length(fileDims - dimensions)
                        let maxDim = max(dimensions.x, max(dimensions.y, dimensions.z))
                        if diff / maxDim > tolerance {
                            return nil
                        }
                    }

                    return CADSearchResult(
                        file: file,
                        relevanceScore: 0.8,
                        matchType: .dimensionMatch
                    )
                }

                allResults.append(contentsOf: results)
            } catch {
                print("Dimension search failed for \(provider.source.rawValue): \(error)")
            }
        }

        return allResults.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    // MARK: - Query Generation

    private func generateSearchQueries(
        from results: [IdentificationResult],
        metrics: ObjectMetrics?
    ) -> [SearchQuery] {
        var queries: [SearchQuery] = []

        // From identification results
        for result in results.prefix(3) {
            queries.append(SearchQuery(
                text: result.name,
                matchType: .nameMatch,
                weight: result.confidence
            ))

            // Add related terms
            for term in result.relatedSearchTerms.prefix(2) {
                queries.append(SearchQuery(
                    text: term,
                    matchType: .categoryMatch,
                    weight: result.confidence * 0.8
                ))
            }
        }

        // From dimensions
        if let metrics = metrics {
            let dimsMM = metrics.dimensionsMM
            let dimQuery = "\(Int(dimsMM.x))mm \(metrics.primitiveType.rawValue)"
            queries.append(SearchQuery(
                text: dimQuery,
                matchType: .dimensionMatch,
                weight: 0.6
            ))
        }

        // Remove duplicates
        var seen = Set<String>()
        return queries.filter { query in
            let normalized = query.text.lowercased()
            if seen.contains(normalized) {
                return false
            }
            seen.insert(normalized)
            return true
        }
    }

    // MARK: - Relevance Calculation

    private func calculateRelevance(
        file: CADFile,
        query: SearchQuery,
        metrics: ObjectMetrics?
    ) -> Float {
        var score = query.weight

        // Boost for preferred formats
        if configuration.preferredFormats.contains(file.format) {
            score *= 1.2
        }

        // Boost for dimension match
        if let metrics = metrics, let fileDims = file.dimensions {
            let diff = simd_length(fileDims - metrics.dimensions)
            let maxDim = max(metrics.dimensions.x, max(metrics.dimensions.y, metrics.dimensions.z))
            let dimScore = max(0, 1 - diff / maxDim)
            score *= (1 + dimScore * 0.3)
        }

        // Boost for name match
        let queryWords = Set(query.text.lowercased().components(separatedBy: .whitespaces))
        let fileWords = Set(file.name.lowercased().components(separatedBy: .whitespaces))
        let intersection = queryWords.intersection(fileWords)
        let nameMatchScore = Float(intersection.count) / Float(max(queryWords.count, 1))
        score *= (1 + nameMatchScore * 0.2)

        return min(score, 1.0)
    }

    // MARK: - Deduplication

    private func removeDuplicates(_ results: [CADSearchResult]) -> [CADSearchResult] {
        var seen = Set<String>()
        var unique: [CADSearchResult] = []

        for result in results {
            let key = "\(result.file.source.rawValue):\(result.file.name.lowercased())"
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(result)
            }
        }

        return unique
    }
}

// MARK: - Supporting Types

struct SearchQuery {
    let text: String
    let matchType: CADSearchResult.MatchType
    let weight: Float
}

// MARK: - CAD Provider Protocol

protocol CADProvider {
    var source: CADSource { get }
    func search(query: String, maxResults: Int) async throws -> [CADFile]
    func getDownloadURL(for file: CADFile, format: CADFormat) async throws -> URL
}
