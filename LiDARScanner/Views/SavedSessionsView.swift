import SwiftUI
import simd

/// List of saved scan sessions
struct SavedSessionsView: View {
    @ObservedObject private var sessionManager = ScanSessionManager.shared
    @State private var selectedSession: SessionMetadata?
    @State private var sessionToDelete: SessionMetadata?
    @State private var showDeleteConfirmation = false
    @State private var sessionToRename: SessionMetadata?
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if sessionManager.savedSessions.isEmpty {
                    emptyState
                } else {
                    sessionsList
                }
            }
            .navigationTitle("Saved Scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Reload sessions when view appears
                sessionManager.loadSessionsList()
                print("[SavedSessionsView] Loaded \(sessionManager.savedSessions.count) sessions")
            }
            .sheet(item: $selectedSession) { session in
                SessionDetailView(
                    sessionId: session.id,
                    onResume: { dismiss() }
                )
            }
            .alert("Delete Scan?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let session = sessionToDelete {
                        try? sessionManager.deleteSession(session.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let session = sessionToDelete {
                    Text("Are you sure you want to delete \"\(session.name)\"? This cannot be undone.")
                }
            }
            .alert("Rename Scan", isPresented: .init(
                get: { sessionToRename != nil },
                set: { if !$0 { sessionToRename = nil } }
            )) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let session = sessionToRename, !newName.isEmpty {
                        try? sessionManager.renameSession(session.id, to: newName)
                    }
                    sessionToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionToRename = nil
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.3.layers.3d.slash")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No Saved Scans")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Complete a scan and tap \"Save Session\" to save it for later editing.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var sessionsList: some View {
        List {
            // Storage info
            Section {
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(.blue)
                    Text("Storage Used")
                    Spacer()
                    Text(sessionManager.formattedStorageSize())
                        .foregroundColor(.secondary)
                }
            }

            // Sessions
            Section {
                ForEach(sessionManager.savedSessions) { session in
                    SessionRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedSession = session
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                sessionToDelete = session
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                newName = session.name
                                sessionToRename = session
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                }
            } header: {
                Text("\(sessionManager.savedSessions.count) Scans")
            }
        }
        .refreshable {
            sessionManager.loadSessionsList()
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: SessionMetadata
    @ObservedObject private var sessionManager = ScanSessionManager.shared

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            thumbnailView
                .frame(width: 60, height: 60)
                .cornerRadius(8)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    // Mode icon
                    if let mode = ScanMode(rawValue: session.scanMode) {
                        Image(systemName: mode.icon)
                            .font(.caption)
                            .foregroundColor(mode.color)
                    }

                    // Vertex count
                    Text("\(formatNumber(session.vertexCount)) vertices")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Mesh count
                    Text("\(session.meshCount) meshes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Date
                Text(formatDate(session.lastModifiedAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = sessionManager.loadThumbnail(for: session.id) {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Placeholder with mode icon
            ZStack {
                Color.gray.opacity(0.2)
                if let mode = ScanMode(rawValue: session.scanMode) {
                    Image(systemName: mode.icon)
                        .font(.title2)
                        .foregroundColor(mode.color.opacity(0.5))
                } else {
                    Image(systemName: "cube")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000000 {
            return String(format: "%.1fM", Double(n) / 1000000)
        } else if n >= 1000 {
            return String(format: "%.1fK", Double(n) / 1000)
        }
        return "\(n)"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let sessionId: UUID
    let onResume: () -> Void

    @ObservedObject private var sessionManager = ScanSessionManager.shared
    @State private var loadedScan: CapturedScan?
    @State private var scanMode: ScanMode = .fast
    @State private var isLoading = true
    @State private var error: String?
    @State private var showExport = false
    @State private var showArchitecturalExtraction = false
    @State private var showAnnotation = false
    @State private var repairModeEnabled = true
    @State private var showLabelingExport = false
    @State private var labelingExportURL: URL?
    @State private var isExportingForLabeling = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    loadingView
                } else if let scan = loadedScan {
                    scanDetailView(scan)
                } else if let error = error {
                    errorView(error)
                }
            }
            .navigationTitle("Session Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back") { dismiss() }
                }
            }
            .task {
                await loadSession()
            }
            .sheet(isPresented: $showExport) {
                if let scan = loadedScan {
                    ExportView(scan: scan, scanMode: scanMode)
                }
            }
            .sheet(isPresented: $showArchitecturalExtraction) {
                if let scan = loadedScan {
                    ArchitecturalExtractionView(scan: scan)
                }
            }
            .sheet(isPresented: $showAnnotation) {
                if let scan = loadedScan {
                    AnnotationView(scan: scan)
                }
            }
            .sheet(isPresented: $showLabelingExport) {
                if let url = labelingExportURL {
                    LabelingExportShareSheet(url: url) {
                        showLabelingExport = false
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading session...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            Text("Failed to Load")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Retry") {
                Task { await loadSession() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanDetailView(_ scan: CapturedScan) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Stats card
                statsCard(scan)

                // Repair mode toggle
                repairModeCard

                // Action buttons
                actionButtons
            }
            .padding()
        }
    }

    private func statsCard(_ scan: CapturedScan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: scanMode.icon)
                    .foregroundColor(scanMode.color)
                Text(scanMode.rawValue)
                    .font(.headline)
                Spacer()
            }

            Divider()

            HStack(spacing: 20) {
                StatItem(title: "Vertices", value: "\(scan.vertexCount)")
                StatItem(title: "Meshes", value: "\(scan.meshes.count)")
                StatItem(title: "Faces", value: "\(scan.faceCount)")
            }

            if let stats = scan.statistics {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if let height = stats.estimatedRoomHeight {
                        HStack {
                            Image(systemName: "ruler")
                            Text(String(format: "Room Height: %.2fm", height))
                        }
                        .font(.subheadline)
                    }

                    if stats.floorArea > 0 {
                        HStack {
                            Image(systemName: "square")
                            Text(String(format: "Floor Area: %.1fm²", stats.floorArea))
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var repairModeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $repairModeEnabled) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text("Auto-Repair Mode")
                            .font(.headline)
                        Text("Automatically replace bad mesh areas when rescanning")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Resume scanning
            Button(action: resumeScanning) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Resume Scanning")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }

            // Extract Architecture (AI)
            Button(action: { showArchitecturalExtraction = true }) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("Extract Architecture")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.purple)
                .foregroundColor(.white)
                .cornerRadius(12)
            }

            // Annotate for ML Training
            Button(action: { showAnnotation = true }) {
                HStack {
                    Image(systemName: "brain")
                    Text("Annotate for Training")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(12)
            }

            // Export
            Button(action: { showExport = true }) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }

            // Export for Desktop Labeling
            Button(action: { exportForLabeling() }) {
                HStack {
                    if isExportingForLabeling {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "desktopcomputer")
                    }
                    Text("Export for Desktop Labeling")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.teal)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isExportingForLabeling)
        }
    }

    private func loadSession() async {
        isLoading = true
        error = nil

        do {
            let result = try await sessionManager.loadSession(sessionId)
            loadedScan = result.scan
            scanMode = result.mode
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    private func resumeScanning() {
        // TODO: Pass session to MeshManager and start scanning
        // For now, just notify that we want to resume
        NotificationCenter.default.post(
            name: .resumeScanSession,
            object: nil,
            userInfo: [
                "sessionId": sessionId,
                "repairMode": repairModeEnabled
            ]
        )
        dismiss()
        onResume()
    }

    private func exportForLabeling() {
        guard let scan = loadedScan else { return }

        isExportingForLabeling = true

        Task {
            do {
                let url = try await createLabelingJSON(from: scan)
                await MainActor.run {
                    labelingExportURL = url
                    showLabelingExport = true
                    isExportingForLabeling = false
                }
            } catch {
                print("[SessionDetail] Export for labeling failed: \(error)")
                await MainActor.run {
                    isExportingForLabeling = false
                }
            }
        }
    }

    /// Point data for classification during export
    private struct ExportPointData {
        let vertex: SIMD3<Float>
        let normal: SIMD3<Float>
        let color: (r: Float, g: Float, b: Float)?
    }

    private func createLabelingJSON(from scan: CapturedScan) async throws -> URL {
        // Create JSON structure compatible with PointCloudLabeler.html
        // Phase 1: Collect all points with world coordinates
        var allPoints: [ExportPointData] = []

        for mesh in scan.meshes {
            let transform = mesh.transform
            let rotationMatrix = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )

            for i in 0..<mesh.vertices.count {
                let localVertex = mesh.vertices[i]
                let localNormal = i < mesh.normals.count ? mesh.normals[i] : SIMD3<Float>(0, 1, 0)

                let worldPos = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
                let vertex = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)
                let normal = simd_normalize(rotationMatrix * localNormal)

                let color: (r: Float, g: Float, b: Float)? = i < mesh.colors.count ?
                    (mesh.colors[i].r, mesh.colors[i].g, mesh.colors[i].b) : nil

                allPoints.append(ExportPointData(vertex: vertex, normal: normal, color: color))
            }
        }

        // Phase 2: Determine room boundaries (floor/ceiling heights, wall distances)
        let roomBounds = calculateRoomBounds(points: allPoints)

        // Phase 3: Classify each point individually and build JSON
        var pointsArray: [[String: Any]] = []

        for pointData in allPoints {
            let label = classifyPointForExport(
                vertex: pointData.vertex,
                normal: pointData.normal,
                roomBounds: roomBounds
            )

            var point: [String: Any] = [
                "x": pointData.vertex.x,
                "y": pointData.vertex.y,
                "z": pointData.vertex.z,
                "nx": pointData.normal.x,
                "ny": pointData.normal.y,
                "nz": pointData.normal.z,
                "label": label.rawValue
            ]

            if let color = pointData.color {
                point["r"] = color.r
                point["g"] = color.g
                point["b"] = color.b
            }

            pointsArray.append(point)
        }

        let exportData: [String: Any] = [
            "points": pointsArray,
            "metadata": [
                "sessionId": sessionId.uuidString,
                "exportDate": ISO8601DateFormatter().string(from: Date()),
                "vertexCount": scan.vertexCount,
                "meshCount": scan.meshes.count,
                "floorHeight": roomBounds.floorHeight,
                "ceilingHeight": roomBounds.ceilingHeight
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])

        let filename = "labeling_\(sessionId.uuidString.prefix(8)).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try jsonData.write(to: tempURL)

        print("[SessionDetail] Created labeling JSON: \(tempURL.path) (\(jsonData.count) bytes)")
        print("[SessionDetail] Room bounds: floor=\(roomBounds.floorHeight), ceiling=\(roomBounds.ceilingHeight)")

        return tempURL
    }

    /// Room boundary data for classification
    private struct RoomBounds {
        let floorHeight: Float      // Lowest Y with density (actual floor)
        let ceilingHeight: Float    // Highest Y with density (actual ceiling)
        let floorTolerance: Float   // Tolerance for floor classification
        let ceilingTolerance: Float // Tolerance for ceiling classification
        let wallDistances: [Int: Float]  // Farthest distance per angle bucket (16 buckets)
        let roomCenter: SIMD2<Float>     // Center of room in XZ plane
    }

    /// Calculate room boundaries from point cloud
    private func calculateRoomBounds(points: [ExportPointData]) -> RoomBounds {
        // Collect Y values for upward-facing surfaces (potential floor)
        var floorYSamples: [Float] = []
        // Collect Y values for downward-facing surfaces (potential ceiling)
        var ceilingYSamples: [Float] = []
        // Track farthest points per angle for walls
        var wallDistances: [Int: Float] = [:]  // 16 angle buckets (22.5° each)

        // Calculate rough center from all points
        var sumX: Float = 0, sumZ: Float = 0
        for p in points {
            sumX += p.vertex.x
            sumZ += p.vertex.z
        }
        let roomCenter = SIMD2<Float>(sumX / Float(points.count), sumZ / Float(points.count))

        for p in points {
            let ny = p.normal.y
            let horizontalMag = sqrt(p.normal.x * p.normal.x + p.normal.z * p.normal.z)

            // Upward-facing surfaces (floor candidates)
            if ny > 0.5 {
                floorYSamples.append(p.vertex.y)
            }
            // Downward-facing surfaces (ceiling candidates)
            else if ny < -0.5 {
                ceilingYSamples.append(p.vertex.y)
            }
            // Horizontal normals (wall candidates)
            else if horizontalMag > 0.5 {
                // Calculate angle bucket (0-15 for 360°)
                let angle = atan2(p.vertex.z - roomCenter.y, p.vertex.x - roomCenter.x)
                let bucket = Int((angle + .pi) / (2 * .pi) * 16) % 16
                let distance = sqrt(pow(p.vertex.x - roomCenter.x, 2) + pow(p.vertex.z - roomCenter.y, 2))

                if wallDistances[bucket] == nil || distance > wallDistances[bucket]! {
                    wallDistances[bucket] = distance
                }
            }
        }

        // Find floor height: LOWEST Y with significant density
        let floorHeight = findBoundaryHeight(samples: floorYSamples, findLowest: true)
        // Find ceiling height: HIGHEST Y with significant density
        let ceilingHeight = findBoundaryHeight(samples: ceilingYSamples, findLowest: false)

        return RoomBounds(
            floorHeight: floorHeight,
            ceilingHeight: ceilingHeight,
            floorTolerance: 0.10,   // 10cm tolerance for floor
            ceilingTolerance: 0.10, // 10cm tolerance for ceiling
            wallDistances: wallDistances,
            roomCenter: roomCenter
        )
    }

    /// Find floor or ceiling height using density analysis
    private func findBoundaryHeight(samples: [Float], findLowest: Bool) -> Float {
        guard samples.count >= 10 else {
            return samples.isEmpty ? 0 : (findLowest ? samples.min()! : samples.max()!)
        }

        let sorted = samples.sorted()
        let minY = sorted.first!
        let maxY = sorted.last!
        let range = maxY - minY

        // If all samples within 10cm, return median
        guard range > 0.10 else {
            return sorted[sorted.count / 2]
        }

        // Create 5cm bins
        let binSize: Float = 0.05
        let binCount = max(1, Int(range / binSize) + 1)
        var histogram = [Int](repeating: 0, count: binCount)

        for y in samples {
            let binIndex = min(binCount - 1, Int((y - minY) / binSize))
            histogram[binIndex] += 1
        }

        // Find significant density threshold
        let maxDensity = histogram.max() ?? 1
        let densityThreshold = max(3, maxDensity / 10)

        // Find lowest (floor) or highest (ceiling) bin with significant density
        var selectedBin = 0
        if findLowest {
            for i in 0..<binCount {
                if histogram[i] >= densityThreshold {
                    selectedBin = i
                    break
                }
            }
        } else {
            for i in stride(from: binCount - 1, through: 0, by: -1) {
                if histogram[i] >= densityThreshold {
                    selectedBin = i
                    break
                }
            }
        }

        // Average Y values in selected bin region
        let binY = minY + Float(selectedBin) * binSize
        var sum: Float = 0
        var count = 0

        for y in samples {
            if abs(y - binY) < binSize * 1.5 {
                sum += y
                count += 1
            }
        }

        return count > 0 ? sum / Float(count) : binY
    }

    /// Classify a single point based on its normal and position relative to room bounds
    private func classifyPointForExport(
        vertex: SIMD3<Float>,
        normal: SIMD3<Float>,
        roomBounds: RoomBounds
    ) -> SurfaceType {
        let ny = normal.y
        let horizontalMag = sqrt(normal.x * normal.x + normal.z * normal.z)

        // Upward-facing surface
        if ny > 0.5 {
            // Check if at floor level (lowest Y + tolerance)
            if vertex.y <= roomBounds.floorHeight + roomBounds.floorTolerance {
                return .floor
            }
            return .objectTop
        }

        // Downward-facing surface
        if ny < -0.5 {
            // Check if at ceiling level (highest Y - tolerance)
            if vertex.y >= roomBounds.ceilingHeight - roomBounds.ceilingTolerance {
                return .ceiling
            }
            return .objectBottom
        }

        // Horizontal normal (vertical surface)
        if horizontalMag > 0.5 {
            // Check if this is at the farthest distance for its angle (room wall)
            let angle = atan2(vertex.z - roomBounds.roomCenter.y, vertex.x - roomBounds.roomCenter.x)
            let bucket = Int((angle + .pi) / (2 * .pi) * 16) % 16
            let distance = sqrt(pow(vertex.x - roomBounds.roomCenter.x, 2) + pow(vertex.z - roomBounds.roomCenter.y, 2))

            if let maxDistance = roomBounds.wallDistances[bucket] {
                // Within 30cm of farthest = room wall
                if distance >= maxDistance - 0.30 {
                    return .wall
                }
            }
            return .objectWall
        }

        // Mixed/angled surfaces
        return .object
    }

}

// Share sheet for labeling export
struct LabelingExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onDismiss()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Stat Item

struct StatItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let resumeScanSession = Notification.Name("resumeScanSession")
}

#Preview {
    SavedSessionsView()
}
