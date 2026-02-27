import Foundation
import simd
import SwiftUI

/// A single room scan with its detected features
struct RoomScan: Identifiable {
    let id: UUID
    var name: String
    var capturedScan: CapturedScan
    var doors: [LabeledDoor]
    var windows: [DetectedWindow]
    var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var floorArea: Float
    var transform: simd_float4x4  // Transform to align with other rooms
    var isAligned: Bool = false

    init(name: String, capturedScan: CapturedScan, statistics: ScanStatistics?) {
        self.id = UUID()
        self.name = name
        self.capturedScan = capturedScan
        self.doors = statistics?.detectedDoors.map { LabeledDoor(door: $0) } ?? []
        self.windows = statistics?.detectedWindows ?? []
        self.floorArea = statistics?.floorArea ?? 0
        self.transform = matrix_identity_float4x4

        // Calculate bounding box from meshes
        self.boundingBox = Self.calculateBoundingBox(from: capturedScan.meshes)
    }

    static func calculateBoundingBox(from meshes: [CapturedMeshData]) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard !meshes.isEmpty else { return nil }

        var minBound = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBound = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        for mesh in meshes {
            for vertex in mesh.vertices {
                let worldVertex = transformPoint(vertex, by: mesh.transform)
                minBound = min(minBound, worldVertex)
                maxBound = max(maxBound, worldVertex)
            }
        }

        return (minBound, maxBound)
    }

    private static func transformPoint(_ point: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let p4 = SIMD4<Float>(point.x, point.y, point.z, 1)
        let transformed = transform * p4
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}

/// A door with user-assigned label for matching across rooms
struct LabeledDoor: Identifiable {
    let id: UUID
    var label: String           // User-assigned label (e.g., "Kitchen-Living", "Door A")
    var door: DetectedDoor
    var connectedRoomId: UUID?  // ID of room on other side
    var wallSide: WallSide      // Which side of wall this door is on

    enum WallSide: String {
        case front = "Front"
        case back = "Back"
    }

    init(door: DetectedDoor, label: String = "") {
        self.id = UUID()
        self.door = door
        self.label = label
        self.wallSide = .front
    }
}

/// Door pair for alignment (same door seen from two rooms)
struct DoorPair {
    let doorLabel: String
    let room1Id: UUID
    let room1Door: LabeledDoor
    let room2Id: UUID
    let room2Door: LabeledDoor
}

/// Multi-room scan session
@MainActor
class MultiRoomManager: ObservableObject {
    // MARK: - Published State
    @Published var rooms: [RoomScan] = []
    @Published var currentRoomIndex: Int = 0
    @Published var doorPairs: [DoorPair] = []
    @Published var isAligned: Bool = false
    @Published var wallThickness: Float = 0.15  // Default 15cm wall thickness
    @Published var alignmentStatus: String = ""

    // Combined floor plan after alignment
    @Published var combinedBoundingBox: (min: SIMD3<Float>, max: SIMD3<Float>)?
    @Published var totalFloorArea: Float = 0

    // MARK: - Room Management

    /// Add a new room scan to the session
    func addRoom(name: String, scan: CapturedScan, statistics: ScanStatistics?) {
        let room = RoomScan(name: name, capturedScan: scan, statistics: statistics)
        rooms.append(room)
        currentRoomIndex = rooms.count - 1
        alignmentStatus = "Room '\(name)' added. Label doors to align with other rooms."
    }

    /// Get current room being edited
    var currentRoom: RoomScan? {
        guard currentRoomIndex >= 0 && currentRoomIndex < rooms.count else { return nil }
        return rooms[currentRoomIndex]
    }

    /// Label a door in a room
    func labelDoor(roomId: UUID, doorId: UUID, label: String) {
        guard let roomIndex = rooms.firstIndex(where: { $0.id == roomId }),
              let doorIndex = rooms[roomIndex].doors.firstIndex(where: { $0.id == doorId }) else {
            return
        }

        rooms[roomIndex].doors[doorIndex].label = label

        // Check if this creates a door pair
        findDoorPairs()
    }

    /// Set which side of the wall a door is on
    func setDoorSide(roomId: UUID, doorId: UUID, side: LabeledDoor.WallSide) {
        guard let roomIndex = rooms.firstIndex(where: { $0.id == roomId }),
              let doorIndex = rooms[roomIndex].doors.firstIndex(where: { $0.id == doorId }) else {
            return
        }

        rooms[roomIndex].doors[doorIndex].wallSide = side
    }

