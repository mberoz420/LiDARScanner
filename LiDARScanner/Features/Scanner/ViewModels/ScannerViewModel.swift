import SwiftUI
import ARKit
import RealityKit
import Combine

@MainActor
class ScannerViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var isScanning = false
    @Published var isProcessing = false
    @Published var processingMessage = ""
    @Published var scanProgress: Float = 0
    @Published var showBoundingBox = false
    @Published var error: Error?

    @Published var capturedMesh: MeshData?
    @Published var currentMetrics: ObjectMetrics?
    @Published var capturedImage: Data?

    @Published var identificationResults: [IdentificationResult]?
    @Published var identificationComplete = false

    // MARK: - Services
    private let lidarCapture = LiDARCapture()
    private let dimensionExtractor = DimensionExtractor()
    private let objectIdentifier = ObjectIdentifier()

    // MARK: - Private Properties
    private var arView: ARView?
    private var boundingBoxEntity: ModelEntity?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties
    var canReset: Bool {
        isScanning || capturedMesh != nil
    }

    // MARK: - Initialization
    init() {
        setupBindings()
    }

    private func setupBindings() {
        lidarCapture.$isScanning
            .assign(to: &$isScanning)

        lidarCapture.$scanProgress
            .assign(to: &$scanProgress)

        lidarCapture.$error
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.error = error
            }
            .store(in: &cancellables)
    }

    // MARK: - AR Setup
    func setupARView(_ arView: ARView) {
        self.arView = arView
    }

    // MARK: - Scanning Control
    func toggleScanning() {
        if isScanning {
            stopScanning()
        } else {
            startScanning()
        }
    }

    func startScanning() {
        guard let arView = arView else { return }

        // Clear previous capture
        capturedMesh = nil
        currentMetrics = nil
        capturedImage = nil
        identificationResults = nil
        identificationComplete = false

        lidarCapture.startScanning(session: arView.session)
    }

    func stopScanning() {
        isProcessing = true
        processingMessage = "Processing scan..."

        Task {
            // Stop scanning and get mesh anchors
            let anchors = lidarCapture.stopScanning()

            // Extract mesh data
            guard let meshData = lidarCapture.extractMeshData(from: anchors) else {
                isProcessing = false
                error = LiDARError.meshExtractionFailed
                return
            }

            capturedMesh = meshData

            // Extract dimensions
            processingMessage = "Calculating dimensions..."
            let metrics = dimensionExtractor.extractMetrics(from: meshData)
            currentMetrics = metrics

            // Capture image for identification
            if let arView = arView {
                capturedImage = captureScreenshot(from: arView)
            }

            isProcessing = false
        }
    }

    func reset() {
        lidarCapture.resetScanning()
        capturedMesh = nil
        currentMetrics = nil
        capturedImage = nil
        identificationResults = nil
        identificationComplete = false
        showBoundingBox = false
        removeBoundingBoxVisualization()
    }

    // MARK: - Object Identification
    func identifyObject() async {
        guard let metrics = currentMetrics else { return }

        isProcessing = true
        processingMessage = "Identifying object..."

        do {
            let results = try await objectIdentifier.identify(
                metrics: metrics,
                image: capturedImage
            )

            identificationResults = results
            identificationComplete = true
        } catch {
            self.error = error
        }

        isProcessing = false
    }

    // MARK: - Export
    func exportMesh(format: ExportFormat, filename: String) async -> URL? {
        guard let meshData = capturedMesh else { return nil }

        do {
            switch format {
            case .obj:
                return try MeshExporter.exportToOBJ(meshData: meshData, filename: filename)
            case .stl:
                return try MeshExporter.exportToSTL(meshData: meshData, filename: filename)
            case .usdz:
                return try MeshExporter.exportToUSDZ(meshData: meshData, filename: filename)
            }
        } catch {
            self.error = error
            return nil
        }
    }

    // MARK: - Bounding Box
    func updateBoundingBoxVisualization(in arView: ARView) {
        guard showBoundingBox else {
            removeBoundingBoxVisualization()
            return
        }

        // Create or update bounding box entity
        if boundingBoxEntity == nil {
            let boxMesh = MeshResource.generateBox(size: 0.3)
            var material = SimpleMaterial()
            material.color = .init(tint: .blue.withAlphaComponent(0.3))
            boundingBoxEntity = ModelEntity(mesh: boxMesh, materials: [material])

            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(boundingBoxEntity!)
            arView.scene.addAnchor(anchor)
        }

        // Position at camera center
        if let cameraTransform = arView.session.currentFrame?.camera.transform {
            let forward = SIMD3<Float>(
                -cameraTransform.columns.2.x,
                -cameraTransform.columns.2.y,
                -cameraTransform.columns.2.z
            )
            let position = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            ) + forward * 0.5

            boundingBoxEntity?.position = position

            // Update LiDAR capture bounding box
            lidarCapture.setBoundingBox(center: position, extent: SIMD3<Float>(0.3, 0.3, 0.3))
        }
    }

    func removeBoundingBoxVisualization() {
        boundingBoxEntity?.removeFromParent()
        boundingBoxEntity = nil
    }

    // MARK: - Screenshot
    private func captureScreenshot(from arView: ARView) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: arView.bounds.size)
        let image = renderer.image { _ in
            arView.drawHierarchy(in: arView.bounds, afterScreenUpdates: true)
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    // MARK: - Error Handling
    func dismissError() {
        error = nil
    }
}
