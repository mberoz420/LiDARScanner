import SwiftUI
import AVFoundation
import RealityKit
import Vision
import CoreImage
import CoreMedia

// MARK: - Geometry Analyzer

/// Analyzes captured photos to estimate geometric complexity of the object.
/// Uses Vision contour + rectangle detection — no custom ML model needed.
@MainActor
class GeometryAnalyzer: ObservableObject {

    enum ShapeClass {
        case unknown
        case geometric(confidence: Double)   // box, cylinder, prism — few photos needed
        case mixed(confidence: Double)       // partially regular
        case organic(confidence: Double)     // freeform — many photos needed

        var label: String {
            switch self {
            case .unknown:               return "Analyzing…"
            case .geometric(let c):      return "Geometric shape (\(Int(c*100))% confidence)"
            case .mixed(let c):          return "Mixed shape (\(Int(c*100))% confidence)"
            case .organic(let c):        return "Organic/complex (\(Int(c*100))% confidence)"
            }
        }

        var color: Color {
            switch self {
            case .unknown:    return .white
            case .geometric:  return .cyan
            case .mixed:      return .yellow
            case .organic:    return .orange
            }
        }

        /// Recommended photo target based on shape class
        var recommendedTarget: Int {
            switch self {
            case .unknown:          return 20
            case .geometric:        return 8
            case .mixed:            return 15
            case .organic:          return 28
            }
        }
    }

    @Published var shapeClass: ShapeClass = .unknown
    @Published var isAnalyzing = false

    private var analysisScores: [Double] = []

