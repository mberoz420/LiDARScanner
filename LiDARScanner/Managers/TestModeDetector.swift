import Foundation
import simd
import ARKit
import UIKit

/// Test Mode: Detect ceiling plane and wall-ceiling intersections
class TestModeDetector: ObservableObject {

    // MARK: - Published State
    @MainActor @Published var ceilingPlane: DetectedPlane?
    @MainActor @Published var wallPlanes: [DetectedPlane] = []
    @MainActor @Published var detectedEdges: [BoundaryEdge] = []
    @MainActor @Published var isPaused: Bool = false
    @MainActor @Published var isListening: Bool = false
    @MainActor @Published var isReceivingAudio: Bool = false
    @MainActor @Published var statusMessage: String = "Point at ceiling"

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
    }

    // MARK: - Configuration

    private let ceilingProximityThreshold: Float = 0.20
    private let ceilingNormalThreshold: Float = 0.8
    private let wallNormalThreshold: Float = 0.3

    // MARK: - Voice Control (placeholder for now)

    @MainActor
    func startListening() {
        isListening = true
        statusMessage = "Point at ceiling"
    }

    @MainActor
    func stopListening() {
        isListening = false
        isReceivingAudio = false
    }

    @MainActor
    func togglePause() {
        isPaused.toggle()
        if isPaused {
            statusMessage = "PAUSED - Tap to continue"
        } else {
            updateStatus()
        }
        hapticFeedback()
    }

    private func hapticFeedback() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    @MainActor
    private func updateStatus() {
        if isPaused {
            statusMessage = "PAUSED"
        } else if ceilingPlane == nil {
            statusMessage = "Point at ceiling"
        } else if wallPlanes.isEmpty {
            statusMessage = "Now scan wall edges"
        } else {
            statusMessage = "\(wallPlanes.count) walls, \(detectedEdges.count) edges"
        }
    }

    // MARK: - Frame Processing

    @MainActor
    func processFrame(_ frame: ARFrame) {
        guard !isPaused else { return }

        for anchor in frame.anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                processPlaneAnchor(planeAnchor)
            }
        }

        if ceilingPlane != nil {
            findWallCeilingIntersections()
        }

        updateStatus()
    }

    @MainActor
    private func processPlaneAnchor(_ anchor: ARPlaneAnchor) {
        let transform = anchor.transform
        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let normal = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let extent = SIMD2<Float>(anchor.planeExtent.width, anchor.planeExtent.height)

        // Detect ceiling (normal pointing down)
        if anchor.classification == .ceiling || normal.y < -ceilingNormalThreshold {
            let plane = DetectedPlane(
                id: anchor.identifier,
                center: center,
                normal: normal,
                extent: extent,
                classification: .ceiling
            )
            if ceilingPlane == nil {
                hapticFeedback()
            }
            ceilingPlane = plane
        }
        // Detect walls near ceiling
        else if anchor.classification == .wall || abs(normal.y) < wallNormalThreshold {
            if let ceiling = ceilingPlane {
                let distanceToCeiling = abs(center.y - ceiling.center.y)

                if distanceToCeiling <= ceilingProximityThreshold {
                    let plane = DetectedPlane(
                        id: anchor.identifier,
                        center: center,
                        normal: normal,
                        extent: extent,
                        classification: .wall
                    )

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

    @MainActor
    private func findWallCeilingIntersections() {
        guard let ceiling = ceilingPlane else { return }

        var newEdges: [BoundaryEdge] = []

        for wall in wallPlanes {
            if let edge = calculateIntersection(wall: wall, ceiling: ceiling) {
                newEdges.append(edge)
            }
        }

        detectedEdges = newEdges
    }

    private func calculateIntersection(wall: DetectedPlane, ceiling: DetectedPlane) -> BoundaryEdge? {
        let lineDirection = simd_cross(wall.normal, ceiling.normal)
        let lengthSq = simd_length_squared(lineDirection)

        guard lengthSq > 0.0001 else { return nil }

        let normalizedDir = simd_normalize(lineDirection)

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

        let halfLength = max(wall.extent.x, wall.extent.y) / 2.0
        let start = point - normalizedDir * halfLength
        let end = point + normalizedDir * halfLength

        return BoundaryEdge(startPoint: start, endPoint: end)
    }

    // MARK: - Reset

    @MainActor
    func reset() {
        ceilingPlane = nil
        wallPlanes = []
        detectedEdges = []
        isPaused = false
        isListening = false
        isReceivingAudio = false
        statusMessage = "Point at ceiling"
    }
}
