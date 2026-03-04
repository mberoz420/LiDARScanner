import SwiftUI
import AVFoundation
import ARKit
import RealityKit
import CoreImage
import CoreMedia

// MARK: - Geometry Analyzer

// MARK: - Quality Preset

enum PhotogrammetryPreset: String, CaseIterable, Identifiable {
    case quick    = "Quick"
    case standard = "Standard"
    case detailed = "Detailed"
    case free     = "Free"

    var id: String { rawValue }

    var targetCount: Int? {
        switch self {
        case .quick:    return 10
        case .standard: return 25
        case .detailed: return 50
        case .free:     return nil
        }
    }

    var minToProcess: Int {
        switch self {
        case .quick:    return 5
        case .standard: return 10
        case .detailed: return 20
        case .free:     return 5
        }
    }
}

// MARK: - Camera Controller

// MARK: - Depth Mask Processor

struct DepthMaskProcessor {

    /// Applies a depth-range mask to a captured photo.
    /// Pixels whose depth is outside [targetDepth-buffer, targetDepth+buffer] become black.
    /// Returns a masked JPEG, or the original data if depth is unavailable.
    static func masked(photo: AVCapturePhoto,
                       targetDepth: Float,
                       buffer: Float) -> Data? {

        guard let depthData = photo.depthData,
              let cgImage   = photo.cgImageRepresentation() else {
            return photo.fileDataRepresentation()
        }

        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap   = converted.depthDataMap

        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            return photo.fileDataRepresentation()
        }

        let depthPtr = base.assumingMemoryBound(to: Float32.self)
        let minD = targetDepth - buffer
        let maxD = targetDepth + buffer

        // Build a grayscale mask the same size as the depth map
        var maskBytes = [UInt8](repeating: 0, count: depthW * depthH)
        for i in 0..<(depthW * depthH) {
            let d = depthPtr[i]
            maskBytes[i] = (d.isFinite && d > 0 && d >= minD && d <= maxD) ? 255 : 0
        }