    /// Analyze a newly captured photo. Runs Vision off main thread, publishes result on main.
    func analyze(imageURL: URL) {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            guard let image = UIImage(contentsOfFile: imageURL.path),
                  let cgImage = image.cgImage else { return }

            await MainActor.run { self.isAnalyzing = true }

            let score = await Self.geometricScore(for: cgImage)

            await MainActor.run {
                self.isAnalyzing = false
                self.analysisScores.append(score)

                // Use median of last 5 scores for stability
                let recent = self.analysisScores.suffix(5).sorted()
                let median = recent[recent.count / 2]

                if self.analysisScores.count < 3 {
                    self.shapeClass = .unknown
                } else if median >= 0.65 {
                    self.shapeClass = .geometric(confidence: median)
                } else if median >= 0.35 {
                    self.shapeClass = .mixed(confidence: median)
                } else {
                    self.shapeClass = .organic(confidence: 1 - median)
                }
            }
        }
    }

    func reset() {
        analysisScores = []
        shapeClass = .unknown
    }

    /// Returns a score 0→1 where 1 = very geometric, 0 = very organic.
    /// Combines rectangle detection density and contour straightness.
    private static func geometricScore(for cgImage: CGImage) async -> Double {
        async let rectScore   = rectangleScore(cgImage)
        async let contourScore = contourStraightnessScore(cgImage)
        let (r, c) = await (rectScore, contourScore)
        return (r * 0.4 + c * 0.6)
    }

    /// Score based on how many strong rectangles Vision detects.
    private static func rectangleScore(_ cgImage: CGImage) async -> Double {
        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { req, _ in
                let results = req.results as? [VNRectangleObservation] ?? []
                // Normalize: 3+ strong rectangles = fully geometric
                let score = min(Double(results.count) / 3.0, 1.0)
                continuation.resume(returning: score)
            }
            request.minimumConfidence   = 0.5
            request.minimumAspectRatio  = 0.2
            request.maximumObservations = 10

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    /// Score based on straightness of detected contours.
    /// Straight, long contours → geometric. Many short curved ones → organic.
    private static func contourStraightnessScore(_ cgImage: CGImage) async -> Double {
        return await withCheckedContinuation { continuation in
            let request = VNDetectContoursRequest { req, _ in
                guard let result = req.results?.first as? VNContoursObservation else {
                    continuation.resume(returning: 0.5)
                    return
                }

                var totalPoints   = 0
                var straightPoints = 0

                for i in 0..<result.contourCount {
                    guard let contour = try? result.contour(at: i) else { continue }
                    let pts = contour.normalizedPoints
                    totalPoints += pts.count

                    // Measure straightness: compare actual path length vs chord length
                    guard pts.count >= 3 else { continue }
                    var pathLen: Float = 0
                    for j in 1..<pts.count {
                        let dx = pts[j].x - pts[j-1].x
                        let dy = pts[j].y - pts[j-1].y
                        pathLen += sqrt(dx*dx + dy*dy)
                    }
                    let dx = pts.last!.x - pts.first!.x
                    let dy = pts.last!.y - pts.first!.y
                    let chord = sqrt(dx*dx + dy*dy)
                    if pathLen > 0 {
                        let straightness = Double(chord / pathLen)   // 1.0 = perfectly straight
                        straightPoints += Int(Double(pts.count) * straightness)
                    }
                }

                let score = totalPoints > 0 ? Double(straightPoints) / Double(totalPoints) : 0.5
                continuation.resume(returning: score)
            }
            request.contrastAdjustment = 1.0
            request.detectsDarkOnLight  = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
}

// MARK: - Quality Preset

enum PhotogrammetryPreset: String, CaseIterable, Identifiable {
    case auto     = "Auto"
    case quick    = "Quick"
    case detailed = "Detailed"
    case free     = "Free"

    var id: String { rawValue }

    var targetCount: Int? {
        switch self {
        case .auto:     return nil   // set dynamically by GeometryAnalyzer
        case .quick:    return 8
        case .detailed: return 40
        case .free:     return nil
        }
    }

    var minToProcess: Int {
        switch self {
        case .auto:     return 5
        case .quick:    return 5
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
    @StateObject private var camera:   PhotogrammetryController
    @StateObject private var analyzer  = GeometryAnalyzer()

    @State private var preset: PhotogrammetryPreset = .auto
    @State private var phase: Phase
    @State private var processingProgress: Double = 0
    @State private var outputURL: URL?
    @State private var errorMessage: String?
    @State private var showShareSheet = false
    @State private var capturedURLs: [URL]

    enum Phase { case capturing, processing, done, failed }

    /// Standard init — launches with empty capture session.
    init() {
        _camera = StateObject(wrappedValue: PhotogrammetryController())
        _capturedURLs = State(initialValue: [])
        _phase = State(initialValue: .capturing)
    }

    /// Pre-loaded init — skips capture and jumps straight to processing.
    /// Used when photos were auto-captured during a LiDAR scan.
    init(preloadedDir: URL) {
        let ctrl = PhotogrammetryController(existingDir: preloadedDir)
        _camera = StateObject(wrappedValue: ctrl)
        // Pre-populate capturedURLs from the existing directory
        let urls = (try? FileManager.default.contentsOfDirectory(at: preloadedDir, includingPropertiesForKeys: nil))
            .map { $0.filter { ["jpg","heic","png"].contains($0.pathExtension.lowercased()) }
                     .sorted { $0.lastPathComponent < $1.lastPathComponent } }
            ?? []
        _capturedURLs = State(initialValue: urls)
        _phase = State(initialValue: .processing)  // jump straight to processing
    }

    // MARK: Computed properties

    /// Effective target: Auto uses analyzer recommendation, others use fixed value
    var effectiveTarget: Int? {
        if preset == .auto {
            return capturedURLs.count >= 3 ? analyzer.shapeClass.recommendedTarget : nil
        }
        return preset.targetCount
    }

    var qualityInfo: (label: String, color: Color) {
        if preset == .auto && capturedURLs.count >= 3 {
            return (analyzer.shapeClass.label, analyzer.shapeClass.color)
        }
        switch capturedURLs.count {
        case 0..<5:   return ("Need at least 5 photos", .red)
        case 5..<10:  return ("Basic shape", .orange)
        case 10..<20: return ("Good quality", .yellow)
        case 20..<40: return ("Detailed", .green)
        default:      return ("Maximum detail", .cyan)
        }
    }

    var progressToTarget: Double {
        guard let target = effectiveTarget, target > 0 else { return 1 }
        return min(Double(capturedURLs.count) / Double(target), 1)
    }

    var canProcess: Bool { capturedURLs.count >= preset.minToProcess }

    // MARK: Body

    var body: some View {
        ZStack {
            // Camera feed — tap to set depth mask target
            GeometryReader { geo in
                CameraPreviewView(controller: camera)
                    .edgesIgnoringSafeArea(.all)
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                let norm = CGPoint(
                                    x: value.location.x / geo.size.width,
                                    y: value.location.y / geo.size.height
                                )
                                if let depth = camera.sampleDepth(at: norm) {
                                    camera.targetDepth = depth
                                }
                            }
                    )
            }
            .edgesIgnoringSafeArea(.all)

            // Main UI
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }

            // Processing overlay
            if phase == .processing {
                processingOverlay
            }

            // Done overlay
            if phase == .done {
                doneOverlay
            }

            // Error overlay
            if phase == .failed, let msg = errorMessage {
                errorOverlay(msg)
            }
        }
        .onAppear {
            if phase == .processing {
                // Pre-loaded mode: skip camera, go straight to processing
                startProcessing()
            } else {
                camera.start()
            }
        }
        .onDisappear {
            camera.stop()
            if phase != .done { camera.cleanup() }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = outputURL {
                PhotogrammetryShareSheet(url: url)
            }
        }
    }

    // MARK: Top bar

    var topBar: some View {
        HStack(alignment: .top) {
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                // Photo counter
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .foregroundColor(.white)
                    Text("\(capturedURLs.count) photos")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }

                // Quality label
                Text(qualityInfo.label)
                    .font(.caption)
                    .foregroundColor(qualityInfo.color)

                // Progress toward target
                if effectiveTarget != nil {
                    ProgressView(value: progressToTarget)
                        .progressViewStyle(LinearProgressViewStyle(tint: qualityInfo.color))
                        .frame(width: 120)
                }

                // Auto mode: analyzing indicator
                if preset == .auto && analyzer.isAnalyzing {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.6).tint(.white)
                        Text("Analyzing…").font(.caption2).foregroundColor(.white.opacity(0.7))
                    }
                }

                // Depth mask controls
                if let depth = camera.targetDepth {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "scope").font(.caption).foregroundColor(.green)
                            Text(String(format: "%.2fm ±%.2fm", depth, camera.depthBuffer))
                                .font(.caption).foregroundColor(.green)
                            Button(action: { camera.targetDepth = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption).foregroundColor(.green.opacity(0.7))
                            }
                        }
                        Slider(value: Binding(
                            get: { Double(camera.depthBuffer) },
                            set: { camera.depthBuffer = Float($0) }
                        ), in: 0.05...1.0, step: 0.05)
                        .tint(.green)
                        .frame(width: 120)
                    }
                } else if camera.latestDepthMap != nil {
                    Text("Tap object to set depth mask")
                        .font(.caption2).foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))
            .cornerRadius(14)
        }
        .padding()
    }

    // MARK: Bottom panel

    var bottomPanel: some View {
        VStack(spacing: 12) {
            // Preset picker
            Picker("Quality", selection: $preset) {
                ForEach(PhotogrammetryPreset.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .background(Color.black.opacity(0.01)) // force dark tint context
            .colorScheme(.dark)

            // Target hint
            if preset == .auto {
                if let target = effectiveTarget {
                    Text("AI target: \(target) photos  •  adjusts as you scan")
                        .font(.caption2)
                        .foregroundColor(analyzer.shapeClass.color.opacity(0.9))
                } else {
                    Text("Auto mode — take 3+ photos to detect shape")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
            } else if let target = effectiveTarget {
                Text("Target: \(target) photos  •  min \(preset.minToProcess) to start")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            } else {
                Text("Free mode — take as many as you like  •  min \(preset.minToProcess) to start")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }

            HStack(spacing: 50) {
                // Thumbnail of last capture
                Group {
                    if let thumb = camera.lastThumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 52, height: 52)
                    }
                }

                // Shutter button
                Button(action: capturePhoto) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 72, height: 72)
                        Circle()
                            .stroke(Color.white.opacity(0.4), lineWidth: 3)
                            .frame(width: 84, height: 84)
                    }
                }

                // Done button
                Button(action: startProcessing) {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 28))
                        Text("Process")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(canProcess ? .green : .gray)
                    .frame(width: 52)
                }
                .disabled(!canProcess)
            }
        }
        .padding(.bottom, 50)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: Processing overlay

    var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).edgesIgnoringSafeArea(.all)
            VStack(spacing: 24) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 60))
                    .foregroundColor(.cyan)

                Text("Building 3D model…")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                VStack(spacing: 8) {
                    ProgressView(value: processingProgress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .cyan))
                        .frame(width: 260)
                    Text("\(Int(processingProgress * 100))%  •  \(capturedURLs.count) photos")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }

                Text("Keep the app open")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(40)
        }
    }

    // MARK: Done overlay

    var doneOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).edgesIgnoringSafeArea(.all)
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                Text("3D Model Ready")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("USDZ file — open in AR Quick Look,\nBlender, or any 3D viewer")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.7))

                HStack(spacing: 20) {
                    Button(action: { showShareSheet = true }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(Color.blue)
                            .cornerRadius(14)
                    }

                    Button(action: { dismiss() }) {
                        Text("Done")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(Color.gray.opacity(0.4))
                            .cornerRadius(14)
                    }
                }
            }
            .padding(40)
        }
    }

    // MARK: Error overlay

    func errorOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.85).edgesIgnoringSafeArea(.all)
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.red)
                Text("Processing Failed")
                    .font(.title3).fontWeight(.bold).foregroundColor(.white)
                Text(message)
                    .font(.caption).foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    phase = .capturing
                    capturedURLs = []
                    camera.capturedCount = 0
                    camera.lastThumbnail = nil
                    analyzer.reset()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28).padding(.vertical, 14)
                .background(Color.orange).cornerRadius(14)
            }
            .padding(40)
        }
    }

    // MARK: Actions

    func capturePhoto() {
        camera.capturePhoto { url in
            capturedURLs.append(url)
            // Analyze every 3rd photo in Auto mode (avoid hammering Vision on every shot)
            if self.preset == .auto && self.capturedURLs.count % 3 == 0 {
                self.analyzer.analyze(imageURL: url)
            }
        }
    }

    func startProcessing() {
        guard canProcess else { return }
        camera.stop()
        phase = .processing
        processingProgress = 0

        Task {
            do {
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("scan_\(Int(Date().timeIntervalSince1970)).usdz")

                try await runPhotogrammetry(inputDir: camera.tempDir, outputURL: output)

                await MainActor.run {
                    outputURL = output
                    phase = .done
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .failed
                }
            }
        }
    }

    func runPhotogrammetry(inputDir: URL, outputURL: URL) async throws {
        guard #available(iOS 17.0, *) else {
            throw NSError(domain: "Photogrammetry",
                          code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Requires iOS 17 or later"])
        }

        var config = PhotogrammetrySession.Configuration()
        config.sampleOrdering   = .unordered
        config.featureSensitivity = .high

        let session = try PhotogrammetrySession(input: inputDir, configuration: config)

        // PhotogrammetrySession.Request.Detail is macOS-only.
        // On iOS 17 the request omits the detail parameter.
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
