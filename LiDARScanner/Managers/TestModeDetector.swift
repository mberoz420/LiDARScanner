import Foundation
import simd
import ARKit
import UIKit
import Speech
import AVFoundation

/// Test Mode: Detect ceiling plane and create room boundary from wall-ceiling intersections
class TestModeDetector: ObservableObject {

    // MARK: - Published State
    @Published var ceilingPlane: CeilingPlane?
    @Published var ceilingBoundary: [SIMD3<Float>] = []  // Clean boundary points
    @Published var isPaused: Bool = false
    @Published var isListening: Bool = false
    @Published var isReceivingAudio: Bool = false
    @Published var statusMessage: String = "Point at ceiling"
    @Published var wallCount: Int = 0
    @Published var edgeCount: Int = 0

    // MARK: - Data Structures

    struct CeilingPlane {
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let y: Float  // Height of ceiling
    }

    struct WallIntersection {
        let point1: SIMD3<Float>
        let point2: SIMD3<Float>
        let direction: SIMD3<Float>  // Wall direction (horizontal)
    }

    // MARK: - Internal State

    private var detectedWallIntersections: [UUID: WallIntersection] = [:]
    private var rawCeilingY: [Float] = []  // Samples to average

    // MARK: - Configuration

    private let ceilingDetectionThreshold: Float = 0.85  // Normal Y < -0.85 for ceiling
    private let wallDetectionThreshold: Float = 0.25     // abs(Normal Y) < 0.25 for walls
    private let ceilingProximity: Float = 0.30           // 30cm - walls must be within this of ceiling
    private let minEdgeLength: Float = 0.20              // 20cm minimum edge
    private let mergeDistance: Float = 0.15              // 15cm - merge points closer than this

    // MARK: - Voice Recognition

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var permissionGranted: Bool = false

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Frame Processing