        // Create mask as CIImage (will be scaled to photo size by CoreImage)
        let maskColorSpace = CGColorSpaceCreateDeviceGray()
        guard let maskProvider = CGDataProvider(data: Data(maskBytes) as CFData),
              let maskCG = CGImage(width: depthW, height: depthH,
                                   bitsPerComponent: 8, bitsPerPixel: 8,
                                   bytesPerRow: depthW,
                                   space: maskColorSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: 0),
                                   provider: maskProvider,
                                   decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent) else {
            return photo.fileDataRepresentation()
        }

        // Scale mask to photo resolution using CIImage blend
        let ciPhoto  = CIImage(cgImage: cgImage)
        let ciMask   = CIImage(cgImage: maskCG)
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(cgImage.width)  / CGFloat(depthW),
                y:      CGFloat(cgImage.height) / CGFloat(depthH)))

        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
            return photo.fileDataRepresentation()
        }
        blendFilter.setValue(ciPhoto,         forKey: kCIInputImageKey)
        blendFilter.setValue(CIImage.black,   forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(ciMask,          forKey: kCIInputMaskImageKey)

        guard let output = blendFilter.outputImage else {
            return photo.fileDataRepresentation()
        }

        let ctx = CIContext()
        guard let maskedCG = ctx.createCGImage(output, from: output.extent) else {
            return photo.fileDataRepresentation()
        }

        // Return as JPEG
        let uiImage = UIImage(cgImage: maskedCG)
        return uiImage.jpegData(compressionQuality: 0.92)
    }

    /// Mask a raw CVPixelBuffer (e.g. ARFrame.capturedImage) using a LiDAR depth map.
    /// Pixels whose depth is outside [targetDepth ± buffer] are blacked out.
    /// Returns a JPEG-encoded masked image, or nil on failure.
    static func masked(
        imageBuffer: CVPixelBuffer,
        depthMap: CVPixelBuffer,
        targetDepth: Float,
        buffer: Float
    ) -> Data? {
        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)
        let imgW   = CVPixelBufferGetWidth(imageBuffer)
        let imgH   = CVPixelBufferGetHeight(imageBuffer)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)

        let minD = targetDepth - buffer
        let maxD = targetDepth + buffer
        var maskBytes = [UInt8](repeating: 0, count: depthW * depthH)
        for i in 0..<(depthW * depthH) {
            let d = depthPtr[i]
            maskBytes[i] = (d.isFinite && d > 0 && d >= minD && d <= maxD) ? 255 : 0
        }

        let maskCS = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(maskBytes) as CFData),
              let maskCG   = CGImage(width: depthW, height: depthH,
                                     bitsPerComponent: 8, bitsPerPixel: 8,
                                     bytesPerRow: depthW, space: maskCS,
                                     bitmapInfo: CGBitmapInfo(rawValue: 0),
                                     provider: provider,
                                     decode: nil, shouldInterpolate: true,
                                     intent: .defaultIntent) else { return nil }

        // Orient YCbCr image and scale mask to photo size
        let ciPhoto = CIImage(cvPixelBuffer: imageBuffer).oriented(.right)
        let ciMask  = CIImage(cgImage: maskCG)
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(imgW) / CGFloat(depthW),
                y:      CGFloat(imgH) / CGFloat(depthH)))

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(ciPhoto,         forKey: kCIInputImageKey)
        blend.setValue(CIImage.black,   forKey: kCIInputBackgroundImageKey)
        blend.setValue(ciMask,          forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage else { return nil }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let maskedCG = ctx.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: maskedCG).jpegData(compressionQuality: 0.85)
    }

    /// Sample depth at a normalised point (0–1, 0–1) from a CVPixelBuffer depth map.
    static func sampleDepth(from depthMap: CVPixelBuffer, at normalised: CGPoint) -> Float? {
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let x = max(0, min(w - 1, Int(normalised.x * CGFloat(w))))
        let y = max(0, min(h - 1, Int(normalised.y * CGFloat(h))))

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let depth = base.assumingMemoryBound(to: Float32.self)[y * w + x]
        return (depth.isFinite && depth > 0) ? depth : nil
    }
}

// MARK: - Photo Controller

@MainActor
class PhotogrammetryController: NSObject, ObservableObject {
    @Published var capturedCount = 0
    @Published var isRunning = false
    @Published var lastThumbnail: UIImage?

    // Depth masking
    @Published var targetDepth: Float? = nil    // metres — nil = no masking
    @Published var depthBuffer: Float = 0.25    // ± metres around targetDepth
    @Published private(set) var latestDepthMap: CVPixelBuffer?  // live depth from LiDAR

    private let captureSession  = AVCaptureSession()
    private let photoOutput     = AVCapturePhotoOutput()
    private let depthOutput     = AVCaptureDepthDataOutput()
    private let depthQueue      = DispatchQueue(label: "depth.queue")

    let previewLayer = AVCaptureVideoPreviewLayer()
    let tempDir: URL

    private var captureCallback: ((URL) -> Void)?

    /// Sample live depth (metres) at a normalised point (0–1, 0–1) from the LiDAR depth map.
    func sampleDepth(at normalised: CGPoint) -> Float? {
        guard let map = latestDepthMap else { return nil }
        return DepthMaskProcessor.sampleDepth(from: map, at: normalised)
    }

