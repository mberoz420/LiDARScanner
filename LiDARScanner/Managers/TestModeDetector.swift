import Foundation
import simd
import ARKit
import UIKit
import Speech
import AVFoundation

/// Test Mode: Detect ceiling plane and wall-ceiling intersections with voice control
class TestModeDetector: ObservableObject {

    // MARK: - Published State
    @Published var ceilingPlane: DetectedPlane?
    @Published var wallPlanes: [DetectedPlane] = []
    @Published var detectedEdges: [BoundaryEdge] = []
    @Published var isPaused: Bool = false
    @Published var isListening: Bool = false
    @Published var isReceivingAudio: Bool = false
    @Published var statusMessage: String = "Point at ceiling"

    // MARK: - Data Structures

    struct DetectedPlane: Identifiable {
        let id: UUID
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let extent: SIMD2<Float>
        let classification: PlaneType

        enum PlaneType {
            case ceiling
            case wall
        }
    }

    struct BoundaryEdge: Identifiable {
        let id = UUID()
        let startPoint: SIMD3<Float>
        let endPoint: SIMD3<Float>
    }

    // MARK: - Configuration

    private let ceilingProximityThreshold: Float = 0.20
    private let ceilingNormalThreshold: Float = 0.8
    private let wallNormalThreshold: Float = 0.3

    // MARK: - Voice Recognition

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var permissionGranted: Bool = false

    // MARK: - Init

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Voice Control

