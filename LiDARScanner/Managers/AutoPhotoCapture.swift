import ARKit
import CoreImage
import simd

/// Automatically saves ARFrames as JPEG photos during a LiDAR scan session.
///
/// Capture triggers (whichever comes first):
///   • Time-based:  every `captureInterval` seconds (primary — works while circling an object)
///   • Movement:    camera moved ≥5 cm since last capture
///   • Rotation:    camera rotated ≥10° since last capture
///
/// When a ScanVolume is active, photos are depth-masked to only show surfaces inside the cube.
@MainActor
class AutoPhotoCapture: ObservableObject {

    @Published var isEnabled  = false
    @Published var photoCount = 0

    private(set) var photoDir: URL

    /// When set, depth masking is applied: pixels outside the volume's depth range are blacked out.
    var scanVolume: ScanVolume? = nil

    private var lastCaptureTransform: simd_float4x4?
    private var lastCaptureDate: Date = .distantPast
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Capture thresholds
    private static let captureInterval: TimeInterval = 1.5  // seconds — primary trigger
    private static let minDistanceM:    Float = 0.05        // 5 cm  — movement trigger
    private static let minAngleDeg:     Float = 10.0        // 10°   — rotation trigger
    private static let maxPhotos              = 60

    init() {
        photoDir = Self.makeDir()
    }

    /// Reset all captured photos and restart.
    func reset() {
        try? FileManager.default.removeItem(at: photoDir)
        photoDir = Self.makeDir()
        photoCount = 0
        lastCaptureTransform = nil
        lastCaptureDate = .distantPast
    }

    /// Call from ARSessionDelegate.session(_:didUpdate:) each frame.
    /// Captures when enough time has passed OR camera has moved/rotated enough.
    func process(frame: ARFrame) {
        guard isEnabled, photoCount < Self.maxPhotos else { return }

        let t   = frame.camera.transform
        let now = Date()

        // Decide whether to capture
        if let last = lastCaptureTransform {
            let elapsed = now.timeIntervalSince(lastCaptureDate)

            // Time-based trigger (primary): take a photo every captureInterval seconds
            let timeTrigger = elapsed >= Self.captureInterval

            // Movement triggers (secondary): useful when user moves fast
            let dp = SIMD3<Float>(
                t.columns.3.x - last.columns.3.x,
                t.columns.3.y - last.columns.3.y,
                t.columns.3.z - last.columns.3.z
            )
            let dist     = simd_length(dp)
            let fwd      = SIMD3<Float>(t.columns.2.x,    t.columns.2.y,    t.columns.2.z)
            let lastFwd  = SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z)
            let dot      = simd_clamp(simd_dot(fwd, lastFwd), -1, 1)
            let angleDeg = acos(dot) * (180 / Float.pi)
            let moveTrigger = dist >= Self.minDistanceM || angleDeg >= Self.minAngleDeg

            guard timeTrigger || moveTrigger else { return }
        }

        guard let data = buildImageData(frame: frame, transform: t) else { return }

        let url = photoDir.appendingPathComponent(String(format: "auto_%04d.jpg", photoCount))
        do {
            try data.write(to: url)
            photoCount += 1
            lastCaptureTransform = t
            lastCaptureDate = now
        } catch {}
    }

    /// Force-capture the current frame regardless of thresholds (manual shutter).
    @discardableResult
    func captureNow(frame: ARFrame) -> URL? {
        guard photoCount < Self.maxPhotos else { return nil }
        let t = frame.camera.transform
        guard let data = buildImageData(frame: frame, transform: t) else { return nil }

        let url = photoDir.appendingPathComponent(String(format: "auto_%04d.jpg", photoCount))
        do {
            try data.write(to: url)
            photoCount += 1
            lastCaptureTransform = t
            lastCaptureDate = Date()
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

    private func buildImageData(frame: ARFrame, transform: simd_float4x4) -> Data? {
        if let volume = scanVolume,
           let sceneDepth = frame.sceneDepth {
            let cam = transform.columns.3
            let camPos = SIMD3<Float>(cam.x, cam.y, cam.z)
            let targetDepth = simd_length(volume.center - camPos)
            return DepthMaskProcessor.masked(
                imageBuffer: frame.capturedImage,
                depthMap:    sceneDepth.depthMap,
                targetDepth: targetDepth,
                buffer:      volume.halfExtent
            )
        } else {
            let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
        }
    }

    private static func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto_scan_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