    /// `existingDir`: reuse an existing photo directory (e.g. auto-captured during LiDAR scan).
    /// Pass `nil` to create a fresh temp directory.
    init(existingDir: URL? = nil) {
        if let dir = existingDir {
            tempDir = dir
        } else {
            let newDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("photogrammetry_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            tempDir = newDir
        }
        super.init()
        setupSession()
        // Sync capturedCount so new files don't overwrite pre-existing photos
        if existingDir != nil {
            let existing = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
            capturedCount = existing.filter { ["jpg","heic","png"].contains($0.pathExtension.lowercased()) }.count
        }
    }

    private func setupSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back),
              let input  = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(input)

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
        }

        // Live depth stream for tap-to-set-depth (LiDAR / dual-camera devices)
        if captureSession.canAddOutput(depthOutput) {
            captureSession.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = false
            depthOutput.setDelegate(self, callbackQueue: depthQueue)
        }

        captureSession.commitConfiguration()

        previewLayer.session = captureSession
        previewLayer.videoGravity = .resizeAspectFill
    }

    func start() {
        guard !captureSession.isRunning else { return }
        let session = captureSession
        Task.detached(priority: .userInitiated) {
            session.startRunning()
        }
        isRunning = true
    }

    func stop() {
        guard captureSession.isRunning else { return }
        let session = captureSession
        Task.detached(priority: .userInitiated) {
            session.stopRunning()
        }
        isRunning = false
    }

    func capturePhoto(completion: @escaping (URL) -> Void) {
        captureCallback = completion
        var settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        if photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.isDepthDataFiltered        = false
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

extension PhotogrammetryController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil else { return }

        Task { @MainActor in
            // Apply depth mask when a target depth is set
            let data: Data?
            if let target = self.targetDepth {
                data = DepthMaskProcessor.masked(photo: photo, targetDepth: target, buffer: self.depthBuffer)
            } else {
                data = photo.fileDataRepresentation()
            }
            guard let data else { return }

            let filename = String(format: "%04d.heic", self.capturedCount)
            let url = self.tempDir.appendingPathComponent(filename)
            try? data.write(to: url)

            if let image = UIImage(data: data) {
                self.lastThumbnail = image
            }

            self.capturedCount += 1
            self.captureCallback?(url)
            self.captureCallback = nil
        }
    }
}

