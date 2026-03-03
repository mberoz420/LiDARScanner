import Foundation

/// Uploads scan JSON files to scan-wizard.robo-wizard.com
/// Replaces the Google Drive upload flow.
@MainActor
class ScanServerManager: ObservableObject {

    static let shared = ScanServerManager()

    // ── Configuration — must match UPLOAD_API_KEY in server/includes/config.php ──
    private let serverURL = "https://scanwizard.robo-wizard.com/upload.php"
    private let apiKey    = "ScanWizard2025Secret"  // ← must match UPLOAD_API_KEY in config.php

    @Published var isUploading = false
    @Published var lastError: String?

    private init() {}

    /// Upload a local JSON file to the ScanWizard server.
    /// Returns the remote filename on success, nil on failure.
    func uploadFile(at url: URL) async -> String? {
        isUploading = true
        lastError   = nil
        defer { isUploading = false }

        do {
            let data = try Data(contentsOf: url)

            var request = URLRequest(url: URL(string: serverURL)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey,             forHTTPHeaderField: "X-API-Key")
            request.httpBody = data

            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                lastError = "No HTTP response"
                return nil
            }

            guard http.statusCode == 200 else {
                let body = String(data: responseData, encoding: .utf8) ?? ""
                lastError = "Server error \(http.statusCode): \(body)"
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let filename = json["filename"] as? String else {
                lastError = "Unexpected server response"
                return nil
            }

            return filename

        } catch {
            lastError = "Upload failed: \(error.localizedDescription)"
            return nil
        }
    }
}
