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

    private func createLabelingJSON(from scan: CapturedScan) async throws -> URL {
        // Create JSON structure compatible with PointCloudLabeler.html
        // Phase 1: Collect all points and find room bounds
        var allPoints: [(vertex: SIMD3<Float>, normal: SIMD3<Float>, color: (r: Float, g: Float, b: Float)?)] = []
        var floorYSamples: [Float] = []
        var ceilingYSamples: [Float] = []

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

                allPoints.append((vertex, normal, color))

                // Collect Y samples for floor/ceiling detection
                if normal.y > 0.5 {
                    floorYSamples.append(vertex.y)
                } else if normal.y < -0.5 {
                    ceilingYSamples.append(vertex.y)
                }
            }
        }

        // Find floor height: minimum Y among upward-facing surfaces
        // This is the actual floor level (lowest point with upward normal)
        let floorHeight: Float = floorYSamples.isEmpty ? -999 : floorYSamples.min()!

        // Find ceiling height: maximum Y among downward-facing surfaces
        // This is the actual ceiling level (highest point with downward normal)
        let ceilingHeight: Float = ceilingYSamples.isEmpty ? 999 : ceilingYSamples.max()!

        let floorTolerance: Float = 0.15  // 15cm
        let ceilingTolerance: Float = 0.15

        // Phase 2: Classify each point and build JSON
        var pointsArray: [[String: Any]] = []

        for (vertex, normal, color) in allPoints {
            var point: [String: Any] = [
                "x": vertex.x,
                "y": vertex.y,
                "z": vertex.z,
                "nx": normal.x,
                "ny": normal.y,
                "nz": normal.z
            ]

            if let c = color {
                point["r"] = c.r
                point["g"] = c.g
                point["b"] = c.b
            }

            // Classify based on normal direction and Y position
            let label: String
            let ny = normal.y
            let horizontalMag = sqrt(normal.x * normal.x + normal.z * normal.z)

            if ny > 0.5 {
                // Upward-facing: Floor if at lowest level, otherwise Object Top
                label = (vertex.y <= floorHeight + floorTolerance) ? "Floor" : "Object Top"
            } else if ny < -0.5 {
                // Downward-facing: Ceiling if at highest level, otherwise Object Top
                label = (vertex.y >= ceilingHeight - ceilingTolerance) ? "Ceiling" : "Object Top"
            } else if horizontalMag > 0.5 {
                // Horizontal normal: Wall or Object
                label = "Wall"
            } else {
                // Mixed/angled
                label = "Object"
            }

            point["label"] = label
            pointsArray.append(point)
        }

        let exportData: [String: Any] = [
            "points": pointsArray,
            "metadata": [
                "sessionId": sessionId.uuidString,
                "exportDate": ISO8601DateFormatter().string(from: Date()),
                "vertexCount": scan.vertexCount,
                "meshCount": scan.meshes.count,
                "floorHeight": floorHeight,
                "ceilingHeight": ceilingHeight,
                "classificationMethod": "per-point"
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])

        let filename = "labeling_\(sessionId.uuidString.prefix(8)).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try jsonData.write(to: tempURL)

        print("[SessionDetail] Created labeling JSON: \(tempURL.path) (\(jsonData.count) bytes)")
        print("[SessionDetail] Floor: \(floorHeight), Ceiling: \(ceilingHeight)")

        return tempURL
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
