import SwiftUI

struct MultiRoomView: View {
    @StateObject private var multiRoomManager = MultiRoomManager()
    @StateObject private var meshManager = MeshManager()
    @State private var showScanner = false
    @State private var showDoorLabeling = false
    @State private var newRoomName = ""
    @State private var showExport = false
    @State private var combinedScan: CapturedScan?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status bar
                if !multiRoomManager.alignmentStatus.isEmpty {
                    HStack {
                        Image(systemName: multiRoomManager.isAligned ? "checkmark.circle.fill" : "info.circle")
                            .foregroundColor(multiRoomManager.isAligned ? .green : .blue)
                        Text(multiRoomManager.alignmentStatus)
                            .font(.caption)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.1))
                }

                List {
                    // Rooms section
                    Section {
                        if multiRoomManager.rooms.isEmpty {
                            Text("No rooms scanned yet")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(multiRoomManager.rooms) { room in
                                RoomRow(room: room, onLabelDoors: {
                                    multiRoomManager.currentRoomIndex = multiRoomManager.rooms.firstIndex(where: { $0.id == room.id }) ?? 0
                                    showDoorLabeling = true
                                })
                            }
                            .onDelete { indexSet in
                                multiRoomManager.rooms.remove(atOffsets: indexSet)
                            }
                        }

                        Button(action: { showScanner = true }) {
                            Label("Scan New Room", systemImage: "plus.viewfinder")
                        }
                    } header: {
                        HStack {
                            Text("Rooms")
                            Spacer()
                            Text("\(multiRoomManager.rooms.count) scanned")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Door pairs section
                    if !multiRoomManager.doorPairs.isEmpty {
                        Section("Door Connections") {
                            ForEach(multiRoomManager.doorPairs, id: \.doorLabel) { pair in
                                DoorPairRow(pair: pair, rooms: multiRoomManager.rooms)
                            }
                        }
                    }

                    // Settings section
                    Section {
                        HStack {
                            Text("Wall Thickness")
                            Spacer()
                            Text("\(Int(multiRoomManager.wallThickness * 100))cm")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $multiRoomManager.wallThickness, in: 0.05...0.40, step: 0.01)
                    } header: {
                        Text("Alignment Settings")
                    } footer: {
                        Text("Adjust based on your wall construction (typical: 10-20cm)")
                    }

                    // Actions section
                    Section {
                        Button(action: alignRooms) {
                            HStack {
                                Image(systemName: "arrow.triangle.merge")
                                Text("Align Rooms")
                            }
                        }
                        .disabled(multiRoomManager.doorPairs.isEmpty)

                        if multiRoomManager.isAligned {
                            Button(action: exportCombined) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export Combined Floor Plan")
                                }
                            }

                            // Summary
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Total Floor Area")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.1f m²", multiRoomManager.totalFloorArea))
                                        .font(.headline)
                                }
                                Spacer()
                                if let bounds = multiRoomManager.combinedBoundingBox {
                                    VStack(alignment: .trailing) {
                                        Text("Dimensions")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.1f x %.1f m",
                                                    bounds.max.x - bounds.min.x,
                                                    bounds.max.z - bounds.min.z))
                                            .font(.headline)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Multi-Room Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reset") {
                        multiRoomManager.reset()
                    }
                    .disabled(multiRoomManager.rooms.isEmpty)
                }
            }
            .sheet(isPresented: $showScanner) {
                RoomScannerSheet(
                    meshManager: meshManager,
                    onComplete: { name, scan, stats in
                        multiRoomManager.addRoom(name: name, scan: scan, statistics: stats)
                        showScanner = false
                    }
                )
            }
            .sheet(isPresented: $showDoorLabeling) {
                if let room = multiRoomManager.currentRoom {
                    DoorLabelingView(
                        room: room,
                        existingLabels: getExistingDoorLabels(),
                        onSave: { updatedDoors in
                            if let index = multiRoomManager.rooms.firstIndex(where: { $0.id == room.id }) {
                                multiRoomManager.rooms[index].doors = updatedDoors
                                multiRoomManager.alignRooms()  // Re-check alignment
                            }
                            showDoorLabeling = false
                        }
                    )
                }
            }
            .sheet(isPresented: $showExport) {
                if let scan = combinedScan {
                    ExportView(scan: scan)
                }
            }
        }
    }

    private func getExistingDoorLabels() -> [String] {
        var labels: Set<String> = []
        for room in multiRoomManager.rooms {
            for door in room.doors where !door.label.isEmpty {
                labels.insert(door.label)
            }
        }
        return Array(labels).sorted()
    }

    private func alignRooms() {
        multiRoomManager.alignRooms()
    }

    private func exportCombined() {
        combinedScan = multiRoomManager.createCombinedScan()
        if combinedScan != nil {
            showExport = true
        }
    }
}

// MARK: - Room Row

struct RoomRow: View {
    let room: RoomScan
    let onLabelDoors: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(room.name)
                        .font(.headline)
                    Text(String(format: "%.1f m² | %d doors | %d windows",
                                room.floorArea,
                                room.doors.count,
                                room.windows.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if room.isAligned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }

            // Door labels
            if !room.doors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(room.doors) { door in
                            DoorChip(door: door)
                        }
                    }
                }
            }

            Button("Label Doors", action: onLabelDoors)
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

