import Foundation

/// Generic API client for network requests
class APIClient {

    // MARK: - Singleton
    static let shared = APIClient()

    // MARK: - Configuration

    struct Configuration {
        var defaultTimeout: TimeInterval = 30
        var retryCount = 2
        var retryDelay: TimeInterval = 1
    }

    var configuration = Configuration()

    // MARK: - Private Properties
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = configuration.defaultTimeout
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
        session = URLSession(configuration: config)

        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Request Methods

    /// Perform a GET request
    func get<T: Decodable>(
        url: URL,
        headers: [String: String]? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(headers, to: &request)

        return try await perform(request)
    }

    /// Perform a POST request with JSON body
    func post<T: Decodable, B: Encodable>(
        url: URL,
        body: B,
        headers: [String: String]? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        applyHeaders(headers, to: &request)

        return try await perform(request)
    }

    /// Perform a POST request without expecting response body
    func post<B: Encodable>(
        url: URL,
        body: B,
        headers: [String: String]? = nil
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        applyHeaders(headers, to: &request)

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    /// Perform a request and get raw data
    func getData(
        url: URL,
        headers: [String: String]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(headers, to: &request)

        return try await performRaw(request)
    }

    // MARK: - Private Methods

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performWithRetry(request)
        return try decoder.decode(T.self, from: data)
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        return try await performWithRetry(request)
    }

    private func performWithRetry(_ request: URLRequest) async throws -> Data {
        var lastError: Error?

        for attempt in 0..<configuration.retryCount {
            do {
                let (data, response) = try await session.data(for: request)
                try validateResponse(response)
                return data
            } catch {
                lastError = error

                // Don't retry client errors (4xx)
                if let apiError = error as? APIError,
                   case .clientError = apiError {
                    throw error
                }

                // Wait before retry
                if attempt < configuration.retryCount - 1 {
                    try await Task.sleep(nanoseconds: UInt64(configuration.retryDelay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? APIError.unknown
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 400...499:
            throw APIError.clientError(httpResponse.statusCode)
        case 500...599:
            throw APIError.serverError(httpResponse.statusCode)
        default:
            throw APIError.unknown
        }
    }

    private func applyHeaders(_ headers: [String: String]?, to request: inout URLRequest) {
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}

// MARK: - API Error

enum APIError: LocalizedError {
    case invalidResponse
    case clientError(Int)
    case serverError(Int)
    case decodingError(Error)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server."
        case .clientError(let code):
            return "Client error: \(code)"
        case .serverError(let code):
            return "Server error: \(code)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .unknown:
            return "An unknown error occurred."
        }
    }
}

// MARK: - API Keys Manager

/// Manages API keys for various services
class APIKeysManager {
    static let shared = APIKeysManager()

    private var keys: [String: String] = [:]

    private init() {
        loadKeys()
    }

    func getKey(for service: Service) -> String? {
        keys[service.rawValue]
    }

    func setKey(_ key: String, for service: Service) {
        keys[service.rawValue] = key
        saveKeys()
    }

    enum Service: String {
        case googleCloud = "google_cloud"
        case grabcad = "grabcad"
        case traceparts = "traceparts"
        case thingiverse = "thingiverse"
    }

    private func loadKeys() {
        // Load from Keychain in production
        // For now, load from UserDefaults (not secure - demo only)
        if let data = UserDefaults.standard.data(forKey: "api_keys"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            keys = decoded
        }
    }

    private func saveKeys() {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: "api_keys")
        }
    }
}
