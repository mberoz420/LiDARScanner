import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Visualizes room edges as bright glowing lines during scanning
@MainActor
class EdgeVisualizer {
    // MARK: - Properties

    private weak var arView: ARView?
    private var edgeEntities: [UUID: ModelEntity] = [:]
    private var glowEntities: [UUID: ModelEntity] = [:]  // Outer glow layer
    private var edgeAnchor: AnchorEntity?

    // Edge appearance - make them VERY visible
    private let edgeThickness: Float = 0.025  // 2.5cm thick core
    private let glowThickness: Float = 0.05   // 5cm outer glow

    // MARK: - Bright Colors for visibility

    private let verticalCornerColor = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)  // Bright white
    private let verticalCornerGlow = UIColor(red: 0.8, green: 1.0, blue: 1.0, alpha: 0.5)   // Cyan glow

    private let floorEdgeColor = UIColor(red: 0.0, green: 1.0, blue: 0.8, alpha: 1.0)      // Bright teal
    private let floorEdgeGlow = UIColor(red: 0.0, green: 0.8, blue: 0.6, alpha: 0.4)       // Teal glow

    private let ceilingEdgeColor = UIColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0)    // Bright yellow
    private let ceilingEdgeGlow = UIColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 0.4)     // Yellow glow

    private let doorFrameColor = UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)      // Bright orange
    private let doorFrameGlow = UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.4)       // Orange glow

    private let windowFrameColor = UIColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)    // Bright cyan
    private let windowFrameGlow = UIColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 0.4)     // Cyan glow

    private let objectEdgeColor = UIColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)     // Bright red
    private let objectEdgeGlow = UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.4)      // Red glow

    // MARK: - Debug
    @Published var lastUpdateCount: Int = 0
    @Published var totalEdgesVisualized: Int = 0

    // MARK: - Setup

    func setup(arView: ARView) {
        self.arView = arView

        // Create a root anchor for all edge entities at world origin
        let anchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(anchor)
        edgeAnchor = anchor

        print("[EdgeVisualizer] Setup complete, anchor added to scene")
    }

    // MARK: - Edge Rendering

    /// Update edge visualization from detected edges
    func updateEdges(_ edges: [WallEdge]) {
        guard let anchor = edgeAnchor else {
            print("[EdgeVisualizer] No anchor!")
            return
        }

        lastUpdateCount = edges.count

        if edges.isEmpty {
            return
        }

        print("[EdgeVisualizer] Updating \(edges.count) edges")

        // Track which edges we've seen
        var seenIDs: Set<UUID> = []

        for edge in edges {
            seenIDs.insert(edge.id)

            if edgeEntities[edge.id] != nil {
                // Update existing edge position
                if let existing = edgeEntities[edge.id] {
                    updateEdgeEntity(existing, edge: edge)
                }
                if let existingGlow = glowEntities[edge.id] {
                    updateEdgeEntity(existingGlow, edge: edge)
                }
            } else {
                // Create new edge entity with glow
                let (coreEntity, glowEntity) = createEdgeWithGlow(for: edge)
                anchor.addChild(coreEntity)
                anchor.addChild(glowEntity)
                edgeEntities[edge.id] = coreEntity
                glowEntities[edge.id] = glowEntity

                print("[EdgeVisualizer] Created edge: \(edge.edgeType.rawValue), length: \(edge.length)")
            }
        }

        // Remove edges that are no longer detected
        for id in edgeEntities.keys {
            if !seenIDs.contains(id) {
                edgeEntities[id]?.removeFromParent()
                glowEntities[id]?.removeFromParent()
                edgeEntities.removeValue(forKey: id)
                glowEntities.removeValue(forKey: id)
            }
        }

        totalEdgesVisualized = edgeEntities.count
    }

    /// Clear all edge visualizations
    func clearEdges() {
        for (_, entity) in edgeEntities {
            entity.removeFromParent()
        }
        for (_, entity) in glowEntities {
            entity.removeFromParent()
        }
        edgeEntities.removeAll()
        glowEntities.removeAll()
        totalEdgesVisualized = 0
        print("[EdgeVisualizer] Cleared all edges")
    }

    // MARK: - Entity Creation

    private func createEdgeWithGlow(for edge: WallEdge) -> (core: ModelEntity, glow: ModelEntity) {
        let start = edge.startPoint
        let end = edge.endPoint
        let length = simd_distance(start, end)

        guard length > 0.01 else {
            // Very short edge, create minimal entity
            let mesh = MeshResource.generateBox(size: 0.02)
            var material = UnlitMaterial()
            material.color = .init(tint: .white)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = start
            return (entity, entity.clone(recursive: true))
        }

        // Core - bright solid line
        let coreMesh = MeshResource.generateBox(
            width: edgeThickness,
            height: edgeThickness,
            depth: length
        )
        var coreMaterial = UnlitMaterial()
        coreMaterial.color = .init(tint: coreColorForEdgeType(edge.edgeType))
        let coreEntity = ModelEntity(mesh: coreMesh, materials: [coreMaterial])

        // Glow - larger translucent outer layer
        let glowMesh = MeshResource.generateBox(
            width: glowThickness,
            height: glowThickness,
            depth: length
        )
        var glowMaterial = UnlitMaterial()
        glowMaterial.color = .init(tint: glowColorForEdgeType(edge.edgeType))
        let glowEntity = ModelEntity(mesh: glowMesh, materials: [glowMaterial])

        // Position and rotate both
        positionEdgeEntity(coreEntity, start: start, end: end)
        positionEdgeEntity(glowEntity, start: start, end: end)

        return (coreEntity, glowEntity)
    }

    private func updateEdgeEntity(_ entity: ModelEntity, edge: WallEdge) {
        positionEdgeEntity(entity, start: edge.startPoint, end: edge.endPoint)
    }

    private func positionEdgeEntity(_ entity: ModelEntity, start: SIMD3<Float>, end: SIMD3<Float>) {
        // Calculate midpoint
        let midpoint = (start + end) / 2

        // Calculate direction
        let diff = end - start
        let length = simd_length(diff)

        guard length > 0.001 else {
            entity.position = midpoint
            return
        }

        let direction = diff / length

        // Create rotation to align Z-axis with edge direction
        // Handle edge case where direction is close to (0,0,1) or (0,0,-1)
        let zAxis = SIMD3<Float>(0, 0, 1)
        let dot = simd_dot(zAxis, direction)

        if abs(dot) > 0.999 {
            // Nearly parallel to Z, use simpler rotation
            if dot > 0 {
                entity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            } else {
                entity.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
            }
        } else {
            entity.orientation = simd_quatf(from: zAxis, to: direction)
        }

        entity.position = midpoint
    }

    // MARK: - Colors

    private func coreColorForEdgeType(_ edgeType: WallEdge.EdgeType) -> UIColor {
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

    private func glowColorForEdgeType(_ edgeType: WallEdge.EdgeType) -> UIColor {
        switch edgeType {
        case .verticalCorner:
            return verticalCornerGlow
        case .floorWall:
            return floorEdgeGlow
        case .ceilingWall:
            return ceilingEdgeGlow
        case .doorFrame:
            return doorFrameGlow
        case .windowFrame:
            return windowFrameGlow
        case .objectEdge:
            return objectEdgeGlow
        }
    }

    /// Get count of currently visualized edges
    var edgeCount: Int {
        edgeEntities.count
    }
}