extension PhotogrammetryController: AVCaptureDepthDataOutputDelegate {
    nonisolated func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                                     didOutput depthData: AVDepthData,
                                     timestamp: CMTime,
                                     connection: AVCaptureConnection) {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap
        Task { @MainActor in
            self.latestDepthMap = map
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

/// UIView subclass that keeps the preview layer filling its bounds on every layout pass.
class CameraPreviewContainer: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let controller: PhotogrammetryController

    func makeUIView(context: Context) -> CameraPreviewContainer {
        let view = CameraPreviewContainer()
        view.backgroundColor = .black
        view.previewLayer = controller.previewLayer
        controller.previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(controller.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewContainer, context: Context) {
        uiView.setNeedsLayout()
    }
}

// MARK: - Main Photogrammetry View

struct PhotogrammetryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var meshManager = MeshManager()

    @State private var preset: PhotogrammetryPreset = .standard
    @State private var phase: Phase
    @State private var processingProgress: Double = 0
    @State private var outputURL: URL?
    @State private var errorMessage: String?
    @State private var showShareSheet = false
    @State private var lastThumbnail: UIImage?
    @State private var preloadedPhotoDir: URL?  // non-nil when launched from LiDAR scan
    /// Mirrors autoCapture.photoCount — updated via onReceive so SwiftUI sees it
    @State private var captureCount: Int = 0
    /// Briefly true when a new photo is captured — drives the flash overlay
    @State private var showFlash: Bool = false
    /// Upload-to-labeler state
    @State private var isUploadingToLabeler = false
    @State private var labelerSessionId: String?
    @State private var labelerUploadError: String?
    /// Scan mode chosen by the user before capture starts
    @State private var captureMode: CaptureMode? = nil
    /// True once the user has tapped Start and capture is actively running
    @State private var isCapturing = false

    enum Phase { case capturing, processing, done, failed }
    enum CaptureMode { case cube, free, photoOnly }

    /// Standard init — launches with ARKit scanning + auto-capture.
    init() {
        _phase = State(initialValue: .capturing)
    }

    /// Pre-loaded init — skips capture and jumps straight to processing.
    /// Used when photos were auto-captured during a LiDAR scan.
    init(preloadedDir: URL) {
        _phase = State(initialValue: .processing)
        _preloadedPhotoDir = State(initialValue: preloadedDir)
    }

    // MARK: - Helpers

    var capturedCount: Int {
        if let dir = preloadedPhotoDir {
            return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { ["jpg","heic","png"].contains($0.pathExtension.lowercased()) }.count ?? 0
        }
        return captureCount  // updated via onReceive — guaranteed to trigger re-render
    }

    var inputPhotoDir: URL {
        preloadedPhotoDir ?? meshManager.autoCapture.photoDir
    }

    var effectiveTarget: Int? { preset.targetCount }

    var qualityInfo: (label: String, color: Color) {
        switch capturedCount {
        case 0..<5:   return ("Need at least 5 photos", .red)
        case 5..<15:  return ("Basic shape", .orange)
        case 15..<30: return ("Good quality", .yellow)
        case 30..<50: return ("Detailed", .green)
        default:      return ("Maximum detail", .cyan)
        }
    }

    var progressToTarget: Double {
        guard let target = effectiveTarget, target > 0 else { return 1 }
        return min(Double(capturedCount) / Double(target), 1)
    }

    var canProcess: Bool { capturedCount >= preset.minToProcess }

    // MARK: - Body

    var body: some View {
        ZStack {
            // AR View — camera feed + 3D scan-volume cube visualization
            // autoStartScanning: starts scanning immediately after setup (no delay, no reset)
            if phase == .capturing {
                ARViewContainer(meshManager: meshManager, autoStartScanning: true)
                    .edgesIgnoringSafeArea(.all)
            } else {
                Color.black.edgesIgnoringSafeArea(.all)
            }

            // Main UI
            VStack(spacing: 0) {
                topBar

                // Volume size slider (shown below top bar when cube is active)
                if meshManager.scanVolume != nil && phase == .capturing {
                    volumeSlider
                        .padding(.horizontal)
                        .transition(.opacity)
                }

                Spacer()
                bottomPanel
            }

            // Mode selection — shown until user picks cube or free
            if captureMode == nil && phase == .capturing {
                modeSelectionOverlay
            }

            // Photo capture flash — brief white flicker so user knows a photo was taken
            if showFlash {
                Color.white.opacity(0.35)
                    .edgesIgnoringSafeArea(.all)
                    .allowsHitTesting(false)
            }

            // Processing overlay
            if phase == .processing { processingOverlay }
            // Done overlay
            if phase == .done { doneOverlay }
            // Error overlay
            if phase == .failed, let msg = errorMessage { errorOverlay(msg) }
        }
        .task {
            guard phase == .capturing else {
                startProcessing()
                return
            }
            // ARKit starts tracking immediately (needed for cube raycast).
            // Photo capture stays off until the user taps Start.
            await Task.yield()
            meshManager.setMode(.largeObjects)
            meshManager.autoCapture.reset()
        }
        .onReceive(meshManager.autoCapture.$photoCount) { count in
            captureCount = count
            // Update thumbnail whenever a new photo is saved
            if let url = meshManager.autoCapture.photoURLs().last,
               let image = UIImage(contentsOfFile: url.path) {
                lastThumbnail = image
            }
            // Flash feedback — briefly white so user sees each capture
            if count > 0 {
                showFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { showFlash = false }
            }
        }
        .onDisappear {
            meshManager.autoCapture.isEnabled = false
            isCapturing = false
            if meshManager.isScanning { _ = meshManager.stopScanning() }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = outputURL { PhotogrammetryShareSheet(url: url) }
        }
    }

    // MARK: - Top bar

    var topBar: some View {
        HStack(alignment: .top) {
            // Dismiss
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.title3).foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }

            // Cube reposition button — only shown in cube mode
            if phase == .capturing && captureMode == .cube {
                Button(action: {
                    if meshManager.scanVolume != nil {
                        meshManager.clearScanVolume()
                        meshManager.placeScanVolume()
                    }
                }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "cube.fill")
                            .font(.title3)
                            .foregroundColor(.yellow)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Circle())
                        if let v = meshManager.scanVolume {
                            Text("\(Int(v.halfExtent * 200))cm")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.yellow).clipShape(Capsule())
                                .offset(x: 4, y: -4)
                        }
                    }
                }
            }

            Spacer()

            // Info panel
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill").foregroundColor(.white)
                    Text("\(capturedCount) photos").fontWeight(.semibold).foregroundColor(.white)
                    Text("/ \(meshManager.autoCapture.depthCount)d")
                        .font(.caption).foregroundColor(meshManager.autoCapture.depthCount > 0 ? .cyan : .orange)
                }

                Text(qualityInfo.label).font(.caption).foregroundColor(qualityInfo.color)

                if effectiveTarget != nil {
                    ProgressView(value: progressToTarget)
                        .progressViewStyle(LinearProgressViewStyle(tint: qualityInfo.color))
                        .frame(width: 120)
                }


                if phase == .capturing && isCapturing {
                    Text(captureMode == .cube    ? "Cube active — walk around object" :
                         captureMode == .free    ? "Free — walk around object" :
                                                   "Photo only — walk around object")
                        .font(.caption2).foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.black.opacity(0.55)).cornerRadius(14)
        }
        .padding()
    }

    // MARK: - Volume size slider

    var volumeSlider: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube").font(.caption).foregroundColor(.yellow)
            Slider(
                value: Binding(
                    get: { Double(meshManager.scanVolumeHalfExtent) },
                    set: { meshManager.updateScanVolumeSize(Float($0)) }
                ),
                in: 0.1...1.5, step: 0.05
            )
            .tint(.yellow).frame(width: 130)
            Text("\(Int(meshManager.scanVolumeHalfExtent * 200)) cm")
                .font(.caption2).foregroundColor(.yellow).frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.black.opacity(0.6)).cornerRadius(12)
    }

    // MARK: - Bottom panel

    var bottomPanel: some View {
        VStack(spacing: 12) {
            if captureMode != nil && !isCapturing {
                // ── Mode selected, not yet capturing — show Start ──────────────
                Picker("Quality", selection: $preset) {
                    ForEach(PhotogrammetryPreset.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented).padding(.horizontal)
                .background(Color.black.opacity(0.01)).colorScheme(.dark)

                if captureMode == .cube {
                    Text("Aim at your object, then tap Start")
                        .font(.caption).foregroundColor(.yellow.opacity(0.9))
                } else {
                    Text("Point at your object, then tap Start")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }

                Button(action: startCapture) {
                    Label("Start Capture", systemImage: "record.circle.fill")
                        .font(.headline).foregroundColor(.white)
                        .padding(.horizontal, 44).padding(.vertical, 16)
                        .background(Color.green).cornerRadius(16)
                }

            } else if isCapturing {
                // ── Actively capturing ────────────────────────────────────────
                Picker("Quality", selection: $preset) {
                    ForEach(PhotogrammetryPreset.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented).padding(.horizontal)
                .background(Color.black.opacity(0.01)).colorScheme(.dark)

                if let target = effectiveTarget {
                    Text("Target: \(target) photos  •  min \(preset.minToProcess) to start")
                        .font(.caption2).foregroundColor(.white.opacity(0.7))
                } else {
                    Text("Free — min \(preset.minToProcess) photos to build")
                        .font(.caption2).foregroundColor(.white.opacity(0.7))
                }

                HStack(spacing: 24) {
                    // Thumbnail
                    Group {
                        if let thumb = lastThumbnail {
                            Image(uiImage: thumb)
                                .resizable().scaledToFill()
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.1)).frame(width: 52, height: 52)
                        }
                    }

                    // Shutter — manual capture
                    Button(action: capturePhoto) {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 72, height: 72)
                            Circle().stroke(Color.white.opacity(0.4), lineWidth: 3)
                                .frame(width: 84, height: 84)
                        }
                    }

                    // Stop & Upload
                    Button(action: stopAndUpload) {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .fill(capturedCount > 0 ? Color.orange : Color.white.opacity(0.2))
                                    .frame(width: 52, height: 52)
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(capturedCount > 0 ? .white : .white.opacity(0.4))
                            }
                            Text("Stop & Send")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(capturedCount > 0 ? .orange : .white.opacity(0.5))
                        }
                    }
                    .disabled(capturedCount == 0)
                }
            }
        }
        .padding(.bottom, 50).padding(.top, 12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                   startPoint: .top, endPoint: .bottom))
    }

    // MARK: - Mode selection overlay

    var modeSelectionOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button(action: { selectMode(.cube) }) {
                    VStack(spacing: 5) {
                        Image(systemName: "cube")
                            .font(.title3).foregroundColor(.yellow)
                        Text("Object Scan")
                            .font(.caption2).foregroundColor(.white)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.yellow.opacity(0.7), lineWidth: 1.5))
                }
                .buttonStyle(.plain)

                Button(action: { selectMode(.free) }) {
                    VStack(spacing: 5) {
                        Image(systemName: "camera")
                            .font(.title3).foregroundColor(.white)
                        Text("Free Capture")
                            .font(.caption2).foregroundColor(.white)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                }
                .buttonStyle(.plain)

                Button(action: { selectMode(.photoOnly) }) {
                    VStack(spacing: 5) {
                        Image(systemName: "photo.stack")
                            .font(.title3).foregroundColor(.cyan)
                        Text("Photo Only")
                            .font(.caption2).foregroundColor(.white)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.cyan.opacity(0.7), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 140)
        }
    }

    // MARK: - Processing overlay

    var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).edgesIgnoringSafeArea(.all)
            VStack(spacing: 24) {
                Image(systemName: "cube.transparent").font(.system(size: 60)).foregroundColor(.cyan)
                Text("Building 3D model…").font(.title3).fontWeight(.semibold).foregroundColor(.white)
                VStack(spacing: 8) {
                    ProgressView(value: processingProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .cyan)).frame(width: 260)
                    Text("\(Int(processingProgress * 100))%  •  \(capturedCount) photos")
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
                Text("Keep the app open").font(.caption2).foregroundColor(.white.opacity(0.4))
            }
            .padding(40)
        }
    }

    // MARK: - Done overlay

    var doneOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).edgesIgnoringSafeArea(.all)
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundColor(.green)
                Text("3D Model Ready").font(.title2).fontWeight(.bold).foregroundColor(.white)
                Text("USDZ file — open in AR Quick Look,\nBlender, or any 3D viewer")
                    .font(.caption).multilineTextAlignment(.center).foregroundColor(.white.opacity(0.7))

                HStack(spacing: 16) {
                    Button(action: { showShareSheet = true }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline).foregroundColor(.white)
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .background(Color.blue).cornerRadius(14)
                    }

                    // ── Send to Point Cloud Labeler ──────────────────────────
                    Button(action: sendToLabeler) {
                        Label(isUploadingToLabeler ? "Uploading…" : "Send to Labeler",
                              systemImage: "square.and.arrow.up.on.square")
                            .font(.headline).foregroundColor(.white)
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .background(labelerSessionId != nil ? Color.green : Color.orange)
                            .cornerRadius(14)
                    }
                    .disabled(isUploadingToLabeler)

                    Button(action: { dismiss() }) {
                        Text("Done").font(.headline).foregroundColor(.white)
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .background(Color.gray.opacity(0.4)).cornerRadius(14)
                    }
                }

                // Upload status feedback
                if isUploadingToLabeler {
                    ProgressView("Uploading \(meshManager.autoCapture.photoCount) photos…")
                        .foregroundColor(.white).tint(.white)
                } else if let sid = labelerSessionId {
                    Text("Photos uploaded — labeler will auto-open")
                        .font(.caption).foregroundColor(.green)
                        .multilineTextAlignment(.center)
                    Text(sid).font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                } else if let err = labelerUploadError {
                    Text("Upload failed: \(err)")
                        .font(.caption).foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(40)
        }
    }

    // MARK: - Error overlay

    func errorOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.85).edgesIgnoringSafeArea(.all)
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50)).foregroundColor(.red)
                Text("Processing Failed").font(.title3).fontWeight(.bold).foregroundColor(.white)
                Text(message).font(.caption).foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    phase = .capturing
                    lastThumbnail = nil
                    meshManager.autoCapture.reset()
                    meshManager.autoCapture.isEnabled = true
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28).padding(.vertical, 14)
                .background(Color.orange).cornerRadius(14)
            }
            .padding(40)
        }
    }

    // MARK: - Actions

    func selectMode(_ mode: CaptureMode) {
        captureMode = mode
        switch mode {
        case .cube:
            meshManager.placeScanVolume()
        case .photoOnly:
            // No LiDAR mesh needed — stop scanning to save battery
            if meshManager.isScanning { _ = meshManager.stopScanning() }
            meshManager.startDepthSession()  // ensure .sceneDepth is enabled for depth maps
        case .free:
            break
        }
    }

    func startCapture() {
        isCapturing = true
        meshManager.autoCapture.isEnabled = true
    }

    /// Manual shutter — force-captures the current ARFrame.
    func capturePhoto() {
        meshManager.capturePhotoNow()
        // thumbnail + analysis handled by onReceive($photoCount)
    }

    func stopAndUpload() {
        meshManager.autoCapture.isEnabled = false
        isCapturing = false
        if meshManager.isScanning { _ = meshManager.stopScanning() }
        phase = .done
        sendToLabeler()
    }

    func sendToLabeler() {
        isUploadingToLabeler = true
        labelerSessionId     = nil
        labelerUploadError   = nil
        let dir        = meshManager.autoCapture.photoDir
        let poses      = meshManager.autoCapture.posesJSON()
        // Photo-only mode has no LiDAR mesh — skip point cloud
        let pointCloud = (captureMode == .photoOnly) ? nil : meshManager.pointCloudJSON()
        let depths     = meshManager.autoCapture.depthMaps
        Task {
            let sid = await ScanServerManager.shared.uploadPhotos(
                from: dir, posesData: poses, pointCloudData: pointCloud, depthMaps: depths)
            await MainActor.run {
                isUploadingToLabeler = false
                if let sid {
                    labelerSessionId = sid
                } else {
                    labelerUploadError = ScanServerManager.shared.lastError ?? "Unknown error"
                }
            }
        }
    }

    func startProcessing() {
        guard canProcess || preloadedPhotoDir != nil else { return }
        meshManager.autoCapture.isEnabled = false
        isCapturing = false
        if meshManager.isScanning { _ = meshManager.stopScanning() }
        phase = .processing
        processingProgress = 0

        Task {
            do {
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("scan_\(Int(Date().timeIntervalSince1970)).usdz")
                try await runPhotogrammetry(inputDir: inputPhotoDir, outputURL: output)
                await MainActor.run { outputURL = output; phase = .done }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; phase = .failed }
            }
        }
    }

    func runPhotogrammetry(inputDir: URL, outputURL: URL) async throws {
        guard #available(iOS 17.0, *) else {
            throw NSError(domain: "Photogrammetry", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Requires iOS 17 or later"])
        }
        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering    = .unordered
        config.featureSensitivity = .high
        let session = try PhotogrammetrySession(input: inputDir, configuration: config)
        try session.process(requests: [.modelFile(url: outputURL)])
        for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                await MainActor.run { processingProgress = fraction }
            case .requestComplete:
                return
            case .requestError(_, let error):
                throw error
            case .processingCancelled:
                throw CancellationError()
            default:
                break
            }
        }
    }
}

// MARK: - Share Sheet (photogrammetry-specific, avoids conflict with ExportView.ShareSheet)

struct PhotogrammetryShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
