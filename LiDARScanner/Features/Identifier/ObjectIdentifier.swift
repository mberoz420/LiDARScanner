import Foundation
import Vision
import CoreML

/// Orchestrates object identification using multiple strategies
class ObjectIdentifier {

    // MARK: - Services
    private let imageSearchService = ImageSearchService()
    private let mlClassifier = MLClassifier()

    // MARK: - Configuration
    struct Configuration {
        var useVisualSearch = true
        var useMLClassification = true
        var useDimensionMatch = true
        var minConfidenceThreshold: Float = 0.3
        var maxResults = 10
    }

    var configuration = Configuration()

    // MARK: - Main Identification

    /// Identify an object using multiple strategies
    func identify(
        metrics: ObjectMetrics,
        image: Data?
    ) async throws -> [IdentificationResult] {
        var allResults: [IdentificationResult] = []

        // Run identification strategies in parallel
        await withTaskGroup(of: [IdentificationResult].self) { group in
            // Visual search (if image available)
            if configuration.useVisualSearch, let imageData = image {
                group.addTask {
                    await self.performVisualSearch(imageData: imageData)
                }
            }

            // ML classification (if image available)
            if configuration.useMLClassification, let imageData = image {
                group.addTask {
                    await self.performMLClassification(imageData: imageData)
                }
            }

            // Dimension-based search
            if configuration.useDimensionMatch {
                group.addTask {
                    await self.performDimensionSearch(metrics: metrics)
                }
            }

            // Collect results
            for await results in group {
                allResults.append(contentsOf: results)
            }
        }

        // Merge and rank results
        let mergedResults = mergeResults(allResults)

        // Filter by confidence threshold
        let filteredResults = mergedResults.filter {
            $0.confidence >= configuration.minConfidenceThreshold
        }

        return Array(filteredResults.prefix(configuration.maxResults))
    }

    // MARK: - Visual Search

    private func performVisualSearch(imageData: Data) async -> [IdentificationResult] {
        do {
            let searchResults = try await imageSearchService.search(imageData: imageData)
            return searchResults.map { result in
                IdentificationResult(
                    name: result.title,
                    description: result.snippet,
                    confidence: result.relevanceScore,
                    source: .visualSearch,
                    category: inferCategory(from: result.title),
                    relatedSearchTerms: extractSearchTerms(from: result.title),
                    imageURL: result.thumbnailURL,
                    productURL: result.sourceURL
                )
            }
        } catch {
            print("Visual search failed: \(error)")
            return []
        }
    }

    // MARK: - ML Classification

    private func performMLClassification(imageData: Data) async -> [IdentificationResult] {
        do {
            let classifications = try await mlClassifier.classify(imageData: imageData)
            return classifications.map { classification in
                IdentificationResult(
                    name: classification.label,
                    description: "Classified as \(classification.label)",
                    confidence: classification.confidence,
                    source: .mlClassification,
                    category: mapToCategory(classification.label),
                    relatedSearchTerms: classification.relatedTerms
                )
            }
        } catch {
            print("ML classification failed: \(error)")
            return []
        }
    }

    // MARK: - Dimension Search

    private func performDimensionSearch(metrics: ObjectMetrics) async -> [IdentificationResult] {
        // Search based on dimensions and shape type
        var results: [IdentificationResult] = []

        // Generate search suggestions based on shape and size
        let suggestions = generateDimensionSuggestions(metrics: metrics)

        for suggestion in suggestions {
            results.append(IdentificationResult(
                name: suggestion.name,
                description: "Matched by dimensions: \(metrics.dimensionString())",
                confidence: suggestion.confidence,
                source: .dimensionMatch,
                category: suggestion.category,
                relatedSearchTerms: suggestion.searchTerms
            ))
        }

        return results
    }

    // MARK: - Result Merging

