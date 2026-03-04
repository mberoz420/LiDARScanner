import ARKit
import CoreImage
import simd

/// Automatically saves ARFrames as JPEG photos during a LiDAR scan session.
/// A photo is captured when the camera has moved ≥8 cm or rotated ≥15° since the last capture.
/// When a ScanVolume is active, photos are depth-masked to only show surfaces inside the cube.
@MainActor
class AutoPhotoCapture: ObservableObject {

    @Published var isEnabled  = false
    @Published var photoCount = 0

    private(set) var photoDir: URL

    /// When set, depth masking is applied: pixels outside the volume's depth range are blacked out.
    var scanVolume: ScanVolume? = nil

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

        // Build image data — depth-masked when a scan volume is active
        let data: Data?
        if let volume = scanVolume,
           let sceneDepth = frame.sceneDepth {
            // Distance from camera to volume centre = target depth for masking
            let cam = t.columns.3
            let camPos = SIMD3<Float>(cam.x, cam.y, cam.z)
            let targetDepth = simd_length(volume.center - camPos)
            data = DepthMaskProcessor.masked(
                imageBuffer: frame.capturedImage,
                depthMap:    sceneDepth.depthMap,
                targetDepth: targetDepth,
                buffer:      volume.halfExtent
            )
        } else {
            // No depth masking — convert YCbCr → JPEG directly
            let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
            data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
        }

        guard let data else { return }

        let url = photoDir.appendingPathComponent(String(format: "auto_%04d.jpg", photoCount))
        do {
            try data.write(to: url)
            photoCount += 1
            lastCaptureTransform = t
        } catch {}
    }

    /// Force-capture the current frame regardless of movement thresholds.
    /// Returns the saved URL on success. Use this for the manual shutter button.
    @discardableResult
    func captureNow(frame: ARFrame) -> URL? {
        guard photoCount < Self.maxPhotos else { return nil }
        let t = frame.camera.transform

        let data: Data?
        if let volume = scanVolume,
           let sceneDepth = frame.sceneDepth {
            let cam = t.columns.3
            let camPos = SIMD3<Float>(cam.x, cam.y, cam.z)
            let targetDepth = simd_length(volume.center - camPos)
            data = DepthMaskProcessor.masked(
                imageBuffer: frame.capturedImage,
                depthMap:    sceneDepth.depthMap,
                targetDepth: targetDepth,
                buffer:      volume.halfExtent
            )
        } else {
            let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
            data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
        }

        guard let data else { return nil }

        let url = photoDir.appendingPathComponent(String(format: "auto_%04d.jpg", photoCount))
        do {
            try data.write(to: url)
            photoCount += 1
            lastCaptureTransform = t
            return url
        } catch {
            return nil
        }
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
