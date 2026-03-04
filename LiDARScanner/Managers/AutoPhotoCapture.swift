import ARKit
import CoreImage
import simd

/// Automatically saves ARFrames as JPEG photos during a LiDAR scan session.
///
/// Capture trigger — stillness detection:
///   1. Compute per-frame translation speed (m/s) and rotation speed (°/s).
///   2. Smooth both with an exponential moving average.
///   3. When speed drops below threshold for ≥`stillDuration` seconds → capture.
///   4. After capture, require the camera to move ≥`minMoveDist` OR ≥`minMoveAngle`
///      before the next stillness capture is eligible (avoids duplicate shots).
///
/// Manual shutter via captureNow() bypasses all thresholds.
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
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Camera pose (simd_float4x4) recorded at the moment each photo was captured.
    /// Index N corresponds to auto_000N.jpg.
    private(set) var cameraPoses: [simd_float4x4] = []

    // ── Stillness detection state ─────────────────────────────────────────────
    private var prevFrameTransform: simd_float4x4?
    private var prevFrameDate: Date = .distantPast
    private var smoothedSpeedMs: Float    = 0   // m/s,  EMA
    private var smoothedAngularDs: Float  = 0   // °/s,  EMA
    private var stillSince: Date?               // when camera first became still

    // ── Thresholds ────────────────────────────────────────────────────────────
    private static let maxPhotos         = 60
    /// EMA coefficient — lower = more smoothing of high-freq hand tremor
    private static let α: Float          = 0.08
    /// Camera is "still" when smoothed linear speed is below this (m/s).
    /// Hand tremor in ARKit tracking ≈ 3–8 cm/s, so 10 cm/s clearly separates
    /// "genuinely still" from "moving".
    private static let stillSpeedMs: Float   = 0.10   // 10 cm/s
    /// Camera is "still" when smoothed angular speed is below this (°/s)
    private static let stillAngDs: Float     = 6.0    // 6°/s
    /// How long the camera must stay still before a capture fires (seconds)
    private static let stillDuration: TimeInterval = 0.6
    /// Minimum position change from last capture before another stillness capture is eligible
    private static let minMoveDist: Float = 0.07      // 7 cm
    /// Minimum angle change from last capture before another stillness capture is eligible
    private static let minMoveAngle: Float = 12.0     // 12°

    init() {
        photoDir = Self.makeDir()
    }

    /// Reset all captured photos and restart.
    func reset() {
        try? FileManager.default.removeItem(at: photoDir)
        photoDir = Self.makeDir()
        photoCount = 0
        lastCaptureTransform = nil
        cameraPoses = []
        prevFrameTransform = nil
        prevFrameDate = .distantPast
        smoothedSpeedMs   = 0
        smoothedAngularDs = 0
        stillSince = nil
    }

    /// Call from ARSessionDelegate.session(_:didUpdate:) each frame.
    /// Captures when the camera has been still for `stillDuration` seconds
    /// AND has moved enough since the previous capture.
    func process(frame: ARFrame) {
        guard isEnabled, photoCount < Self.maxPhotos else { return }

        let t   = frame.camera.transform
        let now = Date()

        // ── 1. Compute per-frame velocity ─────────────────────────────────────
        if let prev = prevFrameTransform {
            let dt = Float(max(now.timeIntervalSince(prevFrameDate), 0.001))

            let dp = SIMD3<Float>(
                t.columns.3.x - prev.columns.3.x,
                t.columns.3.y - prev.columns.3.y,
                t.columns.3.z - prev.columns.3.z
            )
            let speedMs = simd_length(dp) / dt                                    // m/s

            let fwd     = SIMD3<Float>(t.columns.2.x,    t.columns.2.y,    t.columns.2.z)
            let prevFwd = SIMD3<Float>(prev.columns.2.x, prev.columns.2.y, prev.columns.2.z)
            let dot     = simd_clamp(simd_dot(fwd, prevFwd), -1, 1)
            let angDs   = acos(dot) * (180 / Float.pi) / dt                       // °/s

            // Exponential moving average — smooths out per-frame jitter
            smoothedSpeedMs   = smoothedSpeedMs   * (1 - Self.α) + speedMs * Self.α
            smoothedAngularDs = smoothedAngularDs * (1 - Self.α) + angDs   * Self.α
        }
        prevFrameTransform = t
        prevFrameDate      = now

        // ── 2. Detect stillness ───────────────────────────────────────────────
        let isStill = smoothedSpeedMs < Self.stillSpeedMs && smoothedAngularDs < Self.stillAngDs
        if isStill {
            if stillSince == nil { stillSince = now }
        } else {
            stillSince = nil
        }

        guard let since = stillSince,
              now.timeIntervalSince(since) >= Self.stillDuration else { return }

        // ── 3. Require minimum displacement from last capture ─────────────────
        if let last = lastCaptureTransform {
            let dp = SIMD3<Float>(
                t.columns.3.x - last.columns.3.x,
                t.columns.3.y - last.columns.3.y,
                t.columns.3.z - last.columns.3.z
            )
            let dist    = simd_length(dp)
            let fwd     = SIMD3<Float>(t.columns.2.x,    t.columns.2.y,    t.columns.2.z)
            let lastFwd = SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z)
            let dot     = simd_clamp(simd_dot(fwd, lastFwd), -1, 1)
            let angle   = acos(dot) * (180 / Float.pi)
            guard dist >= Self.minMoveDist || angle >= Self.minMoveAngle else { return }
        }

        // ── 4. Capture ────────────────────────────────────────────────────────
        guard let data = buildImageData(frame: frame, transform: t) else { return }

        let url = photoDir.appendingPathComponent(String(format: "auto_%04d.jpg", photoCount))
        do {
            try data.write(to: url)
            photoCount += 1
            lastCaptureTransform = t
            cameraPoses.append(t)
            stillSince = nil   // reset so next capture requires stopping again
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
            cameraPoses.append(t)
            stillSince = nil
            return url
        } catch {
            return nil
        }
    }

    /// Serializes all camera poses as a JSON object for upload.
    /// Each pose is a 16-element column-major Float array (simd_float4x4 layout).
    func posesJSON() -> Data? {
        let matrices = cameraPoses.map { m -> [Float] in
            [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
             m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
             m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
             m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
        }
        return try? JSONSerialization.data(
            withJSONObject: ["camera_poses": matrices],
            options: .prettyPrinted
        )
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
