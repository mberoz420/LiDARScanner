import Foundation
import UIKit

/// Performs visual/reverse image search using Google Custom Search API
class ImageSearchService {

    // MARK: - Configuration

    struct Configuration {
        var apiKey: String = "" // Set your Google API key
        var searchEngineID: String = "" // Set your Custom Search Engine ID
        var maxResults = 10
    }

    var configuration = Configuration()

    // MARK: - Search

    /// Perform reverse image search
    func search(imageData: Data) async throws -> [SearchResult] {
        // First, try to identify using on-device Vision
        let visionResults = try await performVisionSearch(imageData: imageData)

        // If we have good local results, use them to search
        if !visionResults.isEmpty {
            return try await searchByKeywords(keywords: visionResults.map { $0.label })
        }

        // Fall back to base64 image search (requires API setup)
        guard !configuration.apiKey.isEmpty else {
            throw SearchError.apiKeyMissing
        }

        return try await performImageSearch(imageData: imageData)
    }

    // MARK: - Vision Framework Search

    private func performVisionSearch(imageData: Data) async throws -> [(label: String, confidence: Float)] {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw SearchError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let results = request.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let filtered = results
                    .filter { $0.confidence > 0.3 }
                    .prefix(5)
                    .map { (label: $0.identifier, confidence: $0.confidence) }

                continuation.resume(returning: Array(filtered))
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Keyword Search

    /// Search by keywords using Google Custom Search API
    func searchByKeywords(keywords: [String]) async throws -> [SearchResult] {
        guard !configuration.apiKey.isEmpty else {
            // Return mock results for testing
            return keywords.prefix(3).enumerated().map { index, keyword in
                SearchResult(
                    title: keyword.capitalized,
                    snippet: "Search result for \(keyword)",
                    sourceURL: URL(string: "https://example.com/\(keyword)")!,
                    thumbnailURL: nil,
                    relevanceScore: Float(keywords.count - index) / Float(keywords.count)
                )
            }
        }

        let query = keywords.joined(separator: " ")
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let urlString = "https://www.googleapis.com/customsearch/v1?key=\(configuration.apiKey)&cx=\(configuration.searchEngineID)&q=\(encodedQuery)&searchType=image&num=\(configuration.maxResults)"

        guard let url = URL(string: urlString) else {
            throw SearchError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SearchError.requestFailed
        }

        return try parseSearchResponse(data)
    }

    // MARK: - Image Search

    private func performImageSearch(imageData: Data) async throws -> [SearchResult] {
        // Google Cloud Vision API for reverse image search
        let base64Image = imageData.base64EncodedString()

        let requestBody: [String: Any] = [
            "requests": [
                [
                    "image": ["content": base64Image],
                    "features": [
                        ["type": "WEB_DETECTION", "maxResults": configuration.maxResults],
                        ["type": "LABEL_DETECTION", "maxResults": 10]
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw SearchError.invalidRequest
        }

        let urlString = "https://vision.googleapis.com/v1/images:annotate?key=\(configuration.apiKey)"
        guard let url = URL(string: urlString) else {
            throw SearchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SearchError.requestFailed
        }

        return try parseVisionResponse(data)
    }

    // MARK: - Response Parsing

    private func parseSearchResponse(_ data: Data) throws -> [SearchResult] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> SearchResult? in
            guard let title = item["title"] as? String,
                  let link = item["link"] as? String,
                  let linkURL = URL(string: link) else {
                return nil
            }

            let snippet = item["snippet"] as? String
            let image = item["image"] as? [String: Any]
            let thumbnailLink = image?["thumbnailLink"] as? String

            return SearchResult(
                title: title,
                snippet: snippet,
                sourceURL: linkURL,
                thumbnailURL: thumbnailLink.flatMap { URL(string: $0) },
                relevanceScore: 0.7 // Default relevance
            )
        }
    }

    private func parseVisionResponse(_ data: Data) throws -> [SearchResult] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = json["responses"] as? [[String: Any]],
              let firstResponse = responses.first else {
            return []
        }

        var results: [SearchResult] = []

        // Parse web detection results
        if let webDetection = firstResponse["webDetection"] as? [String: Any] {
            // Best guess labels
            if let bestGuesses = webDetection["bestGuessLabels"] as? [[String: Any]] {
                for guess in bestGuesses {
                    if let label = guess["label"] as? String {
                        results.append(SearchResult(
                            title: label,
                            snippet: "Best guess from image analysis",
                            sourceURL: URL(string: "https://google.com/search?q=\(label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? label)")!,
                            thumbnailURL: nil,
                            relevanceScore: 0.9
                        ))
                    }
                }
            }

            // Web entities
            if let entities = webDetection["webEntities"] as? [[String: Any]] {
                for entity in entities.prefix(5) {
                    if let description = entity["description"] as? String,
                       let score = entity["score"] as? Double {
                        results.append(SearchResult(
                            title: description,
                            snippet: "Web entity match",
                            sourceURL: URL(string: "https://google.com/search?q=\(description.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? description)")!,
                            thumbnailURL: nil,
                            relevanceScore: Float(score)
                        ))
                    }
                }
            }

            // Visually similar images
            if let similarImages = webDetection["visuallySimilarImages"] as? [[String: Any]] {
                for image in similarImages.prefix(3) {
                    if let url = image["url"] as? String,
                       let imageURL = URL(string: url) {
                        results.append(SearchResult(
                            title: "Similar Image",
                            snippet: url,
                            sourceURL: imageURL,
                            thumbnailURL: imageURL,
                            relevanceScore: 0.6
                        ))
                    }
                }
            }
        }

        // Parse label annotations
        if let labels = firstResponse["labelAnnotations"] as? [[String: Any]] {
            for label in labels.prefix(5) {
                if let description = label["description"] as? String,
                   let score = label["score"] as? Double {
                    results.append(SearchResult(
                        title: description,
                        snippet: "Label detection",
                        sourceURL: URL(string: "https://google.com/search?q=\(description.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? description)")!,
                        thumbnailURL: nil,
                        relevanceScore: Float(score) * 0.8
                    ))
                }
            }
        }

        return results
    }
}

// MARK: - Supporting Types

struct SearchResult {
    let title: String
    let snippet: String?
    let sourceURL: URL
    let thumbnailURL: URL?
    let relevanceScore: Float
}

enum SearchError: LocalizedError {
    case apiKeyMissing
    case invalidImage
    case invalidURL
    case invalidRequest
    case requestFailed
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "API key is not configured. Please set up Google Cloud API key."
        case .invalidImage:
            return "Invalid image data provided."
        case .invalidURL:
            return "Failed to construct search URL."
        case .invalidRequest:
            return "Failed to create search request."
        case .requestFailed:
            return "Search request failed."
        case .parsingFailed:
            return "Failed to parse search results."
        }
    }
}

import Vision
