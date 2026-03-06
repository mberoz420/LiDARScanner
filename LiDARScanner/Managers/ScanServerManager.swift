import Foundation

/// Uploads scan JSON files to scan-wizard.robo-wizard.com
/// Replaces the Google Drive upload flow.
@MainActor
class ScanServerManager: ObservableObject {

    static let shared = ScanServerManager()

    // ── Configuration — must match UPLOAD_API_KEY in server/includes/config.php ──
    private let baseURL        = "https://scanwizard.robo-wizard.com"
    private let serverURL      = "https://scanwizard.robo-wizard.com/upload.php"
    private let photosURL      = "https://scanwizard.robo-wizard.com/upload_photos.php"
    private let apiKey         = "ScanWizard2025Secret"  // ← must match UPLOAD_API_KEY in config.php

    @Published var isUploading = false
    @Published var lastError: String?
    @Published var availableProjects: [String] = []

    private init() {}

    // MARK: - Project Management

    /// Fetch the list of project folders from the server.
    @discardableResult
    func fetchProjects() async -> [String] {
        guard let url = URL(string: "\(baseURL)/list_projects.php") else { return [] }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let projects = json["projects"] as? [String] {
                availableProjects = projects
                return projects
            }
        } catch {}
        return availableProjects
    }

    /// Create a new project folder on the server.
    func createProject(name: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/list_projects.php") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "create", "name": name])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["success"] as? Bool == true {
                await fetchProjects()
                return true
            }
        } catch {}
        return false
    }

    /// Upload a local JSON file to the ScanWizard server.
    /// Returns the remote filename on success, nil on failure.
    func uploadFile(at url: URL, project: String? = nil) async -> String? {
        do {
            let data = try Data(contentsOf: url)
            return await uploadScan(data: data, project: project)
        } catch {
            lastError = "Could not read file: \(error.localizedDescription)"
            return nil
        }
    }

    /// Upload raw scan JSON data (from a LiDAR mesh / point cloud) to the scan endpoint.
    /// Returns the remote filename (e.g. "scan_1234567890_1234.json") on success, nil on failure.
    /// If `project` is provided, the scan is stored in that project subfolder on the server.
    func uploadScan(data: Data, project: String? = nil) async -> String? {
        isUploading = true
        lastError   = nil
        defer { isUploading = false }

        var urlStr = serverURL
        if let proj = project, !proj.isEmpty {
            urlStr += "?project=\(proj.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? proj)"
        }
        var request = URLRequest(url: URL(string: urlStr)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,             forHTTPHeaderField: "X-API-Key")
        request.httpBody = data
        request.timeoutInterval = 120

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                lastError = "No HTTP response"; return nil
            }
            guard http.statusCode == 200 else {
                let body = String(data: responseData, encoding: .utf8) ?? ""
                lastError = "Server error \(http.statusCode): \(body)"; return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let filename = json["filename"] as? String else {
                lastError = "Unexpected server response"; return nil
            }
            return filename

        } catch {
            lastError = "Upload failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Upload auto-captured photos + camera transforms to the photogrammetry endpoint.
    /// Returns the server session_id on success, nil on failure.
    func uploadPhotos(from dir: URL, posesData: Data?,
                      pointCloudData: Data? = nil,
                      depthMaps: [Data] = [],
                      project: String? = nil) async -> String? {
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
            // Also forward intrinsics and image_size so the labeler can use real focal lengths
            if let intrinsics  = posesObj["intrinsics"]   { payload["intrinsics"]   = intrinsics }
            if let imgSize     = posesObj["image_size"]   { payload["image_size"]  = imgSize }
            if let depthSizes  = posesObj["depth_sizes"]  { payload["depth_sizes"]  = depthSizes }
            if let scanVol     = posesObj["scan_volume"]  { payload["scan_volume"]  = scanVol }
        }
        if let pcData = pointCloudData,
           let pcObj = try? JSONSerialization.jsonObject(with: pcData) {
            payload["point_cloud"] = pcObj
        }
        if !depthMaps.isEmpty {
            payload["depths"] = depthMaps.enumerated().map { (i, d) in
                ["name": String(format: "auto_%04d_depth.bin", i),
                 "data": d.base64EncodedString()]
            }
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            lastError = "Failed to encode payload"
            return nil
        }

        var uploadURL = photosURL
        if let project, !project.isEmpty {
            uploadURL += "?project=\(project.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? project)"
        }
        var request = URLRequest(url: URL(string: uploadURL)!)
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