    // MARK: - Door Pair Detection

    /// Find doors with matching labels across different rooms
    private func findDoorPairs() {
        doorPairs.removeAll()

        // Group doors by label
        var doorsByLabel: [String: [(roomId: UUID, door: LabeledDoor)]] = [:]

        for room in rooms {
            for door in room.doors where !door.label.isEmpty {
                doorsByLabel[door.label, default: []].append((room.id, door))
            }
        }

        // Create pairs for labels that appear in exactly 2 rooms
        for (label, doors) in doorsByLabel {
            if doors.count == 2 && doors[0].roomId != doors[1].roomId {
                let pair = DoorPair(
                    doorLabel: label,
                    room1Id: doors[0].roomId,
                    room1Door: doors[0].door,
                    room2Id: doors[1].roomId,
                    room2Door: doors[1].door
                )
                doorPairs.append(pair)
            }
        }

        alignmentStatus = "Found \(doorPairs.count) door pairs for alignment"
    }

    // MARK: - Alignment

    /// Align all rooms using door pairs
    func alignRooms() {
        guard !doorPairs.isEmpty else {
            alignmentStatus = "No door pairs found. Label matching doors with the same name."
            return
        }

        // Start with first room as reference (identity transform)
        guard !rooms.isEmpty else { return }
        rooms[0].transform = matrix_identity_float4x4
        rooms[0].isAligned = true

        var alignedRoomIds: Set<UUID> = [rooms[0].id]
        var iterations = 0
        let maxIterations = rooms.count * 2  // Prevent infinite loop

        // Iteratively align rooms using door pairs
        while alignedRoomIds.count < rooms.count && iterations < maxIterations {
            iterations += 1

            for pair in doorPairs {
                let room1Aligned = alignedRoomIds.contains(pair.room1Id)
                let room2Aligned = alignedRoomIds.contains(pair.room2Id)

                if room1Aligned && !room2Aligned {
                    // Align room2 to room1
                    alignRoom(pair.room2Id, toRoom: pair.room1Id, using: pair)
                    alignedRoomIds.insert(pair.room2Id)
                } else if room2Aligned && !room1Aligned {
                    // Align room1 to room2
                    alignRoom(pair.room1Id, toRoom: pair.room2Id, using: pair)
                    alignedRoomIds.insert(pair.room1Id)
                }
            }
        }

        // Update alignment status
        let alignedCount = rooms.filter { $0.isAligned }.count
        isAligned = alignedCount == rooms.count

        if isAligned {
            alignmentStatus = "All \(rooms.count) rooms aligned successfully!"
            calculateCombinedBounds()
        } else {
            alignmentStatus = "\(alignedCount)/\(rooms.count) rooms aligned. Add more door labels to connect remaining rooms."
        }
    }

    /// Align one room to another using a door pair
    private func alignRoom(_ roomToAlignId: UUID, toRoom referenceRoomId: UUID, using pair: DoorPair) {
        guard let roomToAlignIndex = rooms.firstIndex(where: { $0.id == roomToAlignId }),
              let referenceRoomIndex = rooms.firstIndex(where: { $0.id == referenceRoomId }) else {
            return
        }

        let referenceRoom = rooms[referenceRoomIndex]

        // Get door positions
        let refDoor = pair.room1Id == referenceRoomId ? pair.room1Door : pair.room2Door
        let alignDoor = pair.room1Id == roomToAlignId ? pair.room1Door : pair.room2Door

        // Calculate the transform to align the doors
        // Door positions are relative to their room's coordinate system
        let refDoorWorldPos = transformPoint(refDoor.door.position, by: referenceRoom.transform)
        let alignDoorLocalPos = alignDoor.door.position

        // Account for wall thickness - doors on opposite sides are offset
        var wallOffset = SIMD3<Float>(0, 0, 0)
        if refDoor.wallSide != alignDoor.wallSide {
            // Offset along the wall normal by wall thickness
            wallOffset = refDoor.door.wallNormal * wallThickness
        }

        // The door in the room to align should end up at refDoorWorldPos + wallOffset
        // But facing the opposite direction (180° rotation around Y)

        // Calculate translation
        let targetPos = refDoorWorldPos + wallOffset

        // Create rotation matrix (180° around Y to flip the room)
        let rotationY = simd_float4x4(
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, -1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        // Rotate door position
        let rotatedDoorPos = transformPoint(alignDoorLocalPos, by: rotationY)

        // Calculate translation to move rotated door to target
        let translation = targetPos - rotatedDoorPos
        let translationMatrix = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        )

        // Combined transform: first rotate, then translate
        rooms[roomToAlignIndex].transform = translationMatrix * rotationY
        rooms[roomToAlignIndex].isAligned = true
    }