    func startListening() {
        // Request permissions first
        requestPermissions { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async {
                    self?.statusMessage = "Voice commands disabled"
                    self?.isListening = false
                }
                return
            }

            DispatchQueue.main.async {
                self?.permissionGranted = true
                self?.startAudioEngine()
            }
        }
    }

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        // First request microphone permission
        AVAudioApplication.requestRecordPermission { [weak self] micGranted in
            guard micGranted else {
                completion(false)
                return
            }

            // Then request speech recognition permission
            SFSpeechRecognizer.requestAuthorization { status in
                let granted = (status == .authorized)
                completion(granted)
            }
        }
    }

    private func startAudioEngine() {
        // Stop any existing engine
        stopAudioEngine()

        guard permissionGranted else {
            statusMessage = "Voice not authorized"
            return
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            statusMessage = "Speech not available"
            return
        }

        do {
            // Setup audio session
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // Create audio engine
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }

            // Create recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true

            // Get input node and format
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // Verify format is valid
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                statusMessage = "Invalid audio format"
                return
            }

            // Install tap
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                self?.checkAudioLevel(buffer: buffer)
            }

            // Start engine
            audioEngine.prepare()
            try audioEngine.start()

            isListening = true
            updateStatus()

            // Start recognition
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                if let result = result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    DispatchQueue.main.async {
                        self?.processVoiceCommand(text)
                    }
                }

                if error != nil || (result?.isFinal ?? false) {
                    // Restart recognition after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self, self.isListening else { return }
                        self.startAudioEngine()
                    }
                }
            }

        } catch {
            statusMessage = "Audio error"
            isListening = false
        }
    }

    private func checkAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += abs(channelData[i])
        }
        let average = sum / Float(frameLength)

        DispatchQueue.main.async { [weak self] in
            self?.isReceivingAudio = average > 0.01
        }
    }

    private func processVoiceCommand(_ text: String) {
        let words = text.lowercased().components(separatedBy: " ")
        guard let lastWord = words.last else { return }

        if lastWord.contains("pause") || lastWord.contains("stop") || lastWord.contains("wait") {
            if !isPaused {
                isPaused = true
                hapticFeedback()
                updateStatus()
            }
        } else if lastWord.contains("go") || lastWord.contains("continue") || lastWord.contains("start") || lastWord.contains("resume") {
            if isPaused {
                isPaused = false
                hapticFeedback()
                updateStatus()
            }
        }
    }

    private func stopAudioEngine() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
    }

    func stopListening() {
        stopAudioEngine()
        isListening = false
        isReceivingAudio = false
    }

    func togglePause() {
        isPaused.toggle()
        updateStatus()
        hapticFeedback()
    }

    private func hapticFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func updateStatus() {
        if isPaused {
            statusMessage = "PAUSED - Say 'Go'"
        } else if ceilingPlane == nil {
            statusMessage = "Point at ceiling"
        } else if wallPlanes.isEmpty {
            statusMessage = "Now scan wall edges"
        } else {
            statusMessage = "\(wallPlanes.count) walls, \(detectedEdges.count) edges"
        }
    }

    // MARK: - Frame Processing

    func processFrame(_ frame: ARFrame) {
        guard !isPaused else { return }

        for anchor in frame.anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                processPlaneAnchor(planeAnchor)
            }
        }

        if ceilingPlane != nil {
            findWallCeilingIntersections()
        }

        updateStatus()
    }

    private func processPlaneAnchor(_ anchor: ARPlaneAnchor) {
        let transform = anchor.transform
        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let normal = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let extent = SIMD2<Float>(anchor.planeExtent.width, anchor.planeExtent.height)

        // Detect ceiling (normal pointing down)
        if anchor.classification == .ceiling || normal.y < -ceilingNormalThreshold {
            let plane = DetectedPlane(
                id: anchor.identifier,
                center: center,
                normal: normal,
                extent: extent,
                classification: .ceiling
            )
            if ceilingPlane == nil {
                hapticFeedback()
            }
            ceilingPlane = plane
        }
        // Detect walls near ceiling
        else if anchor.classification == .wall || abs(normal.y) < wallNormalThreshold {
            if let ceiling = ceilingPlane {
                let distanceToCeiling = abs(center.y - ceiling.center.y)

                if distanceToCeiling <= ceilingProximityThreshold {
                    let plane = DetectedPlane(
                        id: anchor.identifier,
                        center: center,
                        normal: normal,
                        extent: extent,
                        classification: .wall
                    )

                    if let index = wallPlanes.firstIndex(where: { $0.id == plane.id }) {
                        wallPlanes[index] = plane
                    } else {
                        wallPlanes.append(plane)
                        hapticFeedback()
                    }
                }
            }
        }
    }

    private func findWallCeilingIntersections() {
        guard let ceiling = ceilingPlane else { return }

        var newEdges: [BoundaryEdge] = []

        for wall in wallPlanes {
            if let edge = calculateIntersection(wall: wall, ceiling: ceiling) {
                newEdges.append(edge)
            }
        }

        detectedEdges = newEdges
    }

    private func calculateIntersection(wall: DetectedPlane, ceiling: DetectedPlane) -> BoundaryEdge? {
        let lineDirection = simd_cross(wall.normal, ceiling.normal)
        let lengthSq = simd_length_squared(lineDirection)

        guard lengthSq > 0.0001 else { return nil }

        let normalizedDir = simd_normalize(lineDirection)

        let d1 = -simd_dot(wall.normal, wall.center)
        let d2 = -simd_dot(ceiling.normal, ceiling.center)

        let n1 = wall.normal
        let n2 = ceiling.normal

        let n1n2 = simd_dot(n1, n2)
        let n1n1 = simd_dot(n1, n1)
        let n2n2 = simd_dot(n2, n2)

        let det = n1n1 * n2n2 - n1n2 * n1n2
        guard abs(det) > 0.0001 else { return nil }

        let c1 = (d2 * n1n2 - d1 * n2n2) / det
        let c2 = (d1 * n1n2 - d2 * n1n1) / det

        let point = c1 * n1 + c2 * n2

        let halfLength = max(wall.extent.x, wall.extent.y) / 2.0
        let start = point - normalizedDir * halfLength
        let end = point + normalizedDir * halfLength

        return BoundaryEdge(startPoint: start, endPoint: end)
    }

    // MARK: - Reset

    func reset() {
        stopListening()
        ceilingPlane = nil
        wallPlanes = []
        detectedEdges = []
        isPaused = false
        statusMessage = "Point at ceiling"
    }
}