    private func mergeResults(_ results: [IdentificationResult]) -> [IdentificationResult] {
        // Group by similar names
        var grouped: [String: [IdentificationResult]] = [:]

        for result in results {
            let normalizedName = result.name.lowercased().trimmingCharacters(in: .whitespaces)
            grouped[normalizedName, default: []].append(result)
        }

        // Merge groups
        var merged: [IdentificationResult] = []

        for (name, group) in grouped {
            if group.count == 1 {
                merged.append(group[0])
            } else {
                // Combine confidence scores
                let combinedConfidence = min(group.map { $0.confidence }.reduce(0, +) * 0.6, 1.0)

                // Use most detailed result as base
                let baseResult = group.max(by: {
                    ($0.description?.count ?? 0) < ($1.description?.count ?? 0)
                }) ?? group[0]

                // Merge search terms
                var allTerms = Set<String>()
                for r in group {
                    allTerms.formUnion(r.relatedSearchTerms)
                }

                merged.append(IdentificationResult(
                    name: baseResult.name,
                    description: baseResult.description,
                    confidence: combinedConfidence,
                    source: .combined,
                    category: baseResult.category,
                    relatedSearchTerms: Array(allTerms),
                    imageURL: baseResult.imageURL,
                    productURL: baseResult.productURL
                ))
            }
        }

        // Sort by confidence
        merged.sort { $0.confidence > $1.confidence }

        return merged
    }

    // MARK: - Helpers

    private func inferCategory(from text: String) -> ObjectCategory? {
        let lowercased = text.lowercased()

        for category in ObjectCategory.allCases {
            if lowercased.contains(category.rawValue.lowercased()) {
                return category
            }
        }

        // Check common synonyms
        if lowercased.contains("fastener") || lowercased.contains("hardware") {
            if lowercased.contains("hex") { return .bolt }
            if lowercased.contains("cap") { return .screw }
        }

        return nil
    }

    private func mapToCategory(_ label: String) -> ObjectCategory? {
        let mapping: [String: ObjectCategory] = [
            "screw": .screw,
            "bolt": .bolt,
            "nut": .nut,
            "washer": .washer,
            "bearing": .bearing,
            "gear": .gear,
            "connector": .connector,
            "cable": .cable,
            "sensor": .sensor,
            "motor": .motor,
            "tool": .tool
        ]

        return mapping[label.lowercased()]
    }

    private func extractSearchTerms(from text: String) -> [String] {
        // Simple keyword extraction
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }

        return Array(Set(words))
    }

    private func generateDimensionSuggestions(metrics: ObjectMetrics) -> [(name: String, confidence: Float, category: ObjectCategory?, searchTerms: [String])] {
        var suggestions: [(name: String, confidence: Float, category: ObjectCategory?, searchTerms: [String])] = []

        let dims = metrics.dimensionsMM

        // Based on primitive shape
        switch metrics.primitiveType {
        case .cylinder:
            // Check for common cylindrical objects
            let diameter = min(dims.x, dims.z)
            let height = dims.y

            // Check for standard bolt/screw sizes
            if diameter >= 3 && diameter <= 20 && height >= 5 && height <= 100 {
                suggestions.append((
                    name: "M\(Int(diameter)) Hardware",
                    confidence: 0.5,
                    category: .bolt,
                    searchTerms: ["M\(Int(diameter))", "bolt", "screw", "fastener"]
                ))
            }

            // Check for bearing sizes
            if diameter >= 10 && diameter <= 100 {
                suggestions.append((
                    name: "Bearing \(Int(diameter))mm",
                    confidence: 0.4,
                    category: .bearing,
                    searchTerms: ["\(Int(diameter))mm bearing", "ball bearing"]
                ))
            }

        case .box:
            // Rectangular objects
            if dims.x < 50 && dims.y < 50 && dims.z < 20 {
                suggestions.append((
                    name: "Electronic Component",
                    confidence: 0.4,
                    category: .connector,
                    searchTerms: ["connector", "electronic", "component"]
                ))
            }

        case .sphere:
            let diameter = (dims.x + dims.y + dims.z) / 3
            suggestions.append((
                name: "\(Int(diameter))mm Ball/Sphere",
                confidence: 0.5,
                category: nil,
                searchTerms: ["ball", "sphere", "\(Int(diameter))mm"]
            ))

        default:
            break
        }

        return suggestions
    }
}
