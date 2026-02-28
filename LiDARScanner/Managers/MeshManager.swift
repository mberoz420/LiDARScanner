import Foundation
import ARKit
import RealityKit
import Combine
import UIKit
import AVFoundation
import Speech

@MainActor
class MeshManager: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isScanning = false
    @Published var scanStatus = "Ready to scan"
    @Published var vertexCount = 0
    @Published var meshUpdateCount = 0
    @Published var lidarAvailable = false
    @Published var faceTrackingAvailable = false
    @Published var currentMode: ScanMode = .largeObjects
    @Published var usingFrontCamera = false
    @Published var surfaceClassificationEnabled = true
    @Published var deviceOrientation: DeviceOrientation = .lookingHorizontal

    // MARK: - Guided Room Scanning
    @Published var currentPhase: RoomScanPhase = .ready
    @Published var phaseProgress: Double = 0
    @Published var useEdgeVisualization = false  // Edge lines instead of mesh overlay
    @Published var edgeInReticle = false  // True when edge is detected in center of screen
    @Published var isPaused = false  // True when device movement has stopped
    @Published var edgeConfirmed = false  // True when paused over an edge (confirmed detection)
    @Published var confirmedCornerCount = 0  // Number of user-confirmed corners

    // User-confirmed corners (high confidence from pause gesture)
    private(set) var userConfirmedCorners: [SIMD3<Float>] = []

    // Movement tracking for pause detection
    private var lastCameraPosition: SIMD3<Float>?
    private var lastCameraUpdateTime: Date = .distantPast
    private var movementSamples: [Float] = []  // Recent movement speeds
    private let pauseThreshold: Float = 0.008  // Movement below this = paused (8mm/frame)
    private let pauseDuration: TimeInterval = 0.3  // Must be still for this long
    private var pauseStartTime: Date?
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    private var lastConfirmedPosition: SIMD3<Float>?  // Prevent duplicate confirmations
    private let speechSynthesizer = AVSpeechSynthesizer()

    // Speech recognition for voice commands
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    @Published var isListening = false
    @Published var lastVoiceCommand: String?

    // Voice command types
    enum VoiceCommand: String, CaseIterable {
        case edge = "edge"
        case corner = "corner"
        case door = "door"
        case window = "window"
        case furniture = "furniture"
        case wall = "wall"

        var confirmationMessage: String {
            switch self {
            case .edge, .corner: return "Corner"
            case .door: return "Door"
            case .window: return "Window"
            case .furniture: return "Furniture"
            case .wall: return "Wall"
            }
        }
    }

    // Surface classifier for floor/ceiling/wall detection
    let surfaceClassifier = SurfaceClassifier()

    // Edge visualizer for room mode
    let edgeVisualizer = EdgeVisualizer()

    // Intelligent room builder for walls mode
    let roomBuilder = RoomBuilder()

    // MARK: - Session Resume
    @Published var isRepairMode = false
    @Published var resumedSessionId: UUID?
    private var existingMeshQuality: [UUID: Float] = [:]  // Quality scores for existing meshes

    // MARK: - Properties
    private weak var arView: ARView?
    private var meshAnchors: [UUID: AnchorEntity] = [:]
    private var faceAnchors: [UUID: AnchorEntity] = [:]
    private var surfaceTypes: [UUID: SurfaceType] = [:]  // Track surface type per mesh
    private var capturedScan: CapturedScan?
    private var lastMeshUpdateTime: Date = .distantPast
    private var currentFrame: ARFrame?

    // MARK: - Setup
    func setup(arView: ARView) {
        self.arView = arView
        arView.session.delegate = self

        // Check LiDAR availability
        lidarAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

        // Check face tracking availability (TrueDepth camera)
        faceTrackingAvailable = ARFaceTrackingConfiguration.isSupported

        // Setup edge visualizer
        edgeVisualizer.setup(arView: arView)

        if lidarAvailable {
            scanStatus = "LiDAR ready"
        } else {
            scanStatus = "LiDAR not available"
        }
    }

    // MARK: - Mode Management
    func setMode(_ mode: ScanMode) {
        currentMode = mode
        scanStatus = mode.guidanceText
    }

    private func meshMaterial(for mode: ScanMode) -> SimpleMaterial {
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(mode.color).withAlphaComponent(0.4))
        material.metallic = 0.0
        material.roughness = 0.9
        return material
    }

    private func meshMaterial(for surfaceType: SurfaceType) -> SimpleMaterial {
        var material = SimpleMaterial()
        let color = surfaceType.color
        material.color = .init(tint: UIColor(
            red: CGFloat(color.r),
            green: CGFloat(color.g),
            blue: CGFloat(color.b),
            alpha: CGFloat(color.a)
        ))
        material.metallic = 0.0
        material.roughness = 0.9
        return material
    }

    // MARK: - Scanning Control
    func startScanning() {
        guard let arView = arView else { return }

        // Clear previous scan
        clearMeshVisualization()
        edgeVisualizer.clearEdges()
        roomBuilder.reset()
        capturedScan = CapturedScan(startTime: Date())
        meshUpdateCount = 0
        vertexCount = 0
        surfaceTypes.removeAll()

        // Reset user-confirmed corners
        userConfirmedCorners.removeAll()
        confirmedCornerCount = 0
        lastConfirmedPosition = nil
        movementSamples.removeAll()
        pauseStartTime = nil
        isPaused = false
        edgeConfirmed = false

        // Reset surface classifier and sync with app settings
        surfaceClassifier.reset()
        surfaceClassificationEnabled = AppSettings.shared.surfaceClassificationEnabled

        // Setup guided scanning for room mode
        if currentMode == .walls {
            currentPhase = .floor
            phaseProgress = 0
            useEdgeVisualization = true
            // Always enable classification for guided room mode (needed for edge detection)
            surfaceClassifier.classificationEnabled = true
            scanStatus = currentPhase.instruction

            // Start voice commands for walls mode
            startVoiceCommands()
        } else {
            currentPhase = .ready
            useEdgeVisualization = false
            surfaceClassifier.classificationEnabled = surfaceClassificationEnabled
        }

        // Configure based on mode
        if currentMode == .organic && faceTrackingAvailable && usingFrontCamera {
            startFaceTracking(arView: arView)
        } else {
            startLiDARTracking(arView: arView)
        }

        isScanning = true
        if currentMode != .walls {
            scanStatus = currentMode.guidanceText
        }
    }

    private func startLiDARTracking(arView: ARView) {
        let config = ARWorldTrackingConfiguration()

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        config.planeDetection = [.horizontal, .vertical]

        // Higher frame rate for small objects
        if currentMode == .smallObjects {
            config.videoFormat = ARWorldTrackingConfiguration.supportedVideoFormats
                .filter { $0.framesPerSecond >= 60 }
                .first ?? config.videoFormat
        }

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        usingFrontCamera = false
    }

    private func startFaceTracking(arView: ARView) {
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1

        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        usingFrontCamera = true
        scanStatus = "Face detected - hold still"
    }

    func toggleCamera() {
        guard let arView = arView, currentMode == .organic else { return }

        if usingFrontCamera {
            startLiDARTracking(arView: arView)
        } else if faceTrackingAvailable {
            startFaceTracking(arView: arView)
        }
    }

    // MARK: - Session Resume

    /// Load existing meshes from a saved session for resuming
    func loadExistingMeshes(_ scan: CapturedScan, repairMode: Bool) {
        guard let arView = arView else { return }

        isRepairMode = repairMode
        capturedScan = scan

        // Store quality scores for repair mode comparison
        existingMeshQuality.removeAll()

        // Create visual representation of existing meshes (semi-transparent)
        for mesh in scan.meshes {
            // Create mesh visualization
            let vertices = mesh.vertices
            let indices = mesh.faces.flatMap { $0 }

            // Create a simple bounding box representation for now
            // Full mesh rendering would require MeshResource generation
            if !vertices.isEmpty {
                let center = vertices.reduce(SIMD3<Float>.zero) { $0 + $1 } / Float(vertices.count)
                let transformedCenter = mesh.transform * SIMD4<Float>(center.x, center.y, center.z, 1)

                // Create a small indicator at mesh location
                let indicatorMesh = MeshResource.generateSphere(radius: 0.02)
                var material = SimpleMaterial()
                material.color = .init(tint: UIColor.cyan.withAlphaComponent(0.5))

                let entity = ModelEntity(mesh: indicatorMesh, materials: [material])
                let anchor = AnchorEntity(world: SIMD3<Float>(transformedCenter.x, transformedCenter.y, transformedCenter.z))
                anchor.addChild(entity)
                arView.scene.addAnchor(anchor)
                meshAnchors[mesh.identifier] = anchor
            }

            // Store default quality score (will be updated in repair mode)
            existingMeshQuality[mesh.identifier] = 0.5
        }

        vertexCount = scan.vertexCount
        scanStatus = "Loaded \(scan.meshes.count) meshes - ready to continue"

        print("[MeshManager] Loaded \(scan.meshes.count) existing meshes, repair mode: \(repairMode)")
    }

    /// Get the current scan with any updates
    func getCurrentScan() -> CapturedScan? {
        return capturedScan
    }

    func stopScanning() -> CapturedScan? {
        isScanning = false
        capturedScan?.endTime = Date()

        // Stop any ongoing speech
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        // Stop voice commands
        stopVoiceCommands()

        // Include user-confirmed corners in statistics
        var stats = surfaceClassifier.statistics
        stats.userConfirmedCorners = userConfirmedCorners
        capturedScan?.statistics = stats

        // Build summary
        var summary = "\(vertexCount) vertices"
        if !surfaceClassifier.statistics.summary.isEmpty {
            summary += " | \(surfaceClassifier.statistics.summary)"
        }
        if !userConfirmedCorners.isEmpty {
            summary += " | \(userConfirmedCorners.count) confirmed corners"
        }
        scanStatus = "Scan complete - \(summary)"

        return capturedScan
    }

    func clearMeshVisualization() {
        for (_, anchor) in meshAnchors {
            anchor.removeFromParent()
        }
        meshAnchors.removeAll()

        for (_, anchor) in faceAnchors {
            anchor.removeFromParent()
        }
        faceAnchors.removeAll()
    }

    // MARK: - Corner Confirmation

    /// Confirm a corner at the given position (from pause gesture or voice command)
    private func confirmCorner(at position: SIMD3<Float>, source: String) {
        // Check if not too close to an already confirmed corner
        let isDuplicate = userConfirmedCorners.contains { existing in
            simd_length(existing - position) < 0.2  // 20cm threshold
        }

        guard !isDuplicate else { return }

        userConfirmedCorners.append(position)
        confirmedCornerCount = userConfirmedCorners.count
        lastConfirmedPosition = position

        // Add to edge visualizer with high priority
        edgeVisualizer.addCorner(at: position)

        // Haptic feedback
        if AppSettings.shared.hapticFeedbackEnabled {
            hapticGenerator.impactOccurred()
        }

        // Speech feedback
        speakConfirmation("Corner \(userConfirmedCorners.count)")

        print("[MeshManager] Corner CONFIRMED via \(source) at \(position), total: \(userConfirmedCorners.count)")
    }

    // MARK: - Speech Feedback

    /// Speak a confirmation message
    private func speakConfirmation(_ message: String) {
        guard AppSettings.shared.speechFeedbackEnabled else { return }

        // Stop any current speech
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.2  // Slightly faster
        utterance.volume = 0.8
        utterance.pitchMultiplier = 1.1  // Slightly higher pitch for clarity

        speechSynthesizer.speak(utterance)
    }

    // MARK: - Voice Commands (Speech Recognition)

    /// Start listening for voice commands
    func startVoiceCommands() {
        guard AppSettings.shared.voiceCommandsEnabled else {
            print("[MeshManager] Voice commands disabled in settings")
            return
        }

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    // Delay to let ARKit's audio session settle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.startListening()
                    }
                case .denied, .restricted, .notDetermined:
                    print("[MeshManager] Speech recognition not authorized: \(status)")
                @unknown default:
                    break
                }
            }
        }
    }

    /// Stop listening for voice commands
    func stopVoiceCommands() {
        // Only clean up if we were actually listening
        guard isListening || recognitionTask != nil else {
            print("[MeshManager] Voice commands - nothing to stop")
            return
        }

        // Stop recognition first
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Safely stop audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            // Only remove tap if engine was running (meaning tap was installed)
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        isListening = false
        print("[MeshManager] Voice commands stopped")
    }

    private func startListening() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("[MeshManager] Speech recognizer not available")
            return
        }

        // Cancel any ongoing task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Stop audio engine if running
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        // Configure audio session - use mixWithOthers to avoid conflicts with ARKit
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[MeshManager] Audio session setup failed: \(error)")
            return
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true

        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let result = result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    self.processVoiceInput(text)
                }

                if error != nil || (result?.isFinal ?? false) {
                    // Restart listening if still scanning
                    if self.isScanning && self.currentMode == .walls && AppSettings.shared.voiceCommandsEnabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.startListening()
                        }
                    }
                }
            }
        }

        // Configure audio input with validation
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Validate audio format - crash prevention
        guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
            print("[MeshManager] Invalid audio format: sampleRate=\(recordingFormat.sampleRate), channels=\(recordingFormat.channelCount)")
            return
        }

        // Install tap for audio buffer (installTap doesn't throw, we already removed any existing tap above)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            print("[MeshManager] Voice commands listening started")
        } catch {
            print("[MeshManager] Audio engine start failed: \(error)")
            // Clean up on failure
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    /// Process recognized voice input and look for commands
    private func processVoiceInput(_ text: String) {
        // Look for command keywords in the text
        for command in VoiceCommand.allCases {
            if text.contains(command.rawValue) {
                handleVoiceCommand(command)
                // Clear recognition to avoid duplicate triggers
                recognitionTask?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if self.isScanning && self.currentMode == .walls {
                        self.startListening()
                    }
                }
                break
            }
        }
    }

    /// Handle a recognized voice command
    private func handleVoiceCommand(_ command: VoiceCommand) {
        guard let frame = currentFrame else { return }

        lastVoiceCommand = command.rawValue

        // Get position where user is pointing
        guard let position = getReticleTargetPosition(frame: frame) else { return }

        // Haptic feedback
        if AppSettings.shared.hapticFeedbackEnabled {
            hapticGenerator.impactOccurred()
        }

        switch command {
        case .edge, .corner, .wall:
            // Register as corner
            confirmCorner(at: position, source: "voice:\(command.rawValue)")

        case .door:
            // Register as door
            registerDoor(at: position, frame: frame)
            speakConfirmation("Door marked")
            print("[MeshManager] Voice: door at \(position)")

        case .window:
            // Register as window
            registerWindow(at: position, frame: frame)
            speakConfirmation("Window marked")
            print("[MeshManager] Voice: window at \(position)")

        case .furniture:
            // Register as furniture (to exclude from clean walls)
            registerFurniture(at: position)
            speakConfirmation("Furniture marked")
            print("[MeshManager] Voice: furniture at \(position)")
        }
    }

    /// Register a door at the given position
    private func registerDoor(at position: SIMD3<Float>, frame: ARFrame) {
        let floorY = surfaceClassifier.statistics.floorHeight ?? 0
        let width: Float = 0.9   // Default door width ~90cm
        let height: Float = 2.1  // Default door height ~210cm

        // Estimate wall normal from camera direction (perpendicular to viewing direction)
        let cameraForward = frame.camera.transform.columns.2
        let wallNormal = SIMD3<Float>(-cameraForward.x, 0, -cameraForward.z)
        let normalizedWallNormal = simd_normalize(wallNormal)

        // Calculate bounding box centered on position, from floor up
        let halfWidth = width / 2
        let boundingBox = (
            min: SIMD3<Float>(position.x - halfWidth, floorY, position.z - 0.1),
            max: SIMD3<Float>(position.x + halfWidth, floorY + height, position.z + 0.1)
        )

        let door = DetectedDoor(
            id: UUID(),
            position: position,
            width: width,
            height: height,
            wallNormal: normalizedWallNormal,
            boundingBox: boundingBox,
            confidence: 1.0  // User-confirmed = high confidence
        )
        surfaceClassifier.statistics.detectedDoors.append(door)
    }

    /// Register a window at the given position
    private func registerWindow(at position: SIMD3<Float>, frame: ARFrame) {
        let floorY = surfaceClassifier.statistics.floorHeight ?? 0
        let width: Float = 1.0           // Default window width ~100cm
        let height: Float = 1.2          // Default window height ~120cm
        let heightFromFloor: Float = 0.9 // Default sill height ~90cm

        // Estimate wall normal from camera direction (perpendicular to viewing direction)
        let cameraForward = frame.camera.transform.columns.2
        let wallNormal = SIMD3<Float>(-cameraForward.x, 0, -cameraForward.z)
        let normalizedWallNormal = simd_normalize(wallNormal)

        // Calculate bounding box for window
        let halfWidth = width / 2
        let windowBottomY = floorY + heightFromFloor
        let boundingBox = (
            min: SIMD3<Float>(position.x - halfWidth, windowBottomY, position.z - 0.1),
            max: SIMD3<Float>(position.x + halfWidth, windowBottomY + height, position.z + 0.1)
        )

        let window = DetectedWindow(
            id: UUID(),
            position: position,
            width: width,
            height: height,
            heightFromFloor: heightFromFloor,
            wallNormal: normalizedWallNormal,
            boundingBox: boundingBox,
            confidence: 1.0  // User-confirmed = high confidence
        )
        surfaceClassifier.statistics.detectedWindows.append(window)
    }

    /// Register furniture to exclude from clean walls export
    private func registerFurniture(at position: SIMD3<Float>) {
        // Store furniture positions for exclusion during wall reconstruction
        // For now, we just log it - can be extended later
        print("[MeshManager] Furniture registered at \(position) - will be excluded from clean walls")
    }

    // MARK: - Reticle Target Position

    /// Get the 3D world position where the reticle (center of screen) is pointing
    private func getReticleTargetPosition(frame: ARFrame) -> SIMD3<Float>? {
        let camera = frame.camera

        // Camera position
        let cameraPosition = SIMD3<Float>(
            camera.transform.columns.3.x,
            camera.transform.columns.3.y,
            camera.transform.columns.3.z
        )

        // Camera forward direction (negative Z in camera space)
        let cameraForward = -SIMD3<Float>(
            camera.transform.columns.2.x,
            camera.transform.columns.2.y,
            camera.transform.columns.2.z
        )

        // Find the closest edge/corner entity in the reticle direction
        // Use the edgeVisualizer's corner positions
        var closestPosition: SIMD3<Float>?
        var closestDistance: Float = Float.greatestFiniteMagnitude

        // Check against existing detected edges from surfaceClassifier
        for edge in surfaceClassifier.statistics.detectedEdges {
            if edge.edgeType == .verticalCorner {
                let midpoint = (edge.startPoint + edge.endPoint) / 2

                // Vector from camera to edge
                let toEdge = midpoint - cameraPosition
                let distance = simd_length(toEdge)

                // Check if edge is roughly in front of camera
                let dot = simd_dot(simd_normalize(toEdge), cameraForward)
                if dot > 0.9 && distance < closestDistance && distance < 5.0 {
                    closestDistance = distance
                    closestPosition = midpoint
                }
            }
        }

        // If no edge found, raycast to estimate position at ~1.5m ahead
        if closestPosition == nil {
            // Default: position 1.5m ahead at floor level
            let floorY = surfaceClassifier.statistics.floorHeight ?? 0
            let targetDistance: Float = 1.5
            let targetPoint = cameraPosition + cameraForward * targetDistance
            closestPosition = SIMD3<Float>(targetPoint.x, floorY, targetPoint.z)
        }

        return closestPosition
    }

    // MARK: - Mesh Processing
    private func processMeshAnchor(_ anchor: ARMeshAnchor) {
        guard isScanning else { return }

        // Classify the surface
        let classifiedSurface = surfaceClassifier.classifyMeshAnchor(anchor)
        surfaceTypes[anchor.identifier] = classifiedSurface.surfaceType

        // Check if this surface should be filtered (room layout mode)
        let shouldFilter = surfaceClassifier.shouldFilterSurface(classifiedSurface)

        if shouldFilter {
            // Remove visualization if it exists (object was previously visible)
            removeMeshVisualization(for: anchor.identifier)
            // Remove from captured scan
            capturedScan?.meshes.removeAll { $0.identifier == anchor.identifier }
            return
        }

        // Adaptive throttling based on surface type
        let baseInterval = currentMode.updateInterval
        let multiplier = surfaceClassifier.updateIntervalMultiplier(for: classifiedSurface.surfaceType)
        let adjustedInterval = baseInterval * multiplier

        let now = Date()
        guard now.timeIntervalSince(lastMeshUpdateTime) > adjustedInterval else { return }
        lastMeshUpdateTime = now

        // Extract geometry data
        let meshData = extractMeshData(from: anchor)

        // Detect protrusions if ceiling-related
        if classifiedSurface.surfaceType == .ceilingProtrusion {
            surfaceClassifier.detectProtrusion(
                meshID: anchor.identifier,
                vertices: meshData.vertices,
                transform: anchor.transform,
                surfaceType: classifiedSurface.surfaceType
            )
        }

        // Detect doors/windows in wall meshes
        if classifiedSurface.surfaceType == .wall && AppSettings.shared.detectDoorsWindows {
            surfaceClassifier.detectOpenings(
                in: meshData,
                wallNormal: classifiedSurface.averageNormal
            )
        }

        // Process walls with intelligent room builder (walls mode only)
        if currentMode == .walls && roomBuilder.isCalibrated {
            if classifiedSurface.surfaceType == .wall {
                // Send vertical wall surface to room builder
                roomBuilder.processVerticalSurface(
                    vertices: meshData.vertices,
                    normal: classifiedSurface.averageNormal,
                    transform: anchor.transform,
                    meshID: anchor.identifier
                )
            }
        }

        // Update visualization with surface-appropriate color
        updateMeshVisualization(for: anchor, surfaceType: classifiedSurface.surfaceType)

        // Update edge visualization in room mode - show edges as they're detected
        if useEdgeVisualization && currentMode == .walls {
            let edges = surfaceClassifier.statistics.detectedEdges
            if !edges.isEmpty {
                edgeVisualizer.updateEdges(edges)
                print("[MeshManager] Passing \(edges.count) edges to visualizer")
            }
        }

        // Store for export
        if let index = capturedScan?.meshes.firstIndex(where: { $0.identifier == anchor.identifier }) {
            capturedScan?.meshes[index] = meshData
        } else {
            capturedScan?.meshes.append(meshData)
        }

        vertexCount = capturedScan?.vertexCount ?? 0
        meshUpdateCount += 1

        // Update status with room info
        updateScanStatus()
    }

    private func updateScanStatus() {
        let stats = surfaceClassifier.statistics

        // Handle guided room scanning
        if currentMode == .walls && useEdgeVisualization {
            updateRoomScanPhase()
            return
        }

        if !stats.summary.isEmpty {
            scanStatus = "\(currentMode.guidanceText) | \(stats.summary)"
        } else {
            scanStatus = currentMode.guidanceText
        }
    }

    // MARK: - Guided Room Scanning

    private func updateRoomScanPhase() {
        let stats = surfaceClassifier.statistics

        switch currentPhase {
        case .ready:
            scanStatus = currentPhase.instruction
            phaseProgress = 0

        case .floor:
            phaseProgress = Double(stats.floorConfidence)
            if let floorH = stats.floorHeight {
                scanStatus = String(format: "Floor detected at %.2fm", floorH)
                // Calibrate room builder and edge visualizer with floor level
                roomBuilder.calibrateFloor(at: floorH)
                edgeVisualizer.floorY = floorH
            } else {
                scanStatus = currentPhase.instruction
            }
            // Auto-advance when floor is detected with high confidence
            if stats.floorConfidence >= Float(currentPhase.completionThreshold) {
                advancePhase()
            }

        case .ceiling:
            phaseProgress = Double(stats.ceilingConfidence)
            if let height = stats.estimatedRoomHeight, let ceilingH = stats.ceilingHeight {
                scanStatus = String(format: "Height: %.2fm", height)
                // Calibrate room builder and edge visualizer
                roomBuilder.calibrateCeiling(at: ceilingH)
                edgeVisualizer.ceilingY = ceilingH
                edgeVisualizer.setRoomDimensions(floor: stats.floorHeight ?? 0, ceiling: ceilingH)
            } else if stats.ceilingHeight != nil {
                scanStatus = "Measuring height..."
            } else {
                scanStatus = currentPhase.instruction
            }
            // Auto-advance when ceiling is detected
            if stats.ceilingConfidence >= Float(currentPhase.completionThreshold) {
                advancePhase()
            }

        case .walls:
            // Count detected corners from edge data
            let cornerEdges = stats.detectedEdges.filter { $0.edgeType == .verticalCorner }
            let cornerCount = cornerEntities(in: cornerEdges)

            phaseProgress = Double(min(Float(cornerCount) / 4.0, 1.0))
            scanStatus = "\(cornerCount) corners detected"

            // Update edge visualization - only vertical corners become lines
            edgeVisualizer.updateEdges(stats.detectedEdges)

            // Check for completion (4+ corners = enclosed room)
            if cornerCount >= 4 {
                advancePhase()
            }

        case .complete:
            phaseProgress = 1.0
            let wallCount = roomBuilder.wallSegments.count
            let openingCount = roomBuilder.detectedOpenings.count

            if roomBuilder.roomHeight > 0 {
                // Calculate room bounds from wall segments
                let allX = roomBuilder.wallSegments.flatMap { [$0.startPoint.x, $0.endPoint.x] }
                let allZ = roomBuilder.wallSegments.flatMap { [$0.startPoint.y, $0.endPoint.y] }

                if let minX = allX.min(), let maxX = allX.max(),
                   let minZ = allZ.min(), let maxZ = allZ.max() {
                    let width = maxX - minX
                    let depth = maxZ - minZ
                    scanStatus = String(format: "Room: %.1fm x %.1fm x %.1fm | %d walls | %d openings",
                                        width, depth, roomBuilder.roomHeight, wallCount, openingCount)
                } else {
                    scanStatus = String(format: "Height: %.1fm | %d walls | %d openings",
                                        roomBuilder.roomHeight, wallCount, openingCount)
                }
            } else {
                scanStatus = "Room captured!"
            }

            // Generate final edges from room builder
            generateEdgesFromRoomBuilder()
        }
    }

    /// Count unique corners from edges (de-duplicated by position)
    private func cornerEntities(in edges: [WallEdge]) -> Int {
        var uniqueCorners: Set<String> = []
        for edge in edges {
            let midpoint = (edge.startPoint + edge.endPoint) / 2
            let gridX = round(midpoint.x * 10) / 10
            let gridZ = round(midpoint.z * 10) / 10
            uniqueCorners.insert("\(gridX)_\(gridZ)")
        }
        return uniqueCorners.count
    }

    /// Generate edge lines from room builder's wall segments and corners
    private func generateEdgesFromRoomBuilder() {
        var edges: [WallEdge] = []

        // Create vertical corner edges
        for corner in roomBuilder.roomCorners {
            let bottomPoint = SIMD3<Float>(corner.position.x, roomBuilder.floorLevel, corner.position.z)
            let topPoint = SIMD3<Float>(corner.position.x, roomBuilder.floorLevel + roomBuilder.roomHeight, corner.position.z)

            edges.append(WallEdge(
                id: corner.id,
                startPoint: bottomPoint,
                endPoint: topPoint,
                edgeType: .verticalCorner,
                angle: corner.angle
            ))
        }

        // Create floor-wall edges from wall segments
        for segment in roomBuilder.wallSegments {
            let start3D = SIMD3<Float>(segment.startPoint.x, roomBuilder.floorLevel, segment.startPoint.y)
            let end3D = SIMD3<Float>(segment.endPoint.x, roomBuilder.floorLevel, segment.endPoint.y)

            edges.append(WallEdge(
                id: UUID(),
                startPoint: start3D,
                endPoint: end3D,
                edgeType: .floorWall,
                angle: Float.pi / 2
            ))

            // Ceiling edge
            let startCeiling = SIMD3<Float>(segment.startPoint.x, roomBuilder.floorLevel + roomBuilder.roomHeight, segment.startPoint.y)
            let endCeiling = SIMD3<Float>(segment.endPoint.x, roomBuilder.floorLevel + roomBuilder.roomHeight, segment.endPoint.y)

            edges.append(WallEdge(
                id: UUID(),
                startPoint: startCeiling,
                endPoint: endCeiling,
                edgeType: .ceilingWall,
                angle: Float.pi / 2
            ))
        }

        // Create opening edges (doors, windows)
        for opening in roomBuilder.detectedOpenings {
            let edgeType: WallEdge.EdgeType = opening.type == .door ? .doorFrame : .windowFrame

            // Left edge of opening
            let leftBottom = SIMD3<Float>(
                opening.position.x - opening.width / 2,
                roomBuilder.floorLevel + opening.bottomFromFloor,
                opening.position.z
            )
            let leftTop = SIMD3<Float>(
                opening.position.x - opening.width / 2,
                roomBuilder.floorLevel + opening.bottomFromFloor + opening.height,
                opening.position.z
            )
            edges.append(WallEdge(id: UUID(), startPoint: leftBottom, endPoint: leftTop, edgeType: edgeType, angle: Float.pi / 2))

            // Right edge of opening
            let rightBottom = SIMD3<Float>(
                opening.position.x + opening.width / 2,
                roomBuilder.floorLevel + opening.bottomFromFloor,
                opening.position.z
            )
            let rightTop = SIMD3<Float>(
                opening.position.x + opening.width / 2,
                roomBuilder.floorLevel + opening.bottomFromFloor + opening.height,
                opening.position.z
            )
            edges.append(WallEdge(id: UUID(), startPoint: rightBottom, endPoint: rightTop, edgeType: edgeType, angle: Float.pi / 2))

            // Top edge of opening (for windows and doors)
            edges.append(WallEdge(id: UUID(), startPoint: leftTop, endPoint: rightTop, edgeType: edgeType, angle: Float.pi / 2))

            // Bottom edge (only for windows, not doors)
            if opening.type == .window {
                edges.append(WallEdge(id: UUID(), startPoint: leftBottom, endPoint: rightBottom, edgeType: edgeType, angle: Float.pi / 2))
            }
        }

        edgeVisualizer.updateEdges(edges)
    }

    /// Advance to the next phase
    func advancePhase() {
        guard let next = currentPhase.nextPhase else { return }
        currentPhase = next
        phaseProgress = 0

        // Play haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        // Update status
        scanStatus = currentPhase.instruction
    }

    /// Skip current phase (manual override)
    func skipPhase() {
        advancePhase()
    }

    private func processFaceAnchor(_ anchor: ARFaceAnchor) {
        guard isScanning else { return }

        let now = Date()
        guard now.timeIntervalSince(lastMeshUpdateTime) > currentMode.updateInterval else { return }
        lastMeshUpdateTime = now

        // Extract face geometry
        let meshData = extractFaceData(from: anchor)

        // Update visualization
        updateFaceVisualization(for: anchor)

        // Store for export
        if let index = capturedScan?.meshes.firstIndex(where: { $0.identifier == anchor.identifier }) {
            capturedScan?.meshes[index] = meshData
        } else {
            capturedScan?.meshes.append(meshData)
        }

        vertexCount = capturedScan?.vertexCount ?? 0
        meshUpdateCount += 1
    }

    private func extractMeshData(from anchor: ARMeshAnchor) -> CapturedMeshData {
        let geometry = anchor.geometry

        var vertices: [SIMD3<Float>] = []
        for i in 0..<geometry.vertices.count {
            vertices.append(geometry.vertex(at: i))
        }

        var normals: [SIMD3<Float>] = []
        for i in 0..<geometry.normals.count {
            normals.append(geometry.normal(at: i))
        }

        var faces: [[UInt32]] = []
        for i in 0..<geometry.faces.count {
            let face = geometry.faceIndices(at: i)
            faces.append(face)
        }

        // Sample colors from camera frame (skip for Walls mode - geometry only)
        var colors: [VertexColor] = []
        if currentMode != .walls, let frame = currentFrame {
            colors = TextureProjector.sampleColors(
                for: vertices,
                meshTransform: anchor.transform,
                frame: frame
            )
        }

        // Get surface classification
        let surfaceType = surfaceTypes[anchor.identifier]

        // Get per-face classifications if enabled (or if using edge visualization)
        var faceClassifications: [SurfaceType]? = nil
        if surfaceClassificationEnabled || useEdgeVisualization {
            faceClassifications = surfaceClassifier.classifyMesh(
                vertices: vertices,
                normals: normals,
                faces: faces,
                transform: anchor.transform
            )
        }

        return CapturedMeshData(
            vertices: vertices,
            normals: normals,
            colors: colors,
            faces: faces,
            transform: anchor.transform,
            identifier: anchor.identifier,
            surfaceType: surfaceType,
            faceClassifications: faceClassifications
        )
    }

    private func extractFaceData(from anchor: ARFaceAnchor) -> CapturedMeshData {
        let geometry = anchor.geometry

        // Extract vertices
        var vertices: [SIMD3<Float>] = []
        for i in 0..<geometry.vertices.count {
            vertices.append(geometry.vertices[i])
        }

        // Face geometry doesn't have normals in the same way, compute from faces
        var normals: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0, 0, 1), count: vertices.count)

        // Extract faces (triangles)
        var faces: [[UInt32]] = []
        let indexCount = geometry.triangleCount * 3
        for i in stride(from: 0, to: indexCount, by: 3) {
            let i0 = UInt32(geometry.triangleIndices[i])
            let i1 = UInt32(geometry.triangleIndices[i + 1])
            let i2 = UInt32(geometry.triangleIndices[i + 2])
            faces.append([i0, i1, i2])

            // Compute face normal
            if Int(i0) < vertices.count && Int(i1) < vertices.count && Int(i2) < vertices.count {
                let v0 = vertices[Int(i0)]
                let v1 = vertices[Int(i1)]
                let v2 = vertices[Int(i2)]
                let normal = normalize(cross(v1 - v0, v2 - v0))
                normals[Int(i0)] = normal
                normals[Int(i1)] = normal
                normals[Int(i2)] = normal
            }
        }

        // Sample colors from camera frame
        var colors: [VertexColor] = []
        if let frame = currentFrame {
            colors = TextureProjector.sampleColors(
                for: vertices,
                meshTransform: anchor.transform,
                frame: frame
            )
        }

        return CapturedMeshData(
            vertices: vertices,
            normals: normals,
            colors: colors,
            faces: faces,
            transform: anchor.transform,
            identifier: anchor.identifier
        )
    }

    private func updateMeshVisualization(for anchor: ARMeshAnchor, surfaceType: SurfaceType? = nil) {
        guard let arView = arView else { return }

        // Skip mesh overlay when using edge visualization (room mode)
        if useEdgeVisualization {
            // Don't render mesh surfaces - only edges are shown
            return
        }

        guard let meshResource = try? MeshResource.generate(from: anchor.geometry) else { return }

        // Use surface-based color if classification is enabled, otherwise mode color
        let material: SimpleMaterial
        if surfaceClassificationEnabled, let type = surfaceType {
            material = meshMaterial(for: type)
        } else {
            material = meshMaterial(for: currentMode)
        }

        if let existingAnchor = meshAnchors[anchor.identifier] {
            if let modelEntity = existingAnchor.children.first as? ModelEntity {
                modelEntity.model?.mesh = meshResource
                modelEntity.model?.materials = [material]
            }
        } else {
            let modelEntity = ModelEntity(mesh: meshResource, materials: [material])
            let anchorEntity = AnchorEntity(world: anchor.transform)
            anchorEntity.addChild(modelEntity)
            arView.scene.addAnchor(anchorEntity)
            meshAnchors[anchor.identifier] = anchorEntity
        }
    }

    private func updateFaceVisualization(for anchor: ARFaceAnchor) {
        guard let arView = arView else { return }

        guard let meshResource = try? MeshResource.generate(from: anchor.geometry) else { return }

        let material = meshMaterial(for: currentMode)

        if let existingAnchor = faceAnchors[anchor.identifier] {
            if let modelEntity = existingAnchor.children.first as? ModelEntity {
                modelEntity.model?.mesh = meshResource
            }
            existingAnchor.transform = Transform(matrix: anchor.transform)
        } else {
            let modelEntity = ModelEntity(mesh: meshResource, materials: [material])
            let anchorEntity = AnchorEntity(world: anchor.transform)
            anchorEntity.addChild(modelEntity)
            arView.scene.addAnchor(anchorEntity)
            faceAnchors[anchor.identifier] = anchorEntity
        }
    }

    private func removeMeshVisualization(for anchorID: UUID) {
        if let anchor = meshAnchors.removeValue(forKey: anchorID) {
            anchor.removeFromParent()
        }
        if let anchor = faceAnchors.removeValue(forKey: anchorID) {
            anchor.removeFromParent()
        }
    }
}

