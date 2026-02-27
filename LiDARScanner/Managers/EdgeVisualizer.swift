import Foundation
import RealityKit
import ARKit
import simd

/// Visualizes room edges as glowing lines instead of mesh overlays
@MainActor
class EdgeVisualizer {
    // MARK: - Properties

    private weak var arView: ARView?
    private var edgeEntities: [UUID: ModelEntity] = [:]
    private var edgeAnchor: AnchorEntity?

    // Edge appearance
    private let edgeThickness: Float = 0.015  // 1.5cm thick lines
    private let glowThickness: Float = 0.025  // Outer glow layer

    // MARK: - Colors (using WallEdge.EdgeType from SurfaceClassifier)

    private let verticalCornerColor = UIColor.white
    private let floorEdgeColor = UIColor(red: 0, green: 0.8, blue: 0.5, alpha: 0.9)  // Teal
    private let ceilingEdgeColor = UIColor(red: 1.0, green: 0.9, blue: 0.2, alpha: 0.9)  // Yellow
    private let doorFrameColor = UIColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 0.9)  // Brown
    private let windowFrameColor = UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.9)  // Light blue
    private let objectEdgeColor = UIColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.8)  // Red

    // MARK: - Setup

    func setup(arView: ARView) {
        self.arView = arView

        // Create a root anchor for all edge entities
        edgeAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(edgeAnchor!)
    }

    // MARK: - Edge Rendering

    /// Update edge visualization from detected edges
    func updateEdges(_ edges: [WallEdge]) {
        guard let anchor = edgeAnchor else { return }

        // Track which edges we've seen
        var seenIDs: Set<UUID> = []

        for edge in edges {
            seenIDs.insert(edge.id)

            if let existing = edgeEntities[edge.id] {
                // Update position if needed
                updateEdgeEntity(existing, edge: edge)
            } else {
                // Create new edge entity
                let entity = createEdgeEntity(for: edge)
                anchor.addChild(entity)
                edgeEntities[edge.id] = entity
            }
        }

        // Remove edges that are no longer detected
        for (id, entity) in edgeEntities {
            if !seenIDs.contains(id) {
                entity.removeFromParent()
                edgeEntities.removeValue(forKey: id)
            }
        }
    }

    /// Clear all edge visualizations
    func clearEdges() {
        for (_, entity) in edgeEntities {
            entity.removeFromParent()
        }
        edgeEntities.removeAll()
    }

    // MARK: - Entity Creation

    private func createEdgeEntity(for edge: WallEdge) -> ModelEntity {
        let start = edge.startPoint
        let end = edge.endPoint
        let length = simd_distance(start, end)

        // Create thin box stretched along the edge
        let mesh = MeshResource.generateBox(
            width: edgeThickness,
            height: edgeThickness,
            depth: length
        )

        // Create glowing material
        var material = UnlitMaterial()
        material.color = .init(tint: colorForEdgeType(edge.edgeType))

        let entity = ModelEntity(mesh: mesh, materials: [material])

        // Position and rotate to align with edge
        positionEdgeEntity(entity, start: start, end: end)

        return entity
    }

    private func updateEdgeEntity(_ entity: ModelEntity, edge: WallEdge) {
        positionEdgeEntity(entity, start: edge.startPoint, end: edge.endPoint)
    }

    private func positionEdgeEntity(_ entity: ModelEntity, start: SIMD3<Float>, end: SIMD3<Float>) {
        // Calculate midpoint
        let midpoint = (start + end) / 2

        // Calculate direction and rotation
        let direction = normalize(end - start)

        // Create rotation to align Z-axis with edge direction
        let rotation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: direction)

        entity.position = midpoint
        entity.orientation = rotation
    }

    /// Color for edge type (uses WallEdge.EdgeType from SurfaceClassifier)
    private func colorForEdgeType(_ edgeType: WallEdge.EdgeType) -> UIColor {
        switch edgeType {
        case .verticalCorner:
            return verticalCornerColor
        case .floorWall:
            return floorEdgeColor
        case .ceilingWall:
            return ceilingEdgeColor
        case .doorFrame:
            return doorFrameColor
        case .windowFrame:
            return windowFrameColor
        case .objectEdge:
            return objectEdgeColor
        }
    }

    // MARK: - Room Dimension Overlay

    /// Create dimension labels for room measurements
    func showRoomDimensions(
        width: Float,
        depth: Float,
        height: Float,
        floorCenter: SIMD3<Float>
    ) {
        // This would create text entities showing dimensions
        // For now, dimensions are shown in the UI overlay
    }
}
