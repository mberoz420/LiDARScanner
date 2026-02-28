import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    let scan: CapturedScan
    @StateObject private var exporter = MeshExporter()
    @StateObject private var roomSimplifier = RoomSimplifier()
    @ObservedObject var settings = AppSettings.shared
    @State private var exportedURLs: [ExportFormat: URL] = [:]
    @State private var selectedFormat: ExportFormat = .usdz
    @State private var shareItem: ShareItem?
    @State private var showFilePicker = false
    @State private var fileToSave: URL?
    @State private var showSaveSuccess = false
    @State private var showGoogleDriveAlert = false
    @State private var googleDriveInstruction = ""
    @State private var pendingShareURL: URL?
    @State private var useSimplifiedExport = false
    @State private var simplifiedRoom: SimplifiedRoom?
    @State private var showSaveSession = false
    @State private var sessionName = ""
    @State private var isSavingSession = false
    @State private var sessionSaveSuccess = false
    @ObservedObject private var sessionManager = ScanSessionManager.shared
    @Environment(\.dismiss) private var dismiss

    // Optional: scan mode for session saving
    var scanMode: ScanMode = .fast

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Scan summary with simplification toggle
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Export Mode")
                            .font(.headline)
                        Spacer()
                    }

                    // Full mesh vs Simplified toggle
                    Picker("Export Type", selection: $useSimplifiedExport) {
                        Text("Full Mesh").tag(false)
                        Text("Simplified Room").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: useSimplifiedExport) { newValue in
                        if newValue && simplifiedRoom == nil {
                            generateSimplifiedRoom()
                        }
                    }

                    // Stats comparison
                    HStack {
                        VStack(alignment: .leading) {
                            if useSimplifiedExport, let room = simplifiedRoom {
                                Text("Vertices: \(room.vertexCount)")
                                    .foregroundColor(.green)
                                Text("Walls: \(room.wallCount)")
                            } else {
                                Text("Vertices: \(scan.vertexCount)")
                                Text("Faces: \(scan.faceCount)")
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            if useSimplifiedExport, let room = simplifiedRoom {
                                Text(String(format: "%.1f m²", room.floorArea))
                                Text(String(format: "Height: %.2f m", room.roomHeight))
                            } else {
                                Text("Meshes: \(scan.meshes.count)")
                                if scan.hasColors {
                                    Label("With Colors", systemImage: "paintpalette.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                    // Reduction info
                    if useSimplifiedExport, let room = simplifiedRoom {
                        let reduction = 100.0 - (Float(room.vertexCount) / Float(max(1, scan.vertexCount)) * 100)
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                            Text(String(format: "%.0f%% reduction (%d → %d vertices)",
                                        reduction, scan.vertexCount, room.vertexCount))
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }

                    // Surface breakdown if available
                    if let stats = scan.statistics {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Surfaces Detected")
                                .font(.caption)
                                .fontWeight(.semibold)

                            HStack(spacing: 16) {
                                SurfaceStatItem(label: "Floor", value: String(format: "%.1fm²", stats.floorArea), color: .green)
                                SurfaceStatItem(label: "Walls", value: String(format: "%.1fm²", stats.wallArea), color: .blue)
                                SurfaceStatItem(label: "Ceiling", value: String(format: "%.1fm²", stats.ceilingArea), color: .yellow)
                            }

                            if let roomHeight = stats.estimatedRoomHeight {
                                HStack {
                                    Image(systemName: "ruler")
                                    Text(String(format: "Room height: %.2fm", roomHeight))
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }

                            if !stats.detectedProtrusions.isEmpty {
                                HStack {
                                    Image(systemName: "rectangle.split.3x1")
                                        .foregroundColor(.orange)
                                    Text("\(stats.detectedProtrusions.count) ceiling protrusions")
                                }
                                .font(.caption)
                            }

                            if !stats.detectedDoors.isEmpty {
                                HStack {
                                    Image(systemName: "door.left.hand.open")
                                        .foregroundColor(.brown)
                                    Text("\(stats.detectedDoors.count) doors detected")
                                }
                                .font(.caption)
                            }

                            if !stats.detectedWindows.isEmpty {
                                HStack {
                                    Image(systemName: "window.horizontal")
                                        .foregroundColor(.cyan)
                                    Text("\(stats.detectedWindows.count) windows detected")
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)

                // Export format selection
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Export Format")
                            .font(.headline)
                        Spacer()
                        Text(settings.defaultDestination.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    ForEach(ExportFormat.allCases) { format in
                        ExportFormatRow(
                            format: format,
                            isExported: exportedURLs[format] != nil,
                            isExporting: exporter.isExporting && selectedFormat == format
                        ) {
                            Task { await exportAndHandle(format) }
                        } onShare: {
                            if let url = exportedURLs[format] {
                                handleExportedFile(url: url)
                            }
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)

                // Export all button
                Button(action: { Task { await exportAllAndHandle() } }) {
                    HStack {
                        if exporter.isExporting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text("Export All Formats")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(exporter.isExporting)

                // Save Session button
                Button(action: {
                    sessionName = sessionManager.generateDefaultName()
                    showSaveSession = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save Session")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isSavingSession)

                if let error = exporter.lastError {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .font(.caption)
                }

                if showSaveSuccess {
                    Label("Saved successfully!", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .transition(.opacity)
                }

                if sessionSaveSuccess {
                    Label("Session saved! Find it in Saved Scans.", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .transition(.opacity)
                }

                if isSavingSession {
                    HStack {
                        ProgressView()
                        Text("Saving session...")
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Export Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(url: item.url)
            }
            .alert("Save to Google Drive", isPresented: $showGoogleDriveAlert) {
                Button("Open Share Sheet") {
                    if let url = pendingShareURL {
                        shareItem = ShareItem(url: url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(googleDriveInstruction)
            }
            .alert("Save Session", isPresented: $showSaveSession) {
                TextField("Session Name", text: $sessionName)
                Button("Save") {
                    Task { await saveSession() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Save this scan to continue editing later.")
            }
            .fileExporter(
                isPresented: $showFilePicker,
                document: fileToSave.map { FileDocument(url: $0) },
                contentType: .data,
                defaultFilename: fileToSave?.lastPathComponent ?? "scan"
            ) { result in
                switch result {
                case .success:
                    withAnimation {
                        showSaveSuccess = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showSaveSuccess = false
                        }
                    }
                case .failure(let error):
                    exporter.lastError = error.localizedDescription
                }
            }
        }
    }

    private func exportAndHandle(_ format: ExportFormat) async {
        selectedFormat = format
        let exportScan = getExportScan()
        if let url = await exporter.export(exportScan, format: format) {
            exportedURLs[format] = url
            handleExportedFile(url: url)
        }
    }

    private func exportAllAndHandle() async {
        let exportScan = getExportScan()
        let results = await exporter.exportAll(exportScan)
        exportedURLs = results

        // Handle based on settings
        if let firstURL = results.values.first {
            handleExportedFile(url: firstURL, isMultiple: true, allURLs: Array(results.values))
        }
    }

    private func handleExportedFile(url: URL, isMultiple: Bool = false, allURLs: [URL] = []) {
        switch settings.defaultDestination {
        case .shareSheet:
            shareItem = ShareItem(url: url)

        case .files:
            fileToSave = url
            showFilePicker = true

        case .googleDrive:
            // Google Drive: Save to app's documents then share to Google Drive via share sheet
            // User selects "Save to Files" in share sheet, then navigates to Google Drive
            saveToGoogleDrive(url: url)

        case .iCloud:
            // iCloud: Save directly to iCloud Drive container
            saveToiCloud(url: url)
        }
    }

    private func saveToGoogleDrive(url: URL) {
        let driveManager = GoogleDriveManager.shared

        // Check if Google Drive is configured
        guard driveManager.isConfigured else {
            googleDriveInstruction = "Google Drive not configured. Go to App Settings → Google Drive to set up your Client ID."
            showGoogleDriveAlert = true
            pendingShareURL = url
            return
        }

        // Try automatic upload
        Task {
            let mimeType = driveManager.mimeType(for: url)
            let success = await driveManager.uploadFile(at: url, mimeType: mimeType)

            if success {
                withAnimation {
                    showSaveSuccess = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        showSaveSuccess = false
                    }
                }
            } else {
                // Fall back to manual method
                let folderName = settings.googleDriveFolderName
                googleDriveInstruction = driveManager.lastError ?? "Upload failed. Tap 'Save to Files' → Browse → Google Drive → \(folderName)"
                showGoogleDriveAlert = true
                pendingShareURL = url
            }
        }
    }

    private func generateSimplifiedRoom() {
        guard let stats = scan.statistics else {
            exporter.lastError = "No room statistics available for simplification"
            useSimplifiedExport = false
            return
        }

        // Configure simplifier from settings
        roomSimplifier.gridResolution = Float(settings.simplificationGridSize) / 100.0
        roomSimplifier.minWallLength = Float(settings.minWallLength) / 100.0

        simplifiedRoom = roomSimplifier.extractSimplifiedRoom(from: scan, statistics: stats)

        if simplifiedRoom == nil {
            exporter.lastError = "Could not simplify room (need floor/ceiling detection)"
            useSimplifiedExport = false
        }
    }

    private func getExportScan() -> CapturedScan {
        if useSimplifiedExport, let room = simplifiedRoom {
            // Create scan with simplified mesh
            let simplifiedMesh = roomSimplifier.generateMesh(from: room)
            var simplifiedScan = CapturedScan(startTime: scan.startTime)
            simplifiedScan.meshes = [simplifiedMesh]
            simplifiedScan.endTime = scan.endTime
            simplifiedScan.statistics = scan.statistics
            return simplifiedScan
        }
        return scan
    }

    private func saveSession() async {
        guard !sessionName.isEmpty else { return }

        isSavingSession = true

        do {
            _ = try await sessionManager.saveSession(
                scan,
                name: sessionName,
                mode: scanMode
            )

            withAnimation {
                sessionSaveSuccess = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    sessionSaveSuccess = false
                }
            }
        } catch {
            exporter.lastError = "Failed to save session: \(error.localizedDescription)"
        }

        isSavingSession = false
    }

    private func saveToiCloud(url: URL) {
        // Get iCloud container URL
        guard let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents") else {
            // iCloud not available, fall back to share sheet
            exporter.lastError = "iCloud not available. Using share sheet instead."
            shareItem = ShareItem(url: url)
            return
        }

        // Create Documents folder if needed
        do {
            if !FileManager.default.fileExists(atPath: iCloudURL.path) {
                try FileManager.default.createDirectory(at: iCloudURL, withIntermediateDirectories: true)
            }

            // Copy file to iCloud
            let destinationURL = iCloudURL.appendingPathComponent(url.lastPathComponent)

            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: url, to: destinationURL)

            withAnimation {
                showSaveSuccess = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showSaveSuccess = false
                }
            }
        } catch {
            exporter.lastError = "iCloud save failed: \(error.localizedDescription)"
            // Fall back to share sheet
            shareItem = ShareItem(url: url)
        }
    }
}

// File document wrapper for file exporter
struct FileDocument: SwiftUI.FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        url = URL(fileURLWithPath: "")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url)
    }
}

// Wrapper for share sheet item binding
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ExportFormatRow: View {
    let format: ExportFormat
    let isExported: Bool
    let isExporting: Bool
    let onExport: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(format.rawValue)
                    .font(.body)
                Text(formatDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isExporting {
                ProgressView()
            } else if isExported {
                Button("Share") { onShare() }
                    .buttonStyle(.bordered)
            } else {
                Button("Export") { onExport() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var formatDescription: String {
        switch format {
        case .usdz:
            return "Apple 3D format"
        case .ply:
            return "Point cloud with colors"
        case .obj:
            return "Universal 3D mesh"
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SurfaceStatItem: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(color.opacity(0.6))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}
