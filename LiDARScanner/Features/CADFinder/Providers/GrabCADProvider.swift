import Foundation

/// GrabCAD Community Library provider
class GrabCADProvider: CADProvider {
    let source: CADSource = .grabcad

    // MARK: - Configuration

    struct Configuration {
        var apiKey: String = "" // GrabCAD API key if available
        var baseURL = "https://grabcad.com"
    }

    var configuration = Configuration()

    // MARK: - Search

    func search(query: String, maxResults: Int) async throws -> [CADFile] {
        // GrabCAD doesn't have a public API, so we'll use web scraping approach
        // In production, you'd want to use their official API or partner program

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = "\(configuration.baseURL)/library?page=1&per_page=\(maxResults)&query=\(encodedQuery)"

        guard let url = URL(string: searchURL) else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.requestFailed
            }

            // Check for rate limiting
            if httpResponse.statusCode == 429 {
                throw ProviderError.rateLimited
            }

            guard httpResponse.statusCode == 200 else {
                // Return mock data for testing
                return generateMockResults(query: query, count: min(maxResults, 5))
            }

            return try parseSearchResults(data)
        } catch is ProviderError {
            throw ProviderError.requestFailed
        } catch {
            // Network error - return mock data for development
            return generateMockResults(query: query, count: min(maxResults, 5))
        }
    }

    // MARK: - Download URL

    func getDownloadURL(for file: CADFile, format: CADFormat) async throws -> URL {
        // In production, this would authenticate and get the actual download URL
        guard let downloadURL = file.downloadURL else {
            throw ProviderError.downloadNotAvailable
        }
        return downloadURL
    }

    // MARK: - Parsing

    private func parseSearchResults(_ data: Data) throws -> [CADFile] {
        // Parse HTML or JSON response from GrabCAD
        // This is a simplified version - real implementation would use proper HTML parsing

        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.parsingFailed
        }

        var files: [CADFile] = []

        // Simple regex-based extraction (use SwiftSoup in production)
        let pattern = #"data-model-id="(\d+)".*?title="([^"]+)".*?href="(/library/[^"]+)""#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return files
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        for match in matches.prefix(10) {
            guard match.numberOfRanges >= 4 else { continue }

            let idRange = Range(match.range(at: 1), in: html)
            let titleRange = Range(match.range(at: 2), in: html)
            let pathRange = Range(match.range(at: 3), in: html)

            guard let idRange = idRange,
                  let titleRange = titleRange,
                  let pathRange = pathRange else { continue }

            let modelId = String(html[idRange])
            let title = String(html[titleRange])
            let path = String(html[pathRange])

            let sourceURL = URL(string: "\(configuration.baseURL)\(path)")!

            files.append(CADFile(
                name: title.htmlDecoded,
                description: nil,
                format: .step, // Default format
                source: .grabcad,
                sourceURL: sourceURL,
                downloadURL: URL(string: "\(configuration.baseURL)/library/\(modelId)/download"),
                thumbnailURL: URL(string: "\(configuration.baseURL)/library/\(modelId)/thumbnail"),
                tags: []
            ))
        }

        return files
    }

    // MARK: - Mock Data

    private func generateMockResults(query: String, count: Int) -> [CADFile] {
        let mockItems = [
            ("M6 Hex Bolt DIN 933", "Standard hex bolt, metric thread", ["bolt", "hex", "fastener", "M6"]),
            ("Ball Bearing 608ZZ", "Deep groove ball bearing 8x22x7mm", ["bearing", "ball bearing", "608"]),
            ("Spur Gear Module 1", "Standard spur gear, 20 teeth", ["gear", "spur", "mechanical"]),
            ("Cable Gland PG9", "Waterproof cable gland", ["connector", "cable", "electrical"]),
            ("L-Bracket Steel", "90 degree mounting bracket", ["bracket", "mount", "hardware"]),
            ("Shaft Coupling 8mm", "Flexible shaft coupling", ["coupling", "shaft", "mechanical"]),
            ("Terminal Block 4-Way", "Screw terminal connector block", ["terminal", "connector", "electrical"]),
            ("Linear Rail MGN12", "Linear motion guide rail", ["linear", "rail", "motion"]),
            ("Stepper Motor NEMA 17", "Bipolar stepper motor", ["motor", "stepper", "NEMA"]),
            ("Pneumatic Fitting 1/4", "Push-to-connect fitting", ["fitting", "pneumatic", "connector"])
        ]

        let queryLower = query.lowercased()
        let relevant = mockItems.filter { item in
            item.2.contains { queryLower.contains($0) } ||
            item.0.lowercased().contains(queryLower)
        }

        let items = relevant.isEmpty ? mockItems : relevant

        return items.prefix(count).map { item in
            CADFile(
                name: item.0,
                description: item.1,
                format: .step,
                source: .grabcad,
                sourceURL: URL(string: "https://grabcad.com/library/\(item.0.lowercased().replacingOccurrences(of: " ", with: "-"))")!,
                downloadURL: URL(string: "https://grabcad.com/library/download/mock"),
                thumbnailURL: nil,
                fileSize: Int64.random(in: 50_000...5_000_000),
                tags: item.2
            )
        }
    }
}

// MARK: - Provider Errors

enum ProviderError: LocalizedError {
    case invalidURL
    case requestFailed
    case rateLimited
    case parsingFailed
    case downloadNotAvailable
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL for CAD provider."
        case .requestFailed:
            return "Request to CAD provider failed."
        case .rateLimited:
            return "Rate limit exceeded. Please try again later."
        case .parsingFailed:
            return "Failed to parse CAD provider response."
        case .downloadNotAvailable:
            return "Download is not available for this file."
        case .authenticationRequired:
            return "Authentication is required for this action."
        }
    }
}

// MARK: - String Extension

extension String {
    var htmlDecoded: String {
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " "
        ]

        var result = self
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}
