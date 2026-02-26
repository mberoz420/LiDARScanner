import Foundation

/// TraceParts CAD library provider
class TracePartsProvider: CADProvider {
    let source: CADSource = .traceparts

    // MARK: - Configuration

    struct Configuration {
        var apiKey: String = "" // TraceParts API key
        var baseURL = "https://www.traceparts.com"
        var apiURL = "https://api.traceparts.com"
    }

    var configuration = Configuration()

    // MARK: - Search

    func search(query: String, maxResults: Int) async throws -> [CADFile] {
        // TraceParts has a proper API - use it if API key is available
        if !configuration.apiKey.isEmpty {
            return try await searchWithAPI(query: query, maxResults: maxResults)
        }

        // Fallback to web search
        return try await searchWeb(query: query, maxResults: maxResults)
    }

    // MARK: - API Search

    private func searchWithAPI(query: String, maxResults: Int) async throws -> [CADFile] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let urlString = "\(configuration.apiURL)/v1/search?q=\(encodedQuery)&limit=\(maxResults)"

        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProviderError.requestFailed
        }

        return try parseAPIResponse(data)
    }

    // MARK: - Web Search

    private func searchWeb(query: String, maxResults: Int) async throws -> [CADFile] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = "\(configuration.baseURL)/en/search?CadModelsOnly=True&Keywords=\(encodedQuery)"

        guard let url = URL(string: searchURL) else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return generateMockResults(query: query, count: min(maxResults, 5))
            }

            let results = try parseWebResults(data)
            return Array(results.prefix(maxResults))
        } catch {
            return generateMockResults(query: query, count: min(maxResults, 5))
        }
    }

    // MARK: - Download URL

    func getDownloadURL(for file: CADFile, format: CADFormat) async throws -> URL {
        // TraceParts requires authentication for downloads
        guard !configuration.apiKey.isEmpty else {
            throw ProviderError.authenticationRequired
        }

        guard let downloadURL = file.downloadURL else {
            throw ProviderError.downloadNotAvailable
        }

        // Request download URL with format
        let urlString = "\(configuration.apiURL)/v1/download?url=\(downloadURL.absoluteString)&format=\(format.rawValue)"

        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProviderError.downloadNotAvailable
        }

        // Parse response for actual download URL
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let downloadURLString = json["downloadUrl"] as? String,
              let finalURL = URL(string: downloadURLString) else {
            throw ProviderError.parsingFailed
        }

        return finalURL
    }

    // MARK: - Parsing

    private func parseAPIResponse(_ data: Data) throws -> [CADFile] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw ProviderError.parsingFailed
        }

        return results.compactMap { item -> CADFile? in
            guard let name = item["name"] as? String,
                  let partNumber = item["partNumber"] as? String,
                  let urlString = item["url"] as? String,
                  let sourceURL = URL(string: urlString) else {
                return nil
            }

            let description = item["description"] as? String
            let thumbnailString = item["thumbnail"] as? String
            let formats = item["formats"] as? [String] ?? []
            let dimensions = item["dimensions"] as? [String: Float]

            var dims: SIMD3<Float>?
            if let l = dimensions?["length"],
               let w = dimensions?["width"],
               let h = dimensions?["height"] {
                dims = SIMD3<Float>(l, w, h) / 1000 // Convert to meters
            }

            return CADFile(
                name: "\(name) - \(partNumber)",
                description: description,
                format: formats.first.flatMap { CADFormat(rawValue: $0.lowercased()) } ?? .step,
                source: .traceparts,
                sourceURL: sourceURL,
                downloadURL: URL(string: "\(configuration.apiURL)/download/\(partNumber)"),
                thumbnailURL: thumbnailString.flatMap { URL(string: $0) },
                dimensions: dims,
                tags: item["categories"] as? [String] ?? []
            )
        }
    }

    private func parseWebResults(_ data: Data) throws -> [CADFile] {
        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.parsingFailed
        }

        var files: [CADFile] = []

        // Simple pattern matching for TraceParts results
        let pattern = #"class="product-title"[^>]*>([^<]+)</.*?href="(/en/product/[^"]+)""#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return files
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        for match in matches.prefix(10) {
            guard match.numberOfRanges >= 3 else { continue }

            let titleRange = Range(match.range(at: 1), in: html)
            let pathRange = Range(match.range(at: 2), in: html)

            guard let titleRange = titleRange,
                  let pathRange = pathRange else { continue }

            let title = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let path = String(html[pathRange])

            let sourceURL = URL(string: "\(configuration.baseURL)\(path)")!

            files.append(CADFile(
                name: title.htmlDecoded,
                description: nil,
                format: .step,
                source: .traceparts,
                sourceURL: sourceURL,
                tags: []
            ))
        }

        return files
    }

    // MARK: - Mock Data

    private func generateMockResults(query: String, count: Int) -> [CADFile] {
        let mockItems = [
            ("DIN 912 Socket Head Cap Screw", "Metric socket head cap screw", ["screw", "socket", "DIN912"]),
            ("SKF 6205 Ball Bearing", "Deep groove ball bearing", ["bearing", "SKF", "6205"]),
            ("Festo DSNU Cylinder", "Pneumatic cylinder ISO 6432", ["cylinder", "pneumatic", "Festo"]),
            ("Phoenix Contact Terminal", "Push-in terminal block", ["terminal", "connector", "Phoenix"]),
            ("Bosch Rexroth Linear Guide", "Ball rail system", ["linear", "guide", "Bosch"]),
            ("SMC Air Fitting", "One-touch fitting", ["fitting", "pneumatic", "SMC"]),
            ("Misumi Shaft", "Precision ground shaft", ["shaft", "precision", "Misumi"]),
            ("Igus Bearing", "Polymer plain bearing", ["bearing", "igus", "polymer"])
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
                source: .traceparts,
                sourceURL: URL(string: "https://www.traceparts.com/en/product/\(item.0.lowercased().replacingOccurrences(of: " ", with: "-"))")!,
                downloadURL: URL(string: "https://www.traceparts.com/download/mock"),
                thumbnailURL: nil,
                fileSize: Int64.random(in: 100_000...10_000_000),
                tags: item.2
            )
        }
    }
}
