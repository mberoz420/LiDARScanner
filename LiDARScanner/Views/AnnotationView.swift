import SwiftUI
import RealityKit
import simd

/// View for manually labeling scan meshes for ML training
struct AnnotationView: View {
    let scan: CapturedScan
    @StateObject private var exporter = TrainingDataExporter()
    @Environment(\.dismiss) private var dismiss

    // Annotation state
    @State private var meshLabels: [UUID: TrainingDataExporter.PointLabel] = [:]
    @State private var selectedMeshId: UUID?
    @State private var currentLabelTool: TrainingDataExporter.PointLabel = .wall
    @State private var isExporting = false
    @State private var exportSuccess = false
    @State private var showExportAlert = false

    // Stats
    private var labelStats: [String: Int] {
        var stats: [String: Int] = [:]
        for label in meshLabels.values {
            stats[label.name, default: 0] += 1
        }
        return stats
    }

    private var totalMeshes: Int {
        scan.meshes.count
    }

    private var labeledMeshes: Int {
        meshLabels.count
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 3D Preview with tap to select
                AnnotationPreviewView(
                    scan: scan,
                    meshLabels: meshLabels,
                    selectedMeshId: $selectedMeshId,
                    onMeshTapped: { meshId in
                        // Apply current label tool
                        meshLabels[meshId] = currentLabelTool
                        selectedMeshId = meshId
                    }
                )
                .frame(maxHeight: .infinity)

                // Label tool selector
                VStack(spacing: 12) {
                    // Progress
                    HStack {
                        Text("Labeled: \(labeledMeshes)/\(totalMeshes) meshes")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        // Quick stats
                        HStack(spacing: 8) {
                            ForEach(TrainingDataExporter.PointLabel.allCases, id: \.rawValue) { label in
                                HStack(spacing: 2) {
                                    Circle()
                                        .fill(colorFor(label))
                                        .frame(width: 8, height: 8)
                                    Text("\(labelStats[label.name] ?? 0)")
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Label buttons
                    HStack(spacing: 12) {
                        ForEach(TrainingDataExporter.PointLabel.allCases, id: \.rawValue) { label in
                            LabelToolButton(
                                label: label,
                                isSelected: currentLabelTool == label,
                                color: colorFor(label)
                            ) {
                                currentLabelTool = label
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Quick actions
                    HStack(spacing: 16) {
                        Button(action: autoLabelAll) {
                            Label("Auto-Label All", systemImage: "wand.and.stars")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)

                        Button(action: clearLabels) {
                            Label("Clear", systemImage: "trash")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Spacer()

                        Button(action: exportTrainingData) {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(meshLabels.isEmpty || isExporting)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
            }
            .navigationTitle("Annotate Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Export Complete", isPresented: $showExportAlert) {
                Button("OK") {
                    if exportSuccess {
                        dismiss()
                    }
                }
            } message: {
                if exportSuccess {
                    Text("Training data saved! You can find it in the app's Documents/TrainingData folder.")
                } else {
                    Text("Failed to export training data.")
                }
            }
        }
    }

    // MARK: - Actions

    private func autoLabelAll() {
        // Use geometric heuristics to auto-label
        let classifier = SurfaceClassifier()

        for mesh in scan.meshes {
            let avgNormal = computeAverageNormal(mesh.normals)
            let avgY = mesh.vertices.map { $0.y }.reduce(0, +) / Float(max(mesh.vertices.count, 1))
            let surfaceType = classifier.classifySurface(averageNormal: avgNormal, worldY: avgY)
            let label = TrainingDataExporter.PointLabel.from(surfaceType: surfaceType)
            meshLabels[mesh.identifier] = label
        }
    }

    private func clearLabels() {
        meshLabels.removeAll()
        selectedMeshId = nil
    }

    private func exportTrainingData() {
        isExporting = true

        Task {
            let url = await exporter.exportScanWithManualLabels(scan, labels: meshLabels)

            await MainActor.run {
                isExporting = false
                exportSuccess = url != nil
                showExportAlert = true
            }
        }
    }

    private func colorFor(_ label: TrainingDataExporter.PointLabel) -> Color {
        switch label {
        case .floor: return .green
        case .ceiling: return .yellow
        case .wall: return .blue
        case .object: return .red
        }
    }

    private func computeAverageNormal(_ normals: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !normals.isEmpty else { return SIMD3<Float>(0, 1, 0) }
        let sum = normals.reduce(SIMD3<Float>(0, 0, 0), +)
        return simd_normalize(sum)
    }
}

// MARK: - Label Tool Button

struct LabelToolButton: View {
    let label: TrainingDataExporter.PointLabel
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: iconFor(label))
                    .font(.title3)
                Text(label.name.capitalized)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? color.opacity(0.3) : Color.gray.opacity(0.1))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 2)
            )
        }
        .foregroundColor(isSelected ? color : .primary)
    }

    private func iconFor(_ label: TrainingDataExporter.PointLabel) -> String {
        switch label {
        case .floor: return "square.fill"
        case .ceiling: return "square.tophalf.filled"
        case .wall: return "rectangle.portrait.fill"
        case .object: return "cube.fill"
        }
    }
}

// MARK: - 3D Preview View

struct AnnotationPreviewView: UIViewRepresentable {
    let scan: CapturedScan
    let meshLabels: [UUID: TrainingDataExporter.PointLabel]
    @Binding var selectedMeshId: UUID?
    let onMeshTapped: (UUID) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(.darkGray)

        // Add tap gesture
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)

        context.coordinator.arView = arView
        context.coordinator.loadMeshes(scan: scan, labels: meshLabels)

        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.updateColors(labels: meshLabels, selectedId: selectedMeshId)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onMeshTapped: onMeshTapped)
    }

