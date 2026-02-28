import Foundation
import RealityKit
import ARKit
import simd
import UIKit

/// Visualizes room corners as vertical glowing lines from floor to ceiling
@MainActor
class EdgeVisualizer {
    // MARK: - Properties

    private weak var arView: ARView?
    private var cornerEntities: [String: ModelEntity] = [:]  // Key: "x_z" position
    private var edgeAnchor: AnchorEntity?

    // Room dimensions (set by MeshManager)
    var floorY: Float = 0
    var ceilingY: Float = 2.5  // Default room height

    // Line appearance - thin glowing line
    private let lineThickness: Float = 0.008  // 8mm thin line

    // Bright white/cyan glow
    private let lineColor = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    private let glowColor = UIColor(red: 0.5, green: 1.0, blue: 1.0, alpha: 0.6)

    // MARK: - Setup

    func setup(arView: ARView) {
        self.arView = arView

        let anchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(anchor)
        edgeAnchor = anchor
    }

    // MARK: - Corner Visualization

    /// Add a vertical line at a corner position
    func addCorner(at position: SIMD3<Float>) {
        guard let anchor = edgeAnchor else { return }

        // Create unique key for this corner position (rounded to 10cm grid to avoid duplicates)
        let gridX = round(position.x * 10) / 10
        let gridZ = round(position.z * 10) / 10
        let key = "\(gridX)_\(gridZ)"

        // Skip if we already have a line here
        if cornerEntities[key] != nil { return }

        // Create vertical line from floor to ceiling
        let height = ceilingY - floorY
        guard height > 0.5 else { return }  // Need valid room height

        // Create thin cylinder/box for the line
        let lineMesh = MeshResource.generateBox(
            width: lineThickness,
            height: height,
            depth: lineThickness
        )

        var material = UnlitMaterial()
        material.color = .init(tint: lineColor)

        let lineEntity = ModelEntity(mesh: lineMesh, materials: [material])

        // Position at corner, centered vertically between floor and ceiling
        let centerY = floorY + height / 2
        lineEntity.position = SIMD3<Float>(position.x, centerY, position.z)

        anchor.addChild(lineEntity)
        cornerEntities[key] = lineEntity

        print("[EdgeVisualizer] Added corner line at (\(gridX), \(gridZ)), total: \(cornerEntities.count)")
    }

    /// Update from detected edges - only use vertical corners
    func updateEdges(_ edges: [WallEdge]) {
        for edge in edges {
            // Only process vertical corners
            if edge.edgeType == .verticalCorner {
                // Use the midpoint of the edge as corner position
                let midpoint = (edge.startPoint + edge.endPoint) / 2
                addCorner(at: midpoint)
            }
        }
    }

    /// Set room dimensions
    func setRoomDimensions(floor: Float, ceiling: Float) {
        let oldFloor = floorY
        let oldCeiling = ceilingY

        floorY = floor
        ceilingY = ceiling

        // Update existing lines if dimensions changed significantly
        if abs(oldFloor - floor) > 0.1 || abs(oldCeiling - ceiling) > 0.1 {
            rebuildAllLines()
        }
    }

    /// Rebuild all corner lines with current dimensions
    private func rebuildAllLines() {
        guard let anchor = edgeAnchor else { return }

        let height = ceilingY - floorY
        guard height > 0.5 else { return }

        let centerY = floorY + height / 2

        for (_, entity) in cornerEntities {
            // Update height
            let lineMesh = MeshResource.generateBox(
                width: lineThickness,
                height: height,
                depth: lineThickness
            )
            entity.model?.mesh = lineMesh

            // Update Y position
            entity.position.y = centerY
        }
    }

    /// Clear all corner visualizations
    func clearEdges() {
        for (_, entity) in cornerEntities {
            entity.removeFromParent()
        }
        cornerEntities.removeAll()
    }

    /// Get count of corner lines
    var edgeCount: Int {
        cornerEntities.count
    }

    /// Check if any edge is in the center of the screen (reticle area)
    func isEdgeInReticle(frame: ARFrame, reticleRadius: Float = 0.15) -> Bool {
        guard !cornerEntities.isEmpty else { return false }

        // Get camera position and forward direction
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let cameraForward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        // Check each corner position
        for (_, entity) in cornerEntities {
            let cornerPos = entity.position

            // Vector from camera to corner
            let toCorner = cornerPos - cameraPosition
            let distance = length(toCorner)

            // Skip if too far or too close
            if distance < 0.3 || distance > 5.0 { continue }

            // Project corner onto camera's view direction
            let projectedDistance = dot(toCorner, cameraForward)
            if projectedDistance < 0 { continue }  // Behind camera

            // Find the closest point on the camera ray to the corner
            let closestPointOnRay = cameraPosition + cameraForward * projectedDistance

            // Distance from corner to the ray (perpendicular distance)
            let perpDistance = length(cornerPos - closestPointOnRay)

            // Check if within reticle radius (scaled by distance for perspective)
            let scaledRadius = reticleRadius * (projectedDistance / 1.0)  // Scale with distance
            if perpDistance < scaledRadius {
                return true
            }
        }

        return false
    }
}