struct DoorChip: View {
    let door: LabeledDoor

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "door.left.hand.open")
                .font(.caption2)
            Text(door.label.isEmpty ? "Unlabeled" : door.label)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(door.label.isEmpty ? Color.gray.opacity(0.2) : Color.brown.opacity(0.2))
        .foregroundColor(door.label.isEmpty ? .secondary : .brown)
        .cornerRadius(12)
    }
}

// MARK: - Door Pair Row

struct DoorPairRow: View {
    let pair: DoorPair
    let rooms: [RoomScan]

    var body: some View {
        HStack {
            Image(systemName: "door.left.hand.open")
                .foregroundColor(.brown)

            VStack(alignment: .leading) {
                Text(pair.doorLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("\(roomName(pair.room1Id)) ↔ \(roomName(pair.room2Id))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "link")
                .foregroundColor(.green)
        }
    }

    private func roomName(_ id: UUID) -> String {
        rooms.first(where: { $0.id == id })?.name ?? "Unknown"
    }
}

// MARK: - Room Scanner Sheet

struct RoomScannerSheet: View {
    @ObservedObject var meshManager: MeshManager
    let onComplete: (String, CapturedScan, ScanStatistics?) -> Void

    @State private var roomName = ""
    @State private var isScanning = false
    @State private var capturedScan: CapturedScan?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                if !isScanning && capturedScan == nil {
                    // Room name input
                    VStack(spacing: 20) {
                        Image(systemName: "door.left.hand.closed")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)

                        Text("Close all doors before scanning")
                            .font(.headline)

                        TextField("Room Name", text: $roomName)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 40)

                        Text("Scan each room separately with doors closed. Later, label matching doors to align rooms.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Start Scanning") {
                            isScanning = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(roomName.isEmpty)
                    }
                    .padding()
                } else if isScanning {
                    // Scanner view
                    ZStack {
                        ARViewContainer(meshManager: meshManager)
                            .edgesIgnoringSafeArea(.all)

                        VStack {
                            // Stats
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(roomName)
                                        .font(.headline)
                                    Text(meshManager.scanStatus)
                                        .font(.caption)
                                    Text("Vertices: \(meshManager.vertexCount)")
                                        .font(.caption)
                                }
                                .padding()
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(8)

                                Spacer()
                            }
                            .padding()

                            Spacer()

                            // Controls
                            HStack(spacing: 20) {
                                Button(meshManager.isScanning ? "Stop" : "Start") {
                                    if meshManager.isScanning {
                                        capturedScan = meshManager.stopScanning()
                                        isScanning = false
                                    } else {
                                        meshManager.startScanning()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(meshManager.isScanning ? .red : .green)
                            }
                            .padding(.bottom, 50)
                        }
                    }
                    .onAppear {
                        meshManager.startScanning()
                    }
                } else if let scan = capturedScan {
                    // Completion
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)

                        Text("Room Captured!")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Vertices: \(scan.vertexCount)")
                            Text("Faces: \(scan.faceCount)")
                            if let stats = meshManager.surfaceClassifier.statistics.summary, !stats.isEmpty {
                                Text(stats)
                            }
                            Text("Doors: \(meshManager.surfaceClassifier.statistics.detectedDoors.count)")
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                        Button("Save Room") {
                            onComplete(roomName, scan, meshManager.surfaceClassifier.statistics)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle(isScanning ? "Scanning..." : "New Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Door Labeling View

struct DoorLabelingView: View {
    let room: RoomScan
    let existingLabels: [String]
    let onSave: ([LabeledDoor]) -> Void

    @State private var doors: [LabeledDoor]
    @State private var newLabel = ""
    @Environment(\.dismiss) private var dismiss

    init(room: RoomScan, existingLabels: [String], onSave: @escaping ([LabeledDoor]) -> Void) {
        self.room = room
        self.existingLabels = existingLabels
        self.onSave = onSave
        self._doors = State(initialValue: room.doors)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Label each door so it can be matched with the same door in the adjacent room.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Detected Doors (\(doors.count))") {
                    ForEach(doors.indices, id: \.self) { index in
                        DoorLabelRow(
                            door: $doors[index],
                            existingLabels: existingLabels,
                            doorNumber: index + 1
                        )
                    }
                }

                if !existingLabels.isEmpty {
                    Section("Used Labels") {
                        Text(existingLabels.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Label Doors - \(room.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onSave(doors)
                    }
                }
            }
        }
    }
}

struct DoorLabelRow: View {
    @Binding var door: LabeledDoor
    let existingLabels: [String]
    let doorNumber: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "door.left.hand.open")
                    .foregroundColor(.brown)
                Text("Door \(doorNumber)")
                    .font(.subheadline)

                Spacer()

                Text(String(format: "%.0fcm × %.0fcm",
                            door.door.width * 100,
                            door.door.height * 100))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            TextField("Label (e.g., 'Kitchen-Living')", text: $door.label)
                .textFieldStyle(.roundedBorder)

            // Quick select from existing labels
            if !existingLabels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(existingLabels, id: \.self) { label in
                            Button(label) {
                                door.label = label
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
            }

            // Wall side picker
            Picker("Side", selection: $door.wallSide) {
                Text("Front").tag(LabeledDoor.WallSide.front)
                Text("Back").tag(LabeledDoor.WallSide.back)
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    MultiRoomView()
}
