import Foundation
import SwiftUI
import Combine

/// Manages saving, loading, and listing scan sessions
@MainActor
class ScanSessionManager: ObservableObject {
    static let shared = ScanSessionManager()

    // MARK: - Published State

    @Published var savedSessions: [SessionMetadata] = []
    @Published var currentSessionId: UUID?
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var lastError: String?

    // MARK: - Storage

    private var sessionsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ScanSessions", isDirectory: true)
    }

    private let metadataFileName = "sessions_index.json"

    // MARK: - Initialization

    private init() {
        ensureDirectoryExists()
        loadSessionsList()
    }

    private func ensureDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sessionsDirectory.path) {
            try? fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - List Sessions

    /// Load list of saved sessions (metadata only, not full mesh data)
    func loadSessionsList() {
        let metadataURL = sessionsDirectory.appendingPathComponent(metadataFileName)

        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([SessionMetadata].self, from: data) else {
            savedSessions = []
            return
        }

        savedSessions = metadata.sorted { $0.lastModifiedAt > $1.lastModifiedAt }
    }

    /// Save sessions list to disk
    private func saveSessionsList() {
        let metadataURL = sessionsDirectory.appendingPathComponent(metadataFileName)

        if let data = try? JSONEncoder().encode(savedSessions) {
            try? data.write(to: metadataURL)
        }
    }

    // MARK: - Save Session

    /// Save a scan session to disk
    func saveSession(
        _ scan: CapturedScan,
        name: String,
        mode: ScanMode,
        qualityScores: [UUID: Float] = [:]
    ) async throws -> UUID {
        isSaving = true
        lastError = nil

        defer { isSaving = false }

        do {
            // Create session object
            let session = try SavedScanSession(
                name: name,
                scan: scan,
                mode: mode,
                qualityScores: qualityScores
            )

            // Save to file
            let sessionURL = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
            let data = try JSONEncoder().encode(session)

            // Compress data
            let compressedData = try (data as NSData).compressed(using: .lzfse) as Data
            try compressedData.write(to: sessionURL)

            // Update metadata list
            let metadata = SessionMetadata(from: session)
            savedSessions.insert(metadata, at: 0)
            saveSessionsList()

            currentSessionId = session.id

            print("[ScanSessionManager] Saved session: \(name) (\(scan.vertexCount) vertices)")

            return session.id

        } catch {
            lastError = "Failed to save: \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: - Load Session

    /// Load a full scan session from disk
    func loadSession(_ id: UUID) async throws -> (scan: CapturedScan, mode: ScanMode) {
        isLoading = true
        lastError = nil

        defer { isLoading = false }

        do {
            let sessionURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")

            guard FileManager.default.fileExists(atPath: sessionURL.path) else {
                throw SessionError.sessionNotFound
            }

            // Load and decompress
            let compressedData = try Data(contentsOf: sessionURL)
            let data = try (compressedData as NSData).decompressed(using: .lzfse) as Data
            let session = try JSONDecoder().decode(SavedScanSession.self, from: data)

            // Convert to CapturedScan
            let scan = try session.toCapturedScan()

            // Get scan mode
            let mode = ScanMode(rawValue: session.scanMode) ?? .fast

            currentSessionId = id

            print("[ScanSessionManager] Loaded session: \(session.name) (\(scan.vertexCount) vertices)")

            return (scan, mode)

        } catch {
            lastError = "Failed to load: \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: - Update Session

    /// Update an existing session with new scan data
    func updateSession(
        _ id: UUID,
        with scan: CapturedScan,
        qualityScores: [UUID: Float] = [:]
    ) async throws {
        isSaving = true
        lastError = nil

        defer { isSaving = false }

        do {
            let sessionURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")

            guard FileManager.default.fileExists(atPath: sessionURL.path) else {
                throw SessionError.sessionNotFound
            }

            // Load existing session
            let compressedData = try Data(contentsOf: sessionURL)
            let data = try (compressedData as NSData).decompressed(using: .lzfse) as Data
            var session = try JSONDecoder().decode(SavedScanSession.self, from: data)

            // Update with new data
            try session.update(with: scan, qualityScores: qualityScores)

            // Save back
            let newData = try JSONEncoder().encode(session)
            let newCompressedData = try (newData as NSData).compressed(using: .lzfse) as Data
            try newCompressedData.write(to: sessionURL)

            // Update metadata
            if let index = savedSessions.firstIndex(where: { $0.id == id }) {
                savedSessions[index] = SessionMetadata(from: session)
                saveSessionsList()
            }

            print("[ScanSessionManager] Updated session: \(session.name)")

        } catch {
            lastError = "Failed to update: \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: - Delete Session

    /// Delete a saved session
    func deleteSession(_ id: UUID) throws {
        let sessionURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")

        if FileManager.default.fileExists(atPath: sessionURL.path) {
            try FileManager.default.removeItem(at: sessionURL)
        }

        savedSessions.removeAll { $0.id == id }
        saveSessionsList()

        if currentSessionId == id {
            currentSessionId = nil
        }

        print("[ScanSessionManager] Deleted session: \(id)")
    }

    // MARK: - Rename Session

    /// Rename a saved session
    func renameSession(_ id: UUID, to newName: String) throws {
        let sessionURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")

        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            throw SessionError.sessionNotFound
        }

        // Load, modify, save
        let compressedData = try Data(contentsOf: sessionURL)
        let data = try (compressedData as NSData).decompressed(using: .lzfse) as Data
        var session = try JSONDecoder().decode(SavedScanSession.self, from: data)

        session.name = newName
        session.lastModifiedAt = Date()

        let newData = try JSONEncoder().encode(session)
        let newCompressedData = try (newData as NSData).compressed(using: .lzfse) as Data
        try newCompressedData.write(to: sessionURL)

        // Update metadata
        if let index = savedSessions.firstIndex(where: { $0.id == id }) {
            savedSessions[index] = SessionMetadata(from: session)
            saveSessionsList()
        }
    }

    // MARK: - Thumbnail

    /// Generate and save thumbnail for a session
    func saveThumbnail(_ image: UIImage, for sessionId: UUID) {
        guard let jpegData = image.jpegData(compressionQuality: 0.5) else { return }

        let thumbnailURL = sessionsDirectory.appendingPathComponent("\(sessionId.uuidString)_thumb.jpg")
        try? jpegData.write(to: thumbnailURL)
    }

    /// Load thumbnail for a session
    func loadThumbnail(for sessionId: UUID) -> UIImage? {
        let thumbnailURL = sessionsDirectory.appendingPathComponent("\(sessionId.uuidString)_thumb.jpg")

        guard let data = try? Data(contentsOf: thumbnailURL) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Helpers

    /// Generate default session name
    func generateDefaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Scan \(formatter.string(from: Date()))"
    }

    /// Get storage size of all sessions
    func totalStorageSize() -> Int64 {
        let fm = FileManager.default
        var totalSize: Int64 = 0

        if let enumerator = fm.enumerator(at: sessionsDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                }
            }
        }

        return totalSize
    }

    /// Format storage size for display
    func formattedStorageSize() -> String {
        let bytes = totalStorageSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Errors

enum SessionError: LocalizedError {
    case sessionNotFound
    case invalidData
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        case .invalidData:
            return "Invalid session data"
        case .compressionFailed:
            return "Failed to compress/decompress data"
        }
    }
}
