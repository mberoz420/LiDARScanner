import Foundation
import Combine

/// Manages CAD file downloads with caching
class DownloadManager: ObservableObject {

    // MARK: - Published Properties
    @Published var activeDownloads: [UUID: DownloadTask] = [:]
    @Published var downloadedFiles: [UUID: URL] = [:]

    // MARK: - Configuration

    struct Configuration {
        var cacheDirectory: URL
        var maxCacheSize: Int64 = 500 * 1024 * 1024 // 500 MB
        var maxConcurrentDownloads = 3
    }

    var configuration: Configuration

    // MARK: - Private Properties
    private let urlSession: URLSession
    private let fileManager = FileManager.default
    private var downloadSemaphore: DispatchSemaphore

    // MARK: - Providers
    private let providers: [CADSource: CADProvider] = [
        .grabcad: GrabCADProvider(),
        .traceparts: TracePartsProvider(),
        .thingiverse: ThingiverseProvider()
    ]

    // MARK: - Initialization

    init() {
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CADFiles", isDirectory: true)

        // Create cache directory if needed
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        self.configuration = Configuration(cacheDirectory: cacheDir)
        self.downloadSemaphore = DispatchSemaphore(value: configuration.maxConcurrentDownloads)

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 60
        sessionConfig.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    // MARK: - Download

    /// Download a CAD file
    @MainActor
    func download(
        file: CADFile,
        preferredFormat: CADFormat = .step,
        progress: ((Float) -> Void)? = nil
    ) async throws -> URL {
        // Check if already cached
        if let cachedURL = getCachedFile(for: file) {
            return cachedURL
        }

        // Create download task
        let taskId = UUID()
        let task = DownloadTask(
            id: taskId,
            file: file,
            status: .queued,
            progress: 0
        )

        activeDownloads[taskId] = task

        do {
            // Get download URL from provider
            guard let provider = providers[file.source] else {
                throw DownloadError.providerNotFound
            }

            let downloadURL = try await provider.getDownloadURL(for: file, format: preferredFormat)

            // Update status
            activeDownloads[taskId]?.status = .downloading

            // Download file
            let localURL = try await downloadFile(
                from: downloadURL,
                taskId: taskId,
                progress: progress
            )

            // Move to cache
            let cachedURL = try cacheFile(localURL, for: file, format: preferredFormat)

            // Update status
            activeDownloads[taskId]?.status = .completed
            activeDownloads[taskId]?.localURL = cachedURL
            downloadedFiles[file.id] = cachedURL

            // Cleanup active download after delay
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    activeDownloads.removeValue(forKey: taskId)
                }
            }

            return cachedURL
        } catch {
            activeDownloads[taskId]?.status = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - File Download

    private func downloadFile(
        from url: URL,
        taskId: UUID,
        progress: ((Float) -> Void)?
    ) async throws -> URL {
        // Wait for semaphore
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.downloadSemaphore.wait()
                continuation.resume()
            }
        }

        defer {
            downloadSemaphore.signal()
        }

        // Create request
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        // Download with progress
        let (asyncBytes, response) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.downloadFailed
        }

        let expectedLength = response.expectedContentLength
        var receivedLength: Int64 = 0

        // Create temp file
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileManager.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)

        defer {
            try? fileHandle.close()
        }

        // Download in chunks
        for try await byte in asyncBytes {
            try fileHandle.write(contentsOf: [byte])
            receivedLength += 1

            // Update progress
            if expectedLength > 0 {
                let currentProgress = Float(receivedLength) / Float(expectedLength)

                // Update on main actor
                await MainActor.run {
                    activeDownloads[taskId]?.progress = currentProgress
                }

                progress?(currentProgress)
            }
        }

        return tempURL
    }

    // MARK: - Caching

    private func getCachedFile(for file: CADFile) -> URL? {
        let filename = cacheFilename(for: file)
        let cachedURL = configuration.cacheDirectory.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        return nil
    }

    private func cacheFile(_ tempURL: URL, for file: CADFile, format: CADFormat) throws -> URL {
        let filename = cacheFilename(for: file, format: format)
        let cachedURL = configuration.cacheDirectory.appendingPathComponent(filename)

        // Remove existing file if needed
        try? fileManager.removeItem(at: cachedURL)

        // Move temp file to cache
        try fileManager.moveItem(at: tempURL, to: cachedURL)

        // Enforce cache size limit
        enforceMaxCacheSize()

        return cachedURL
    }

    private func cacheFilename(for file: CADFile, format: CADFormat? = nil) -> String {
        let ext = format?.rawValue ?? file.format.rawValue
        let safeName = file.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .prefix(50)

        return "\(file.source.rawValue)_\(file.id.uuidString.prefix(8))_\(safeName).\(ext)"
    }

    // MARK: - Cache Management

    /// Get total cache size
    func getCacheSize() -> Int64 {
        let contents = try? fileManager.contentsOfDirectory(
            at: configuration.cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )

        return contents?.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        } ?? 0
    }

    /// Clear all cached files
    func clearCache() throws {
        let contents = try fileManager.contentsOfDirectory(
            at: configuration.cacheDirectory,
            includingPropertiesForKeys: nil
        )

        for url in contents {
            try fileManager.removeItem(at: url)
        }

        downloadedFiles.removeAll()
    }

    /// Remove oldest files to stay under max cache size
    private func enforceMaxCacheSize() {
        let currentSize = getCacheSize()

        guard currentSize > configuration.maxCacheSize else { return }

        // Get files sorted by modification date
        guard let contents = try? fileManager.contentsOfDirectory(
            at: configuration.cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let sortedFiles = contents.compactMap { url -> (URL, Date, Int64)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate,
                  let size = values.fileSize else {
                return nil
            }
            return (url, date, Int64(size))
        }.sorted { $0.1 < $1.1 } // Oldest first

        var removedSize: Int64 = 0
        let targetRemoval = currentSize - configuration.maxCacheSize + (configuration.maxCacheSize / 10) // Remove extra 10%

        for (url, _, size) in sortedFiles {
            guard removedSize < targetRemoval else { break }
            try? fileManager.removeItem(at: url)
            removedSize += size
        }
    }

    // MARK: - Cancel

    /// Cancel a download
    @MainActor
    func cancelDownload(taskId: UUID) {
        activeDownloads[taskId]?.status = .cancelled
        activeDownloads.removeValue(forKey: taskId)
    }
}

// MARK: - Supporting Types

struct DownloadTask: Identifiable {
    let id: UUID
    let file: CADFile
    var status: DownloadStatus
    var progress: Float
    var localURL: URL?

    enum DownloadStatus: Equatable {
        case queued
        case downloading
        case completed
        case failed(String)
        case cancelled
    }
}

enum DownloadError: LocalizedError {
    case providerNotFound
    case downloadFailed
    case cacheFailed
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .providerNotFound:
            return "CAD provider not found."
        case .downloadFailed:
            return "Failed to download file."
        case .cacheFailed:
            return "Failed to cache downloaded file."
        case .fileNotFound:
            return "File not found."
        }
    }
}
