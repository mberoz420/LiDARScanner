import Foundation

/// Thingiverse 3D model provider
class ThingiverseProvider: CADProvider {
    let source: CADSource = .thingiverse

    // MARK: - Configuration

    struct Configuration {
        var apiKey: String = "" // Thingiverse API key
        var baseURL = "https://www.thingiverse.com"
        var apiURL = "https://api.thingiverse.com"
    }

    var configuration = Configuration()

    // MARK: - Search

    func search(query: String, maxResults: Int) async throws -> [CADFile] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        // Thingiverse has a public API
        let urlString = "\(configuration.apiURL)/search/\(encodedQuery)?per_page=\(maxResults)"

        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.requestFailed
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                // API key required or invalid
                return generateMockResults(query: query, count: min(maxResults, 5))
            }

            guard httpResponse.statusCode == 200 else {
                return generateMockResults(query: query, count: min(maxResults, 5))
            }

            return try parseSearchResults(data)
        } catch {
            return generateMockResults(query: query, count: min(maxResults, 5))
        }
    }

    // MARK: - Download URL

    func getDownloadURL(for file: CADFile, format: CADFormat) async throws -> URL {
        // Get thing details to find files
        guard let thingId = extractThingId(from: file.sourceURL) else {
            throw ProviderError.downloadNotAvailable
        }

        let urlString = "\(configuration.apiURL)/things/\(thingId)/files"

        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProviderError.downloadNotAvailable
        }

        // Parse files and find matching format
        guard let files = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ProviderError.parsingFailed
        }

        // Find file with matching format
        for fileInfo in files {
            guard let fileName = fileInfo["name"] as? String,
                  let downloadURL = fileInfo["download_url"] as? String else {
                continue
            }

            let fileExtension = URL(string: fileName)?.pathExtension.lowercased() ?? ""
            if fileExtension == format.rawValue || fileExtension == "stl" {
                if let url = URL(string: downloadURL) {
                    return url
                }
            }
        }

        // Return first STL file if no exact match
        if let firstFile = files.first,
           let downloadURL = firstFile["download_url"] as? String,
           let url = URL(string: downloadURL) {
            return url
        }

        throw ProviderError.downloadNotAvailable
    }

    // MARK: - Parsing

    private func parseSearchResults(_ data: Data) throws -> [CADFile] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else {
            // Try parsing as array directly
            if let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return parseItems(items)
            }
            throw ProviderError.parsingFailed
        }

        return parseItems(hits)
    }

    private func parseItems(_ items: [[String: Any]]) -> [CADFile] {
        items.compactMap { item -> CADFile? in
            guard let id = item["id"] as? Int,
                  let name = item["name"] as? String else {
                return nil
            }

            let description = item["description"] as? String
            let thumbnailUrl = item["thumbnail"] as? String
            let publicUrl = item["public_url"] as? String ?? "\(configuration.baseURL)/thing:\(id)"

            guard let sourceURL = URL(string: publicUrl) else {
                return nil
            }

            var tags: [String] = []
            if let tagList = item["tags"] as? [[String: Any]] {
                tags = tagList.compactMap { $0["name"] as? String }
            }

            return CADFile(
                name: name,
                description: description?.prefix(200).description,
                format: .stl, // Thingiverse primarily uses STL
                source: .thingiverse,
                sourceURL: sourceURL,
                downloadURL: URL(string: "\(configuration.apiURL)/things/\(id)/files"),
                thumbnailURL: thumbnailUrl.flatMap { URL(string: $0) },
                tags: tags
            )
        }
    }

    private func extractThingId(from url: URL) -> String? {
        // Extract thing ID from URL like "thingiverse.com/thing:12345"
        let path = url.path
        if let range = path.range(of: "thing:") ?? path.range(of: "things/") {
            let remaining = path[range.upperBound...]
            let id = remaining.prefix(while: { $0.isNumber })
            return String(id)
        }
        return nil
    }

    // MARK: - Mock Data

    private func generateMockResults(query: String, count: Int) -> [CADFile] {
        let mockItems = [
            ("Customizable Box", "Parametric storage box", ["box", "storage", "parametric"]),
            ("Phone Stand", "Universal phone holder", ["phone", "stand", "holder"]),
            ("Cable Clip", "Adhesive cable management", ["cable", "clip", "organizer"]),
            ("Hinge", "Printable hinge mechanism", ["hinge", "mechanical", "joint"]),
            ("Gear Set", "Parametric gear collection", ["gear", "mechanical", "parametric"]),
            ("Bracket", "Adjustable mounting bracket", ["bracket", "mount", "hardware"]),
            ("Knob", "Control knob replacement", ["knob", "dial", "control"]),
            ("Enclosure", "Electronics project box", ["enclosure", "box", "electronics"]),
            ("Hook", "Wall mount hook", ["hook", "mount", "wall"]),
            ("Clip", "Spring loaded clip", ["clip", "clamp", "holder"])
        ]

        let queryLower = query.lowercased()
        let relevant = mockItems.filter { item in
            item.2.contains { queryLower.contains($0) } ||
            item.0.lowercased().contains(queryLower)
        }

        let items = relevant.isEmpty ? mockItems : relevant

        return items.prefix(count).enumerated().map { index, item in
            let thingId = 1000000 + index
            return CADFile(
                name: item.0,
                description: item.1,
                format: .stl,
                source: .thingiverse,
                sourceURL: URL(string: "https://www.thingiverse.com/thing:\(thingId)")!,
                downloadURL: URL(string: "https://api.thingiverse.com/things/\(thingId)/files"),
                thumbnailURL: nil,
                fileSize: Int64.random(in: 10_000...1_000_000),
                tags: item.2
            )
        }
    }
}
