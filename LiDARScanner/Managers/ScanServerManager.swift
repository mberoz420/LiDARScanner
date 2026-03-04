import Foundation

/// Uploads scan JSON files to scan-wizard.robo-wizard.com
/// Replaces the Google Drive upload flow.
@MainActor
class ScanServerManager: ObservableObject {

    static let shared = ScanServerManager()

    // ── Configuration — must match UPLOAD_API_KEY in server/includes/config.php ──
    private let serverURL      = "https://scanwizard.robo-wizard.com/upload.php"
    private let photosURL      = "https://scanwizard.robo-wizard.com/upload_photos.php"
    private let apiKey         = "ScanWizard2025Secret"  // ← must match UPLOAD_API_KEY in config.php

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

    /// Upload auto-captured photos + camera transforms to the photogrammetry endpoint.
    /// Returns the server session_id on success, nil on failure.
    func uploadPhotos(from dir: URL, posesData: Data?) async -> String? {
        isUploading = true
        lastError   = nil
        defer { isUploading = false }

        // Gather sorted JPEGs
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            lastError = "Could not read photo directory"
            return nil
        }
        let jpegURLs = contents
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !jpegURLs.isEmpty else {
            lastError = "No photos to upload"
            return nil
        }

        // Build JSON payload: photos as base64, transforms as array
        var photosArray: [[String: String]] = []
        for url in jpegURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            photosArray.append([
                "name": url.lastPathComponent,
                "data": data.base64EncodedString()
            ])
        }

        var payload: [String: Any] = ["photos": photosArray]
        if let poses = posesData,
           let posesObj = try? JSONSerialization.jsonObject(with: poses) as? [String: Any] {
            payload["camera_poses"] = posesObj["camera_poses"] ?? []
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            lastError = "Failed to encode payload"
            return nil
        }

        var request = URLRequest(url: URL(string: photosURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,             forHTTPHeaderField: "X-API-Key")
        request.httpBody = body
        request.timeoutInterval = 120  // large upload may take time

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "No HTTP response"
                return nil
            }
            guard http.statusCode == 200 else {
                let msg = String(data: responseData, encoding: .utf8) ?? ""
                lastError = "Server error \(http.statusCode): \(msg)"
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let sessionId = json["session_id"] as? String else {
                lastError = "Unexpected server response"
                return nil
            }
            return sessionId
        } catch {
            lastError = "Upload failed: \(error.localizedDescription)"
            return nil
        }
    }
}
