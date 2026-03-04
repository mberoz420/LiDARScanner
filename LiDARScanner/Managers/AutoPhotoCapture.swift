import ARKit
import CoreImage
import simd

/// Automatically saves ARFrames as JPEG photos during a LiDAR scan session.
/// A photo is captured when the camera has moved ≥8 cm or rotated ≥15° since the last capture.
@MainActor
class AutoPhotoCapture: ObservableObject {

    @Published var isEnabled  = false
    @Published var photoCount = 0

    private(set) var photoDir: URL

    private var lastCaptureTransform: simd_float4x4?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Movement thresholds
    private static let minDistanceM: Float = 0.08   // 8 cm
    private static let minAngleDeg:  Float = 15.0   // 15°
    private static let maxPhotos           = 60

    init() {
        photoDir = Self.makeDir()
    }

    /// Reset all captured photos and restart.
    func reset() {
        try? FileManager.default.removeItem(at: photoDir)
        photoDir = Self.makeDir()
        photoCount = 0
        lastCaptureTransform = nil
    }

    /// Call from ARSessionDelegate.session(_:didUpdate:) each frame.
    /// Only saves when `isEnabled` and movement threshold is exceeded.
    func process(frame: ARFrame) {
        guard isEnabled, photoCount < Self.maxPhotos else { return }

        let t = frame.camera.transform

        // Check whether camera has moved enough since last capture
        if let last = lastCaptureTransform {
            let dp = SIMD3<Float>(
                t.columns.3.x - last.columns.3.x,
                t.columns.3.y - last.columns.3.y,
                t.columns.3.z - last.columns.3.z
            )
            let dist = simd_length(dp)

            let fwd     = SIMD3<Float>(t.columns.2.x,    t.columns.2.y,    t.columns.2.z)
            let lastFwd = SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z)
            let dot     = simd_clamp(simd_dot(fwd, lastFwd), -1, 1)
            let angleDeg = acos(dot) * (180 / Float.pi)

            guard dist >= Self.minDistanceM || angleDeg >= Self.minAngleDeg else { return }
        }

        // Convert YCbCr CVPixelBuffer → JPEG (oriented upright for photogrammetry)
        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { return }

        let url = photoDir.appendingPathComponent(String(format: "auto_%04d.jpg", photoCount))
        do {
            try data.write(to: url)
            photoCount += 1
            lastCaptureTransform = t
        } catch {}
    }

    /// All captured photo URLs, sorted by capture order.
    func photoURLs() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: photoDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Private

    private static func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto_scan_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
