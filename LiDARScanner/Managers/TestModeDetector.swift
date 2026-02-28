import Foundation
import simd
import ARKit
import Speech
import AVFoundation
import UIKit

/// Test Mode: Detect ceiling plane and wall-ceiling intersections
@MainActor
class TestModeDetector: NSObject, ObservableObject {

    // MARK: - Published State
    @Published var ceilingPlane: DetectedPlane?
    @Published var wallPlanes: [DetectedPlane] = []
    @Published var boundaryPoints: [SIMD3<Float>] = []  // Room boundary from intersections
    @Published var isPaused: Bool = false
    @Published var isListening: Bool = false
    @Published var isReceivingAudio: Bool = false  // For blinking mic
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

        var midpoint: SIMD3<Float> {
            (startPoint + endPoint) / 2.0
        }

        var length: Float {
            simd_distance(startPoint, endPoint)
        }
    }

    @Published var detectedEdges: [BoundaryEdge] = []

    // MARK: - Configuration

    private let ceilingProximityThreshold: Float = 0.20  // 20cm from ceiling
    private let ceilingNormalThreshold: Float = 0.8      // Normal Y < -0.8 for ceiling
    private let wallNormalThreshold: Float = 0.3         // abs(Normal Y) < 0.3 for walls

    // MARK: - Voice Recognition

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var audioLevelTimer: Timer?

    // MARK: - Initialization

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Voice Control

    func startListening() {
        guard !isListening else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                if status == .authorized {
                    self?.startAudioEngine()
                } else {
                    self?.statusMessage = "Voice not authorized"
                }
            }
        }
    }

    private func startAudioEngine() {
        stopListening()

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest,
              let speechRecognizer = speechRecognizer,
              speechRecognizer.isAvailable else {
            statusMessage = "Speech not available"
            return
        }

        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)

            // Check audio level for mic indicator
            self?.checkAudioLevel(buffer: buffer)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
            isListening = true
            updateStatus()
        } catch {
            statusMessage = "Audio failed"
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                self.processVoiceCommand(text)
            }

            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.isListening {
                        self.restartListening()
                    }
                }
            }
        }
    }

    private func checkAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += abs(channelData[i])
        }
        let average = sum / Float(frameLength)

        DispatchQueue.main.async {
            self.isReceivingAudio = average > 0.01  // Threshold for "hearing" audio
        }
    }

    private func restartListening() {
        stopListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.startAudioEngine()
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        isReceivingAudio = false
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

    private func hapticFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func updateStatus() {
        if isPaused {
            statusMessage = "PAUSED - Say 'Go' to continue"
        } else if ceilingPlane == nil {
            statusMessage = "Point at ceiling"
        } else {
            statusMessage = "Scan wall-ceiling edges - Say 'Pause' to stop"
        }
    }

    // MARK: - Frame Processing

    func processFrame(_ frame: ARFrame) {
        guard !isPaused else { return }

        // Process plane anchors
        for anchor in frame.anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                processPlaneAnchor(planeAnchor)
            }
        }

        // Find wall-ceiling intersections
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

        // Detect ceiling (normal pointing down, or classified as ceiling)
        if anchor.classification == .ceiling || normal.y < -ceilingNormalThreshold {
            let plane = DetectedPlane(
                id: anchor.identifier,
                center: center,
                normal: normal,
                extent: extent,
                classification: .ceiling
            )
            ceilingPlane = plane
        }
        // Detect walls near ceiling (within 20cm)
        else if anchor.classification == .wall || abs(normal.y) < wallNormalThreshold {
            if let ceiling = ceilingPlane {
                let distanceToCeiling = abs(center.y - ceiling.center.y)

                // Only consider walls close to ceiling
                if distanceToCeiling <= ceilingProximityThreshold {
                    let plane = DetectedPlane(
                        id: anchor.identifier,
                        center: center,
                        normal: normal,
                        extent: extent,
                        classification: .wall
                    )

                    // Add or update wall
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
            // Calculate intersection line between wall and ceiling
            if let edge = calculateIntersection(wall: wall, ceiling: ceiling) {
                newEdges.append(edge)
            }
        }

        // Update boundary points from edges
        detectedEdges = newEdges
        updateBoundaryPoints()
    }

    private func calculateIntersection(wall: DetectedPlane, ceiling: DetectedPlane) -> BoundaryEdge? {
        // Line direction is cross product of normals
        let lineDirection = simd_cross(wall.normal, ceiling.normal)
        let lengthSq = simd_length_squared(lineDirection)

        guard lengthSq > 0.0001 else { return nil }

        let normalizedDir = simd_normalize(lineDirection)

        // Find point on intersection line
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

        // Create edge segment based on wall extent
        let halfLength = max(wall.extent.x, wall.extent.y) / 2.0
        let start = point - normalizedDir * halfLength
        let end = point + normalizedDir * halfLength

        return BoundaryEdge(startPoint: start, endPoint: end)
    }

    private func updateBoundaryPoints() {
        var points: [SIMD3<Float>] = []

        for edge in detectedEdges {
            points.append(edge.startPoint)
            points.append(edge.endPoint)
        }

        // Remove duplicates and order clockwise
        boundaryPoints = orderPointsClockwise(removeDuplicates(points))
    }

    private func removeDuplicates(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        let threshold: Float = 0.15

        for point in points {
            let isDuplicate = result.contains { simd_distance($0, point) < threshold }
            if !isDuplicate {
                result.append(point)
            }
        }
        return result
    }

    private func orderPointsClockwise(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }

        var centroid = SIMD3<Float>(0, 0, 0)
        for p in points { centroid += p }
        centroid /= Float(points.count)

        return points.sorted { p1, p2 in
            let angle1 = atan2(p1.z - centroid.z, p1.x - centroid.x)
            let angle2 = atan2(p2.z - centroid.z, p2.x - centroid.x)
            return angle1 < angle2
        }
    }

    // MARK: - Reset

    func reset() {
        stopListening()
        ceilingPlane = nil
        wallPlanes = []
        boundaryPoints = []
        detectedEdges = []
        isPaused = false
        statusMessage = "Point at ceiling"
    }
}
