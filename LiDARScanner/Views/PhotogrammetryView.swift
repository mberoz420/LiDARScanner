import SwiftUI
import AVFoundation
import RealityKit

// MARK: - Quality Preset

enum PhotogrammetryPreset: String, CaseIterable, Identifiable {
    case quick    = "Quick"
    case standard = "Standard"
    case detailed = "Detailed"
    case free     = "Free"

    var id: String { rawValue }

    var targetCount: Int? {
        switch self {
        case .quick:    return 8
        case .standard: return 20
        case .detailed: return 40
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

@MainActor
class PhotogrammetryController: NSObject, ObservableObject {
    @Published var capturedCount = 0
    @Published var isRunning = false
    @Published var lastThumbnail: UIImage?

    private let captureSession = AVCaptureSession()
    private let photoOutput    = AVCapturePhotoOutput()
    let previewLayer           = AVCaptureVideoPreviewLayer()
    let tempDir: URL

    private var captureCallback: ((URL) -> Void)?

    override init() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photogrammetry_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        super.init()
        setupSession()
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
            // Enable depth delivery on devices that support it (LiDAR / dual camera)
            photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
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
        guard error == nil, let data = photo.fileDataRepresentation() else { return }

        Task { @MainActor in
            let filename = String(format: "%04d.heic", self.capturedCount)
            let url = self.tempDir.appendingPathComponent(filename)
            try? data.write(to: url)

            // Thumbnail for UI
            if let image = UIImage(data: data) {
                self.lastThumbnail = image
            }

            self.capturedCount += 1
            self.captureCallback?(url)
            self.captureCallback = nil
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

struct CameraPreviewView: UIViewRepresentable {
    let controller: PhotogrammetryController

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        controller.previewLayer.frame = view.bounds
        controller.previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(controller.previewLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.previewLayer.frame = uiView.bounds
    }
}

// MARK: - Main Photogrammetry View

struct PhotogrammetryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = PhotogrammetryController()

    @State private var preset: PhotogrammetryPreset = .standard
    @State private var phase: Phase = .capturing
    @State private var processingProgress: Double = 0
    @State private var outputURL: URL?
    @State private var errorMessage: String?
    @State private var showShareSheet = false
    @State private var capturedURLs: [URL] = []

    enum Phase { case capturing, processing, done, failed }

    // MARK: Quality info

    var qualityInfo: (label: String, color: Color) {
        let n = capturedURLs.count
        switch n {
        case 0..<5:   return ("Need at least 5 photos", .red)
        case 5..<10:  return ("Basic shape", .orange)
        case 10..<20: return ("Good quality", .yellow)
        case 20..<40: return ("Detailed", .green)
        default:      return ("Maximum detail", .cyan)
        }
    }

    var targetCount: Int { preset.targetCount ?? capturedURLs.count }

    var progressToTarget: Double {
        guard let target = preset.targetCount, target > 0 else { return 1 }
        return min(Double(capturedURLs.count) / Double(target), 1)
    }

    var canProcess: Bool { capturedURLs.count >= preset.minToProcess }

    // MARK: Body

    var body: some View {
        ZStack {
            // Camera feed
            CameraPreviewView(controller: camera)
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
        .onAppear { camera.start() }
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

                // Progress toward target (hidden in Free mode)
                if preset.targetCount != nil {
                    ProgressView(value: progressToTarget)
                        .progressViewStyle(LinearProgressViewStyle(tint: qualityInfo.color))
                        .frame(width: 120)
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
            if let target = preset.targetCount {
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

        let detail: PhotogrammetrySession.Request.Detail = {
            switch preset {
            case .quick:    return .reduced
            case .standard: return .reduced
            case .detailed: return .full
            case .free:     return .full
            }
        }()

        try session.process(requests: [.modelFile(url: outputURL, detail: detail)])

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
