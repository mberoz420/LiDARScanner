import Foundation
import RealityKit
import ARKit
import simd
import UIKit

// Note: debugLog is defined in MeshManager.swift

/// Visualizes room corners as vertical glowing lines from floor to ceiling
@MainActor
class EdgeVisualizer {
    // MARK: - Properties

    private weak var arView: ARView?
    private var cornerEntities: [String: ModelEntity] = [:]  // Key: "x_z" position
    private var doorEntities: [UUID: ModelEntity] = [:]       // Door frame visualizations
    private var windowEntities: [UUID: ModelEntity] = [:]     // Window frame visualizations
    private var edgeAnchor: AnchorEntity?

    // Room dimensions (set by MeshManager)
    var floorY: Float = 0
    var ceilingY: Float = 2.5  // Default room height

    // Line appearance - thin glowing line
    private let lineThickness: Float = 0.008  // 8mm thin line
    private let frameThickness: Float = 0.02  // 2cm for door/window frames

    // Colors
    private let lineColor = UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    private let glowColor = UIColor(red: 0.5, green: 1.0, blue: 1.0, alpha: 0.6)
    private let doorColor = UIColor(red: 0.6, green: 0.3, blue: 0.1, alpha: 0.8)      // Brown
    private let windowColor = UIColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 0.6)    // Light blue

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

        debugLog("[EdgeVisualizer] Added corner line at (\(gridX), \(gridZ)), total: \(cornerEntities.count)")
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

    // MARK: - Door Visualization

    /// Add or update a door frame visualization
    func addDoor(_ door: DetectedDoor) {
        guard let anchor = edgeAnchor else { return }

        // Remove existing if updating
        if let existing = doorEntities[door.id] {
            existing.removeFromParent()
        }

        // Create door frame as a rectangular outline
        let frameEntity = createDoorFrame(door: door)
        anchor.addChild(frameEntity)
        doorEntities[door.id] = frameEntity

        debugLog("[EdgeVisualizer] Added door at (\(door.position.x), \(door.position.z)), total: \(doorEntities.count)")
    }

    /// Create a door frame entity (rectangular outline)
    private func createDoorFrame(door: DetectedDoor) -> ModelEntity {
        // Door frame is a rectangle: two vertical sides + top
        let parentEntity = ModelEntity()

        var material = UnlitMaterial()
        material.color = .init(tint: door.isConfirmed ? doorColor : doorColor.withAlphaComponent(0.4))

        // Calculate door orientation from wall normal
        let angle = atan2(door.wallNormal.x, door.wallNormal.z)

        // Left vertical post
        let leftPost = MeshResource.generateBox(width: frameThickness, height: door.height, depth: frameThickness)
        let leftEntity = ModelEntity(mesh: leftPost, materials: [material])
        leftEntity.position = SIMD3<Float>(-door.width / 2, door.height / 2, 0)
        parentEntity.addChild(leftEntity)

        // Right vertical post
        let rightEntity = ModelEntity(mesh: leftPost, materials: [material])
        rightEntity.position = SIMD3<Float>(door.width / 2, door.height / 2, 0)
        parentEntity.addChild(rightEntity)

        // Top horizontal beam
        let topBeam = MeshResource.generateBox(width: door.width + frameThickness, height: frameThickness, depth: frameThickness)
        let topEntity = ModelEntity(mesh: topBeam, materials: [material])
        topEntity.position = SIMD3<Float>(0, door.height, 0)
        parentEntity.addChild(topEntity)

        // Position and rotate the frame
        parentEntity.position = SIMD3<Float>(door.position.x, floorY, door.position.z)
        parentEntity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))

        return parentEntity
    }

    /// Update doors from detected doors list
    func updateDoors(_ doors: [DetectedDoor]) {
        // Remove doors that no longer exist
        let currentIDs = Set(doors.map { $0.id })
        for (id, entity) in doorEntities where !currentIDs.contains(id) {
            entity.removeFromParent()
            doorEntities.removeValue(forKey: id)
        }

        // Add/update doors
        for door in doors {
            addDoor(door)
        }
    }

    // MARK: - Window Visualization

    /// Add or update a window frame visualization
    func addWindow(_ window: DetectedWindow) {
        guard let anchor = edgeAnchor else { return }

        // Remove existing if updating
        if let existing = windowEntities[window.id] {
            existing.removeFromParent()
        }

        // Create window frame as a rectangular outline with glass effect
        let frameEntity = createWindowFrame(window: window)
        anchor.addChild(frameEntity)
        windowEntities[window.id] = frameEntity

        debugLog("[EdgeVisualizer] Added window at (\(window.position.x), \(window.position.z)), total: \(windowEntities.count)")
    }

    /// Create a window frame entity (rectangular outline with glass)
    private func createWindowFrame(window: DetectedWindow) -> ModelEntity {
        let parentEntity = ModelEntity()

        var frameMaterial = UnlitMaterial()
        frameMaterial.color = .init(tint: UIColor.gray)

        var glassMaterial = UnlitMaterial()
        glassMaterial.color = .init(tint: window.isConfirmed ? windowColor : windowColor.withAlphaComponent(0.3))

        // Calculate window orientation from wall normal
        let angle = atan2(window.wallNormal.x, window.wallNormal.z)

        // Four frame posts
        let verticalPost = MeshResource.generateBox(width: frameThickness, height: window.height, depth: frameThickness)
        let horizontalPost = MeshResource.generateBox(width: window.width + frameThickness, height: frameThickness, depth: frameThickness)

        // Left post
        let leftEntity = ModelEntity(mesh: verticalPost, materials: [frameMaterial])
        leftEntity.position = SIMD3<Float>(-window.width / 2, window.height / 2, 0)
        parentEntity.addChild(leftEntity)

        // Right post
        let rightEntity = ModelEntity(mesh: verticalPost, materials: [frameMaterial])
        rightEntity.position = SIMD3<Float>(window.width / 2, window.height / 2, 0)
        parentEntity.addChild(rightEntity)

        // Top post
        let topEntity = ModelEntity(mesh: horizontalPost, materials: [frameMaterial])
        topEntity.position = SIMD3<Float>(0, window.height, 0)
        parentEntity.addChild(topEntity)

        // Bottom post (sill)
        let bottomEntity = ModelEntity(mesh: horizontalPost, materials: [frameMaterial])
        bottomEntity.position = SIMD3<Float>(0, 0, 0)
        parentEntity.addChild(bottomEntity)

        // Glass pane (semi-transparent)
        if window.hasGlass {
            let glassMesh = MeshResource.generateBox(width: window.width - frameThickness, height: window.height - frameThickness, depth: 0.005)
            let glassEntity = ModelEntity(mesh: glassMesh, materials: [glassMaterial])
            glassEntity.position = SIMD3<Float>(0, window.height / 2, 0)
            parentEntity.addChild(glassEntity)
        }

        // Position and rotate the frame
        parentEntity.position = SIMD3<Float>(window.position.x, floorY + window.heightFromFloor, window.position.z)
        parentEntity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))

        return parentEntity
    }

    /// Update windows from detected windows list
    func updateWindows(_ windows: [DetectedWindow]) {
        // Remove windows that no longer exist
        let currentIDs = Set(windows.map { $0.id })
        for (id, entity) in windowEntities where !currentIDs.contains(id) {
            entity.removeFromParent()
            windowEntities.removeValue(forKey: id)
        }

        // Add/update windows
        for window in windows {
            addWindow(window)
        }
    }

    // MARK: - Room Dimensions

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

    /// Clear all visualizations
    func clearEdges() {
        for (_, entity) in cornerEntities {
            entity.removeFromParent()
        }
        cornerEntities.removeAll()

        for (_, entity) in doorEntities {
            entity.removeFromParent()
        }
        doorEntities.removeAll()

        for (_, entity) in windowEntities {
            entity.removeFromParent()
        }
        windowEntities.removeAll()
    }

    /// Get count of corner lines
    var edgeCount: Int {
        cornerEntities.count
    }

    /// Get count of doors
    var doorCount: Int {
        doorEntities.count
    }

    /// Get count of windows
    var windowCount: Int {
        windowEntities.count
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
