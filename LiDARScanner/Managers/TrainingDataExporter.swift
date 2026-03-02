import Foundation
import simd

/// Exports scans as labeled training data for ML model training
@MainActor
class TrainingDataExporter: ObservableObject {

    // MARK: - Data Structures

    /// A labeled point for training
    struct LabeledPoint: Codable {
        let x: Float
        let y: Float
        let z: Float
        let nx: Float  // normal x
        let ny: Float  // normal y
        let nz: Float  // normal z
        let label: Int // 0=floor, 1=ceiling, 2=wall, 3=object
    }

    /// Training sample (one room/scan)
    struct TrainingSample: Codable {
        let id: String
        let timestamp: Date
        let pointCount: Int
        let points: [LabeledPoint]

        // Metadata
        let roomHeight: Float?
        let floorArea: Float?
        let labelCounts: [String: Int]
    }

    /// Label categories matching the ML model
    enum PointLabel: Int, CaseIterable, Codable, Sendable {
        case floor = 0
        case ceiling = 1
        case wall = 2
        case object = 3

        var name: String {
            switch self {
            case .floor: return "floor"
            case .ceiling: return "ceiling"
            case .wall: return "wall"
            case .object: return "object"
            }
        }

        static func from(surfaceType: SurfaceType) -> PointLabel {
            switch surfaceType {
            case .floor, .floorEdge:
                return .floor
            case .ceiling, .ceilingProtrusion, .cove:
                return .ceiling
            case .wall, .wallEdge:
                return .wall
            case .door, .doorFrame, .window, .windowFrame, .object, .objectTop, .backReflection, .unknown:
                return .object
            }
        }
    }

    // MARK: - Published State

    @Published var isExporting = false
    @Published var exportProgress: Float = 0
    @Published var lastExportURL: URL?
    @Published var exportedSampleCount = 0

    // MARK: - Export Methods

    /// Export a captured scan with automatic labels from surface classification
    func exportScanWithAutoLabels(_ scan: CapturedScan, classifier: SurfaceClassifier) async -> URL? {
        isExporting = true
        exportProgress = 0

        var labeledPoints: [LabeledPoint] = []
        var labelCounts: [String: Int] = [:]

        let totalMeshes = scan.meshes.count

        for (index, mesh) in scan.meshes.enumerated() {
            // Update progress
            exportProgress = Float(index) / Float(totalMeshes)

            // Classify this mesh
            let avgNormal = computeAverageNormal(mesh.normals)
            let avgY = mesh.vertices.map { $0.y }.reduce(0, +) / Float(max(mesh.vertices.count, 1))
            let surfaceType = classifier.classifySurface(averageNormal: avgNormal, worldY: avgY)
            let label = PointLabel.from(surfaceType: surfaceType)

            // Transform vertices and normals to world space
            for i in 0..<min(mesh.vertices.count, mesh.normals.count) {
                let worldPos = transformPoint(mesh.vertices[i], by: mesh.transform)
                let worldNormal = transformNormal(mesh.normals[i], by: mesh.transform)

                let point = LabeledPoint(
                    x: worldPos.x,
                    y: worldPos.y,
                    z: worldPos.z,
                    nx: worldNormal.x,
                    ny: worldNormal.y,
                    nz: worldNormal.z,
                    label: label.rawValue
                )
                labeledPoints.append(point)
                labelCounts[label.name, default: 0] += 1
            }
        }

        // Create training sample
        let sample = TrainingSample(
            id: UUID().uuidString,
            timestamp: Date(),
            pointCount: labeledPoints.count,
            points: labeledPoints,
            roomHeight: classifier.statistics.estimatedRoomHeight,
            floorArea: classifier.statistics.floorArea,
            labelCounts: labelCounts
        )

        // Save to file
        let url = saveTrainingSample(sample)

        isExporting = false
        exportProgress = 1.0
        lastExportURL = url

        if url != nil {
            exportedSampleCount += 1
        }

        return url
    }