// MARK: - ARSessionDelegate
extension MeshManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            currentFrame = frame

            // Update device orientation from gyroscope/accelerometer
            surfaceClassifier.updateDeviceOrientation(from: frame)
            deviceOrientation = surfaceClassifier.deviceOrientation

            // Check if edge is in reticle and detect pause (for walls mode)
            if isScanning && currentMode == .walls {
                // Only check for edges if auto-detection is enabled
                if AppSettings.shared.autoDetectionEnabled {
                    edgeInReticle = edgeVisualizer.isEdgeInReticle(frame: frame)
                } else {
                    edgeInReticle = false
                }

                // Track camera movement for pause detection
                let currentPosition = SIMD3<Float>(
                    frame.camera.transform.columns.3.x,
                    frame.camera.transform.columns.3.y,
                    frame.camera.transform.columns.3.z
                )

                if let lastPos = lastCameraPosition {
                    let movement = simd_length(currentPosition - lastPos)
                    movementSamples.append(movement)
                    if movementSamples.count > 10 {
                        movementSamples.removeFirst()
                    }

                    // Average recent movement
                    let avgMovement = movementSamples.reduce(0, +) / Float(movementSamples.count)

                    if avgMovement < pauseThreshold {
                        // Device is still
                        if pauseStartTime == nil {
                            pauseStartTime = Date()
                        } else if Date().timeIntervalSince(pauseStartTime!) >= pauseDuration {
                            if !isPaused {
                                isPaused = true
                                // Check if pause gesture is enabled
                                if AppSettings.shared.pauseGestureEnabled && !edgeConfirmed {
                                    // If auto-detection is on, require edge to be detected
                                    // If auto-detection is off, allow marking anywhere (manual mode)
                                    let shouldConfirm = !AppSettings.shared.autoDetectionEnabled || edgeInReticle

                                    if shouldConfirm {
                                        // Get the 3D position where user is looking
                                        if let cornerPosition = getReticleTargetPosition(frame: frame) {
                                            confirmCorner(at: cornerPosition, source: "pause")
                                        }
                                        edgeConfirmed = true
                                    }
                                }
                            }
                        }
                    } else {
                        // Device is moving
                        isPaused = false
                        pauseStartTime = nil
                        edgeConfirmed = false
                    }
                }
                lastCameraPosition = currentPosition
            } else {
                edgeInReticle = false
                isPaused = false
                edgeConfirmed = false
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    processMeshAnchor(meshAnchor)
                } else if let faceAnchor = anchor as? ARFaceAnchor {
                    processFaceAnchor(faceAnchor)
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    processMeshAnchor(meshAnchor)
                } else if let faceAnchor = anchor as? ARFaceAnchor {
                    processFaceAnchor(faceAnchor)
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                removeMeshVisualization(for: anchor.identifier)
                capturedScan?.meshes.removeAll { $0.identifier == anchor.identifier }
            }
        }
    }
}