    class Coordinator {
        var arView: ARView?
        var meshEntities: [UUID: ModelEntity] = [:]
        var meshAnchor: AnchorEntity?
        let onMeshTapped: (UUID) -> Void

        init(onMeshTapped: @escaping (UUID) -> Void) {
            self.onMeshTapped = onMeshTapped
        }

        func loadMeshes(scan: CapturedScan, labels: [UUID: TrainingDataExporter.PointLabel]) {
            guard let arView = arView else { return }

            // Create anchor
            let anchor = AnchorEntity(world: .zero)
            meshAnchor = anchor

            // Calculate center for camera positioning
            var allVertices: [SIMD3<Float>] = []

            for mesh in scan.meshes {
                // Create mesh entity
                if let entity = createMeshEntity(from: mesh, label: labels[mesh.identifier]) {
                    meshEntities[mesh.identifier] = entity
                    anchor.addChild(entity)

                    // Collect vertices for bounds
                    for vertex in mesh.vertices {
                        let worldPos = mesh.transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
                        allVertices.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
                    }
                }
            }

            arView.scene.addAnchor(anchor)

            // Position camera to see the whole scan
            if !allVertices.isEmpty {
                let center = allVertices.reduce(.zero, +) / Float(allVertices.count)
                let bounds = computeBounds(allVertices)
                let maxDim = max(bounds.x, max(bounds.y, bounds.z))

                // Create a camera anchor looking at the center
                let cameraPos = center + SIMD3<Float>(0, maxDim * 0.5, maxDim * 1.5)
                let cameraAnchor = AnchorEntity(world: cameraPos)
                arView.scene.addAnchor(cameraAnchor)
            }
        }

        func createMeshEntity(from mesh: CapturedMeshData, label: TrainingDataExporter.PointLabel?) -> ModelEntity? {
            guard !mesh.vertices.isEmpty else { return nil }

            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []

            // Transform vertices
            for i in 0..<mesh.vertices.count {
                let worldPos = mesh.transform * SIMD4<Float>(mesh.vertices[i].x, mesh.vertices[i].y, mesh.vertices[i].z, 1)
                positions.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))

                if i < mesh.normals.count {
                    let worldNormal = mesh.transform * SIMD4<Float>(mesh.normals[i].x, mesh.normals[i].y, mesh.normals[i].z, 0)
                    normals.append(simd_normalize(SIMD3<Float>(worldNormal.x, worldNormal.y, worldNormal.z)))
                } else {
                    normals.append(SIMD3<Float>(0, 1, 0))
                }
            }

            // Create mesh descriptor
            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)

            // Create triangle indices
            var indices: [UInt32] = []
            for face in mesh.faces {
                if face.count >= 3 {
                    indices.append(contentsOf: face.prefix(3))
                }
            }
            descriptor.primitives = .triangles(indices)

            guard let meshResource = try? MeshResource.generate(from: [descriptor]) else {
                return nil
            }

            var material = SimpleMaterial()
            material.color = .init(tint: colorFor(label).withAlphaComponent(0.6))
            material.metallic = 0
            material.roughness = 0.8

            let entity = ModelEntity(mesh: meshResource, materials: [material])
            entity.name = mesh.identifier.uuidString

            // Enable collision for tap detection
            entity.generateCollisionShapes(recursive: false)

            return entity
        }

        func updateColors(labels: [UUID: TrainingDataExporter.PointLabel], selectedId: UUID?) {
            for (id, entity) in meshEntities {
                let label = labels[id]
                let isSelected = id == selectedId

                var material = SimpleMaterial()
                let baseColor = colorFor(label)
                material.color = .init(tint: isSelected ? baseColor : baseColor.withAlphaComponent(0.6))
                material.metallic = 0
                material.roughness = isSelected ? 0.5 : 0.8

                entity.model?.materials = [material]
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }

            let location = gesture.location(in: arView)

            // Ray cast to find tapped mesh
            if let entity = arView.entity(at: location) as? ModelEntity,
               let meshId = UUID(uuidString: entity.name) {
                onMeshTapped(meshId)
            }
        }

        private func colorFor(_ label: TrainingDataExporter.PointLabel?) -> UIColor {
            switch label {
            case .floor: return .green
            case .ceiling: return .yellow
            case .wall: return .blue
            case .object: return .red
            case .none: return .gray
            }
        }

        private func computeBounds(_ vertices: [SIMD3<Float>]) -> SIMD3<Float> {
            guard !vertices.isEmpty else { return .zero }
            var minV = vertices[0]
            var maxV = vertices[0]
            for v in vertices {
                minV = min(minV, v)
                maxV = max(maxV, v)
            }
            return maxV - minV
        }
    }
}

#Preview {
    AnnotationView(scan: CapturedScan(startTime: Date()))
}
