import Foundation
import SwiftUI
import AuthenticationServices

/// Manages Google Drive authentication and file uploads using web-based OAuth
@MainActor
class GoogleDriveManager: NSObject, ObservableObject {
    static let shared = GoogleDriveManager()

    @Published var isSignedIn = false
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0
    @Published var lastError: String?
    @Published var userEmail: String?

    // Stored tokens
    @AppStorage("googleAccessToken") private var accessToken: String = ""
    @AppStorage("googleRefreshToken") private var refreshToken: String = ""
    @AppStorage("googleTokenExpiry") private var tokenExpiry: Double = 0

    // Configuration
    @AppStorage("googleClientID") var clientID: String = ""
    @AppStorage("googleDriveFolderName") private var folderName: String = "LiDAR Scans"

    // OAuth configuration
    private let redirectScheme = "com.lidarscanner.oauth"
    private let redirectURI: String

    // Google OAuth endpoints
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let driveUploadURL = "https://www.googleapis.com/upload/drive/v3/files"
    private let driveFilesURL = "https://www.googleapis.com/drive/v3/files"

    // Scopes
    private let scopes = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email"

    private var webAuthSession: ASWebAuthenticationSession?

    override init() {
        redirectURI = "\(redirectScheme):/oauth2callback"
        super.init()

        // Check if we have a valid token
        if !accessToken.isEmpty && tokenExpiry > Date().timeIntervalSince1970 {
            isSignedIn = true
        }
    }

    // MARK: - Configuration

    var isConfigured: Bool {
        !clientID.isEmpty
    }

    // MARK: - Sign In

    func signIn() async -> Bool {
        guard isConfigured else {
            lastError = "Google Client ID not configured. Go to Settings to set it up."
            return false
        }

        // Build OAuth URL
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authorizationURL = components.url else {
            lastError = "Failed to build authorization URL"
            return false
        }

        return await withCheckedContinuation { continuation in
            webAuthSession = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: redirectScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self = self else {
                        continuation.resume(returning: false)
                        return
                    }

                    if let error = error {
                        if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            self.lastError = "Sign in cancelled"
                        } else {
                            self.lastError = "Sign in failed: \(error.localizedDescription)"
                        }
                        continuation.resume(returning: false)
                        return
                    }

                    guard let callbackURL = callbackURL,
                          let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "code" })?.value else {
                        self.lastError = "No authorization code received"
                        continuation.resume(returning: false)
                        return
                    }

                    // Exchange code for tokens
                    let success = await self.exchangeCodeForTokens(code)
                    continuation.resume(returning: success)
                }
            }

            webAuthSession?.presentationContextProvider = self
            webAuthSession?.prefersEphemeralWebBrowserSession = false
            webAuthSession?.start()
        }
    }

    private func exchangeCodeForTokens(_ code: String) async -> Bool {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(clientID)",
            "code=\(code)",
            "grant_type=authorization_code",
            "redirect_uri=\(redirectURI)"
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                lastError = "Failed to exchange code for tokens"
                return false
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else {
                lastError = "Invalid token response"
                return false
            }

            accessToken = newAccessToken
            if let newRefreshToken = json["refresh_token"] as? String {
                refreshToken = newRefreshToken
            }
            if let expiresIn = json["expires_in"] as? Int {
                tokenExpiry = Date().timeIntervalSince1970 + Double(expiresIn)
            }

            isSignedIn = true

            // Get user email
            await fetchUserEmail()

            return true
        } catch {
            lastError = "Token exchange failed: \(error.localizedDescription)"
            return false
        }
    }

    private func fetchUserEmail() async {
        guard !accessToken.isEmpty else { return }

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let email = json["email"] as? String {
                userEmail = email
            }
        } catch {
            // Ignore email fetch errors
        }
    }

    func signOut() {
        accessToken = ""
        refreshToken = ""
        tokenExpiry = 0
        isSignedIn = false
        userEmail = nil
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async -> Bool {
        guard !refreshToken.isEmpty else {
            lastError = "No refresh token available"
            return false
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(clientID)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token"
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                lastError = "Failed to refresh token"
                return false
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else {
                lastError = "Invalid refresh response"
                return false
            }

            accessToken = newAccessToken
            if let expiresIn = json["expires_in"] as? Int {
                tokenExpiry = Date().timeIntervalSince1970 + Double(expiresIn)
            }

            return true
        } catch {
            lastError = "Token refresh failed: \(error.localizedDescription)"
            return false
        }
    }

    private func ensureValidToken() async -> Bool {
        // If token is expired or will expire soon, refresh it
        if tokenExpiry < Date().timeIntervalSince1970 + 60 {
            if !refreshToken.isEmpty {
                return await refreshAccessToken()
            } else {
                // Need to sign in again
                return await signIn()
            }
        }
        return true
    }

    // MARK: - Upload

    func uploadFile(at url: URL, mimeType: String = "application/octet-stream") async -> Bool {
        guard isConfigured else {
            lastError = "Google Drive not configured"
            return false
        }

        if !isSignedIn {
            guard await signIn() else { return false }
        }

        guard await ensureValidToken() else { return false }

        isUploading = true
        uploadProgress = 0
        lastError = nil

        do {
            // Find or create folder
            let folderId = try await findOrCreateFolder()

            // Upload file
            let success = try await uploadFileToFolder(url: url, folderId: folderId, mimeType: mimeType)

            isUploading = false
            uploadProgress = success ? 1.0 : 0

            return success
        } catch {
            lastError = "Upload failed: \(error.localizedDescription)"
            isUploading = false
            return false
        }
    }

    private func findOrCreateFolder() async throws -> String {
        let query = "name='\(folderName)' and mimeType='application/vnd.google-apps.folder' and trashed=false"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        var searchRequest = URLRequest(url: URL(string: "\(driveFilesURL)?q=\(encodedQuery)")!)
        searchRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: searchRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "GoogleDrive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to search for folder"])
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = json["files"] as? [[String: Any]],
           let firstFolder = files.first,
           let folderId = firstFolder["id"] as? String {
            return folderId
        }

        // Create new folder
        return try await createFolder()
    }

    private func createFolder() async throws -> String {
        var request = URLRequest(url: URL(string: driveFilesURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let folderMetadata: [String: Any] = [
            "name": folderName,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: folderMetadata)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "GoogleDrive", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create folder"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folderId = json["id"] as? String else {
            throw NSError(domain: "GoogleDrive", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid folder response"])
        }

        return folderId
    }

    private func uploadFileToFolder(url: URL, folderId: String, mimeType: String) async throws -> Bool {
        let fileName = url.lastPathComponent
        let fileData = try Data(contentsOf: url)

        // Create multipart upload
        let boundary = UUID().uuidString
        var body = Data()

        // Metadata part
        let metadata: [String: Any] = [
            "name": fileName,
            "parents": [folderId]
        ]
        let metadataJson = try JSONSerialization.data(withJSONObject: metadata)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJson)
        body.append("\r\n".data(using: .utf8)!)

        // File part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "\(driveUploadURL)?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return false
        }

        return httpResponse.statusCode == 200
    }

    // MARK: - MIME Types

    func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "usdz":
            return "model/vnd.usdz+zip"
        case "ply":
            return "application/x-ply"
        case "obj":
            return "text/plain"
        default:
            return "application/octet-stream"
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GoogleDriveManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Return the key window
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first ?? ASPresentationAnchor()
    }
}