    private func transformPoint(_ point: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let p4 = SIMD4<Float>(point.x, point.y, point.z, 1)
        let transformed = transform * p4
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    /// Calculate combined bounding box after alignment
    private func calculateCombinedBounds() {
        var minBound = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBound = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        totalFloorArea = 0

        for room in rooms where room.isAligned {
            if let roomBounds = room.boundingBox {
                // Transform room bounds to aligned space
                let corners = [
                    SIMD3<Float>(roomBounds.min.x, roomBounds.min.y, roomBounds.min.z),
                    SIMD3<Float>(roomBounds.max.x, roomBounds.min.y, roomBounds.min.z),
                    SIMD3<Float>(roomBounds.min.x, roomBounds.max.y, roomBounds.min.z),
                    SIMD3<Float>(roomBounds.max.x, roomBounds.max.y, roomBounds.min.z),
                    SIMD3<Float>(roomBounds.min.x, roomBounds.min.y, roomBounds.max.z),
                    SIMD3<Float>(roomBounds.max.x, roomBounds.min.y, roomBounds.max.z),
                    SIMD3<Float>(roomBounds.min.x, roomBounds.max.y, roomBounds.max.z),
                    SIMD3<Float>(roomBounds.max.x, roomBounds.max.y, roomBounds.max.z)
                ]

                for corner in corners {
                    let transformedCorner = transformPoint(corner, by: room.transform)
                    minBound = min(minBound, transformedCorner)
                    maxBound = max(maxBound, transformedCorner)
                }
            }

            totalFloorArea += room.floorArea
        }

        combinedBoundingBox = (minBound, maxBound)
    }

    // MARK: - Export

    /// Get all meshes transformed to aligned coordinate system
    func getAlignedMeshes() -> [CapturedMeshData] {
        var allMeshes: [CapturedMeshData] = []

        for room in rooms where room.isAligned {
            for mesh in room.capturedScan.meshes {
                // Combine mesh transform with room alignment transform
                let combinedTransform = room.transform * mesh.transform

                var alignedMesh = mesh
                // Note: We need to update the mesh transform
                // Since CapturedMeshData has let properties, we create a new one
                let newMesh = CapturedMeshData(
                    vertices: mesh.vertices,
                    normals: mesh.normals,
                    colors: mesh.colors,
                    faces: mesh.faces,
                    transform: combinedTransform,
                    identifier: mesh.identifier,
                    surfaceType: mesh.surfaceType,
                    faceClassifications: mesh.faceClassifications
                )
                allMeshes.append(newMesh)
            }
        }

        return allMeshes
    }

    /// Create a combined scan from all aligned rooms
    func createCombinedScan() -> CapturedScan? {
        guard isAligned else { return nil }

        let alignedMeshes = getAlignedMeshes()
        guard !alignedMeshes.isEmpty else { return nil }

        var combinedScan = CapturedScan(startTime: rooms.first?.capturedScan.startTime ?? Date())
        combinedScan.meshes = alignedMeshes
        combinedScan.endTime = Date()

        // Combine statistics
        var combinedStats = ScanStatistics()
        for room in rooms {
            if let stats = room.capturedScan.statistics {
                combinedStats.floorArea += stats.floorArea
                combinedStats.wallArea += stats.wallArea
                combinedStats.ceilingArea += stats.ceilingArea
                combinedStats.detectedDoors.append(contentsOf: stats.detectedDoors)
                combinedStats.detectedWindows.append(contentsOf: stats.detectedWindows)
            }
        }
        combinedScan.statistics = combinedStats

        return combinedScan
    }

    // MARK: - Reset

    func reset() {
        rooms.removeAll()
        doorPairs.removeAll()
        currentRoomIndex = 0
        isAligned = false
        combinedBoundingBox = nil
        totalFloorArea = 0
        alignmentStatus = ""
    }
}