    func processFrame(_ frame: ARFrame) {
        guard !isPaused else { return }

        for anchor in frame.anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                processPlaneAnchor(planeAnchor)
            }
        }

        // Build ceiling boundary from wall intersections
        if ceilingPlane != nil {
            buildCeilingBoundary()
        }

        updateStatus()
    }

    private func processPlaneAnchor(_ anchor: ARPlaneAnchor) {
        let transform = anchor.transform
        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let normal = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)

        // STEP 1: Detect ceiling (horizontal plane with normal pointing DOWN)
        if anchor.classification == .ceiling || normal.y < -ceilingDetectionThreshold {
            // Accumulate ceiling height samples for stability
            rawCeilingY.append(center.y)
            if rawCeilingY.count > 20 {
                rawCeilingY.removeFirst()
            }

            // Use median for stable ceiling height
            let sortedY = rawCeilingY.sorted()
            let medianY = sortedY[sortedY.count / 2]

            let wasNil = ceilingPlane == nil
            ceilingPlane = CeilingPlane(
                center: SIMD3<Float>(center.x, medianY, center.z),
                normal: SIMD3<Float>(0, -1, 0),
                y: medianY
            )

            if wasNil {
                hapticFeedback()
            }
        }
        // STEP 2: Detect walls that are CLOSE to the ceiling
        else if anchor.classification == .wall || abs(normal.y) < wallDetectionThreshold {
            guard let ceiling = ceilingPlane else { return }

            // Check if wall's top edge is near ceiling (within 30cm)
            let wallTopY = center.y + (anchor.planeExtent.height / 2)
            let distanceToCeiling = abs(wallTopY - ceiling.y)

            if distanceToCeiling <= ceilingProximity {
                // Calculate where this wall intersects the ceiling plane
                let intersection = calculateWallCeilingIntersection(
                    wallCenter: center,
                    wallNormal: normal,
                    wallExtent: anchor.planeExtent,
                    ceilingY: ceiling.y
                )

                if let intersection = intersection {
                    let isNew = detectedWallIntersections[anchor.identifier] == nil
                    detectedWallIntersections[anchor.identifier] = intersection

                    if isNew {
                        hapticFeedback()
                    }
                }
            }
        }

        wallCount = detectedWallIntersections.count
    }

    private func calculateWallCeilingIntersection(
        wallCenter: SIMD3<Float>,
        wallNormal: SIMD3<Float>,
        wallExtent: ARPlaneExtent,
        ceilingY: Float
    ) -> WallIntersection? {
        // Wall direction is perpendicular to normal (in XZ plane)
        let wallDirection = simd_normalize(SIMD3<Float>(-wallNormal.z, 0, wallNormal.x))

        // Half width of wall
        let halfWidth = wallExtent.width / 2

        // Intersection line is at ceiling height, along wall direction
        let intersectionCenter = SIMD3<Float>(wallCenter.x, ceilingY, wallCenter.z)

        let point1 = intersectionCenter - wallDirection * halfWidth
        let point2 = intersectionCenter + wallDirection * halfWidth

        // Only keep edges longer than minimum
        let length = simd_distance(point1, point2)
        guard length >= minEdgeLength else { return nil }

        return WallIntersection(
            point1: point1,
            point2: point2,
            direction: wallDirection
        )
    }

    private func buildCeilingBoundary() {
        // Collect all intersection points
        var allPoints: [SIMD3<Float>] = []

        for (_, intersection) in detectedWallIntersections {
            allPoints.append(intersection.point1)
            allPoints.append(intersection.point2)
        }

        // Merge nearby points
        let mergedPoints = mergeNearbyPoints(allPoints)

        // Order points clockwise to form boundary
        let orderedPoints = orderPointsClockwise(mergedPoints)

        ceilingBoundary = orderedPoints
        edgeCount = orderedPoints.count
    }

    private func mergeNearbyPoints(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []

        for point in points {
            // Check if this point is close to an existing point
            var merged = false
            for i in 0..<result.count {
                if simd_distance(result[i], point) < mergeDistance {
                    // Average the points
                    result[i] = (result[i] + point) / 2.0
                    merged = true
                    break
                }
            }

            if !merged {
                result.append(point)
            }
        }

        return result
    }

    private func orderPointsClockwise(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > 2 else { return points }

        // Find centroid
        var centroid = SIMD3<Float>(0, 0, 0)
        for p in points { centroid += p }
        centroid /= Float(points.count)

        // Sort by angle from centroid (in XZ plane)
        return points.sorted { p1, p2 in
            let angle1 = atan2(p1.z - centroid.z, p1.x - centroid.x)
            let angle2 = atan2(p2.z - centroid.z, p2.x - centroid.x)
            return angle1 < angle2
        }
    }

    // MARK: - Voice Control

    func startListening() {
        AVAudioApplication.requestRecordPermission { [weak self] micGranted in
            guard micGranted else {
                DispatchQueue.main.async {
                    self?.statusMessage = "Mic not authorized"
                }
                return
            }

            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        self?.permissionGranted = true
                        self?.startAudioEngine()
                    } else {
                        self?.statusMessage = "Voice not authorized"
                    }
                }
            }
        }
    }

    private func startAudioEngine() {
        stopAudioEngine()

        guard permissionGranted,
              let speechRecognizer = speechRecognizer,
              speechRecognizer.isAvailable else {
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else { return }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
                self?.checkAudioLevel(buffer: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            isListening = true

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                if let result = result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    DispatchQueue.main.async {
                        self?.processVoiceCommand(text)
                    }
                }

                if error != nil || (result?.isFinal ?? false) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self, self.isListening else { return }
                        self.startAudioEngine()
                    }
                }
            }
        } catch {
            isListening = false
        }
    }

    private func checkAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength { sum += abs(channelData[i]) }
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
        } else if wallCount == 0 {
            statusMessage = "Scan wall-ceiling edges"
        } else {
            statusMessage = "\(wallCount) walls → \(edgeCount) boundary points"
        }
    }

    func reset() {
        stopListening()
        ceilingPlane = nil
        ceilingBoundary = []
        detectedWallIntersections = [:]
        rawCeilingY = []
        isPaused = false
        wallCount = 0
        edgeCount = 0
        statusMessage = "Point at ceiling"
    }
}