    /// Export a scan with manual labels (from annotation)
    func exportScanWithManualLabels(_ scan: CapturedScan, labels: [UUID: PointLabel]) async -> URL? {
        isExporting = true
        exportProgress = 0

        var labeledPoints: [LabeledPoint] = []
        var labelCounts: [String: Int] = [:]

        let totalMeshes = scan.meshes.count

        for (index, mesh) in scan.meshes.enumerated() {
            exportProgress = Float(index) / Float(totalMeshes)

            // Get label for this mesh (default to object if not labeled)
            let label = labels[mesh.identifier] ?? .object

            for i in 0..<min(mesh.vertices.count, mesh.normals.count) {
                let worldPos = transformPoint(mesh.vertices[i], by: mesh.transform)
                let worldNormal = transformNormal(mesh.normals[i], by: mesh.transform)

                let point = LabeledPoint(
                    x: worldPos.x,
                    y: worldPos.y,
                    z: worldPos.z,
                    nx: worldNormal.x,
                    ny: worldNormal.y,
                    nz: worldNormal.z,
                    label: label.rawValue
                )
                labeledPoints.append(point)
                labelCounts[label.name, default: 0] += 1
            }
        }

        let sample = TrainingSample(
            id: UUID().uuidString,
            timestamp: Date(),
            pointCount: labeledPoints.count,
            points: labeledPoints,
            roomHeight: nil,
            floorArea: nil,
            labelCounts: labelCounts
        )

        let url = saveTrainingSample(sample)

        isExporting = false
        exportProgress = 1.0
        lastExportURL = url

        if url != nil {
            exportedSampleCount += 1
        }

        return url
    }

    /// Export to NumPy-compatible format (.npz style as JSON)
    func exportAsNumpyFormat(_ scan: CapturedScan, classifier: SurfaceClassifier) async -> URL? {
        isExporting = true

        var points: [[Float]] = []  // N x 6 (x,y,z,nx,ny,nz)
        var labels: [Int] = []      // N

        for mesh in scan.meshes {
            let avgNormal = computeAverageNormal(mesh.normals)
            let avgY = mesh.vertices.map { $0.y }.reduce(0, +) / Float(max(mesh.vertices.count, 1))
            let surfaceType = classifier.classifySurface(averageNormal: avgNormal, worldY: avgY)
            let label = PointLabel.from(surfaceType: surfaceType)

            for i in 0..<min(mesh.vertices.count, mesh.normals.count) {
                let worldPos = transformPoint(mesh.vertices[i], by: mesh.transform)
                let worldNormal = transformNormal(mesh.normals[i], by: mesh.transform)

                points.append([worldPos.x, worldPos.y, worldPos.z, worldNormal.x, worldNormal.y, worldNormal.z])
                labels.append(label.rawValue)
            }
        }

        // Save as JSON (can be loaded into numpy easily)
        let data: [String: Any] = [
            "points": points,
            "labels": labels,
            "num_points": points.count,
            "num_classes": 4,
            "class_names": ["floor", "ceiling", "wall", "object"]
        ]

        let url = getExportURL(filename: "training_\(Date().timeIntervalSince1970).json")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
            try jsonData.write(to: url)
            isExporting = false
            lastExportURL = url
            return url
        } catch {
            print("[TrainingDataExporter] Failed to save: \(error)")
            isExporting = false
            return nil
        }
    }

    // MARK: - Helpers

    private func saveTrainingSample(_ sample: TrainingSample) -> URL? {
        let url = getExportURL(filename: "sample_\(sample.id).json")

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(sample)
            try data.write(to: url)
            print("[TrainingDataExporter] Saved \(sample.pointCount) points to \(url.lastPathComponent)")
            return url
        } catch {
            print("[TrainingDataExporter] Failed to save: \(error)")
            return nil
        }
    }

    private func getExportURL(filename: String) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let trainingDir = documentsPath.appendingPathComponent("TrainingData", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: trainingDir, withIntermediateDirectories: true)

        return trainingDir.appendingPathComponent(filename)
    }

    private func computeAverageNormal(_ normals: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !normals.isEmpty else { return SIMD3<Float>(0, 1, 0) }
        let sum = normals.reduce(SIMD3<Float>(0, 0, 0), +)
        return simd_normalize(sum)
    }

    private func transformPoint(_ point: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let p4 = SIMD4<Float>(point.x, point.y, point.z, 1)
        let transformed = transform * p4
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    private func transformNormal(_ normal: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let n4 = SIMD4<Float>(normal.x, normal.y, normal.z, 0)
        let transformed = transform * n4
        return simd_normalize(SIMD3<Float>(transformed.x, transformed.y, transformed.z))
    }

    // MARK: - Training Data Management

    /// Get all exported training samples
    func getExportedSamples() -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let trainingDir = documentsPath.appendingPathComponent("TrainingData", isDirectory: true)

        do {
            let files = try FileManager.default.contentsOfDirectory(at: trainingDir, includingPropertiesForKeys: nil)
            return files.filter { $0.pathExtension == "json" }
        } catch {
            return []
        }
    }

    /// Delete all training data
    func clearAllTrainingData() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let trainingDir = documentsPath.appendingPathComponent("TrainingData", isDirectory: true)

        try? FileManager.default.removeItem(at: trainingDir)
        exportedSampleCount = 0
    }
}
