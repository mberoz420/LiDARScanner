import SwiftUI
import UniformTypeIdentifiers

// Export type selection
enum ExportType: String, CaseIterable {
    case fullMesh = "Full Mesh"
    case simplifiedRoom = "Simplified Room"
    case cleanWalls = "Clean Walls"
}

// Session save location
enum SessionSaveLocation: String, CaseIterable, Identifiable {
    case local = "On Device"
    case googleDrive = "Google Drive"
    case iCloud = "iCloud Drive"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .local: return "iphone"
        case .googleDrive: return "cloud"
        case .iCloud: return "icloud"
        }
    }

    var description: String {
        switch self {
        case .local: return "Save to app's local storage"
        case .googleDrive: return "Upload to Google Drive"
        case .iCloud: return "Choose location in iCloud Drive"
        }
    }
}

struct ExportView: View {
    let scan: CapturedScan
    let scanMode: ScanMode

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
    @State private var exportType: ExportType = .fullMesh
    @State private var simplifiedRoom: SimplifiedRoom?
    @State private var reconstructedWalls: [ReconstructedWall]?
    @State private var showSaveSession = false
    @State private var sessionName = ""
    @State private var isSavingSession = false
    @State private var sessionSaveSuccess = false
    @State private var saveErrorMessage: String?
    @State private var sessionSaveLocation: SessionSaveLocation = .local
    @State private var lastSaveLocation: SessionSaveLocation = .local
    @State private var showDocumentPicker = false
    @State private var pendingSessionURL: URL?
    @State private var pendingSessionId: UUID?
    @ObservedObject private var sessionManager = ScanSessionManager.shared
    @ObservedObject private var driveManager = GoogleDriveManager.shared

    private var saveSuccessMessage: String {
        switch lastSaveLocation {
        case .local:
            return "Find it in Saved Scans tab"
        case .googleDrive:
            return "Uploaded to Google Drive → LiDAR Scans folder"
        case .iCloud:
            return "Saved to iCloud Drive - visible on icloud.com"
        }
    }
    @Environment(\.dismiss) private var dismiss

    private let wallReconstructor = WallReconstructor()

    init(scan: CapturedScan, scanMode: ScanMode = .fast) {
        self.scan = scan
        self.scanMode = scanMode
    }

    var body: some View {
        NavigationStack {
            mainContent
                .padding()
                .navigationTitle("Export Scan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .sheet(item: $shareItem) { item in
                    ShareSheet(url: item.url)
                }
                .alert("Save to Google Drive", isPresented: $showGoogleDriveAlert) {
                    googleDriveAlertButtons
                } message: {
                    Text(googleDriveInstruction)
                }
                .sheet(isPresented: $showSaveSession) {
                    SaveSessionSheet(
                        sessionName: $sessionName,
                        saveLocation: $sessionSaveLocation,
                        isSaving: $isSavingSession,
                        errorMessage: $saveErrorMessage,
                        meshCount: scan.meshes.count,
                        vertexCount: scan.vertexCount,
                        isGoogleDriveConfigured: driveManager.isConfigured,
                        onSave: { Task { await saveSession() } },
                        onCancel: { showSaveSession = false }
                    )
                }
                .fileExporter(
                    isPresented: $showFilePicker,
                    document: fileToSave.map { FileDocument(url: $0) },
                    contentType: .data,
                    defaultFilename: fileToSave?.lastPathComponent ?? "scan"
                ) { result in
                    handleFileExportResult(result)
                }
                .sheet(isPresented: $showDocumentPicker) {
                    if let url = pendingSessionURL {
                        DocumentPickerView(
                            url: url,
                            onSuccess: {
                                showDocumentPicker = false
                                lastSaveLocation = .iCloud
                                withAnimation {
                                    sessionSaveSuccess = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    withAnimation {
                                        sessionSaveSuccess = false
                                    }
                                }
                                // Clean up temp file
                                try? FileManager.default.removeItem(at: url)
                            },
                            onCancel: {
                                showDocumentPicker = false
                                // Clean up temp file
                                try? FileManager.default.removeItem(at: url)
                            }
                        )
                    }
                }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                exportModeSection
                exportFormatSection
                actionButtonsSection
                statusMessagesSection
            }
        }
    }

    // MARK: - Export Mode Section

    private var exportModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Export Mode")
                    .font(.headline)
                Spacer()
            }

            Picker("Export Type", selection: $exportType) {
                ForEach(ExportType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: exportType) { newValue in
                switch newValue {
                case .simplifiedRoom:
                    if simplifiedRoom == nil {
                        generateSimplifiedRoom()
                    }
                case .cleanWalls:
                    if reconstructedWalls == nil {
                        generateCleanWalls()
                    }
                case .fullMesh:
                    break
                }
            }

            statsComparisonView
            reductionInfoView
            surfaceBreakdownView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }

    private var statsComparisonView: some View {
        HStack {
            VStack(alignment: .leading) {
                switch exportType {
                case .simplifiedRoom:
                    if let room = simplifiedRoom {
                        Text("Vertices: \(room.vertexCount)")
                            .foregroundColor(.green)
                        Text("Walls: \(room.wallCount)")
                    }
                case .cleanWalls:
                    if let walls = reconstructedWalls {
                        let vertexCount = walls.count * 8  // Approximate
                        Text("Vertices: ~\(vertexCount)")
                            .foregroundColor(.blue)
                        Text("Walls: \(walls.count)")
                    }
                case .fullMesh:
                    Text("Vertices: \(scan.vertexCount)")
                    Text("Faces: \(scan.faceCount)")
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                switch exportType {
                case .simplifiedRoom:
                    if let room = simplifiedRoom {
                        Text(String(format: "%.1f m²", room.floorArea))
                        Text(String(format: "Height: %.2f m", room.roomHeight))
                    }
                case .cleanWalls:
                    if let stats = scan.statistics, let height = stats.estimatedRoomHeight {
                        Text(String(format: "Height: %.2f m", height))
                        Text("No furniture")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                case .fullMesh:
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
    }

    @ViewBuilder
    private var reductionInfoView: some View {
        switch exportType {
        case .simplifiedRoom:
            if let room = simplifiedRoom {
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
        case .cleanWalls:
            HStack {
                Image(systemName: "cube.transparent")
                    .foregroundColor(.blue)
                Text("Clean architectural walls from floor to ceiling")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        case .fullMesh:
            EmptyView()
        }
    }

    @ViewBuilder
    private var surfaceBreakdownView: some View {
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

                surfaceDetailsView(stats: stats)
            }
        }
    }

    @ViewBuilder
    private func surfaceDetailsView(stats: ScanStatistics) -> some View {
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

    // MARK: - Export Format Section

    private var exportFormatSection: some View {
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
    }

    // MARK: - Action Buttons Section

    private var actionButtonsSection: some View {
        VStack(spacing: 12) {
            exportAllButton
            saveSessionButton
        }
    }

    private var exportAllButton: some View {
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
    }

    private var saveSessionButton: some View {
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
    }

    // MARK: - Status Messages Section

    @ViewBuilder
    private var statusMessagesSection: some View {
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
            VStack(spacing: 4) {
                Label("Session saved!", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(saveSuccessMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        }

        if isSavingSession {
            HStack {
                ProgressView()
                Text("Saving session...")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Toolbar & Alerts

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Done") { dismiss() }
        }
    }

    @ViewBuilder
    private var googleDriveAlertButtons: some View {
        Button("Open Share Sheet") {
            if let url = pendingShareURL {
                shareItem = ShareItem(url: url)
            }
        }
        Button("Cancel", role: .cancel) {}
    }


    private func handleFileExportResult(_ result: Result<URL, Error>) {
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
            exportType = .fullMesh
            return
        }

        // Configure simplifier from settings
        roomSimplifier.gridResolution = Float(settings.simplificationGridSize) / 100.0
        roomSimplifier.minWallLength = Float(settings.minWallLength) / 100.0

        simplifiedRoom = roomSimplifier.extractSimplifiedRoom(from: scan, statistics: stats)

        if simplifiedRoom == nil {
            exporter.lastError = "Could not simplify room (need floor/ceiling detection)"
            exportType = .fullMesh
        }
    }

    private func generateCleanWalls() {
        guard let stats = scan.statistics else {
            exporter.lastError = "No room statistics available for wall reconstruction"
            exportType = .fullMesh
            return
        }

        let walls = wallReconstructor.reconstruct(from: stats)

        if walls.isEmpty {
            exporter.lastError = "Could not reconstruct walls (need corner detection in Walls mode)"
            exportType = .fullMesh
        } else {
            reconstructedWalls = walls
        }
    }

    private func getExportScan() -> CapturedScan {
        switch exportType {
        case .simplifiedRoom:
            if let room = simplifiedRoom {
                let simplifiedMesh = roomSimplifier.generateMesh(from: room)
                var simplifiedScan = CapturedScan(startTime: scan.startTime)
                simplifiedScan.meshes = [simplifiedMesh]
                simplifiedScan.endTime = scan.endTime
                simplifiedScan.statistics = scan.statistics
                return simplifiedScan
            }

        case .cleanWalls:
            if let walls = reconstructedWalls, let stats = scan.statistics {
                // Generate wall mesh
                let wallMesh = wallReconstructor.generateMesh(walls: walls)

                // Generate floor and ceiling
                let corners = wallReconstructor.extractCorners(from: stats.detectedEdges)
                let floorCeilingMesh = wallReconstructor.generateFloorCeiling(
                    corners: corners,
                    floorY: stats.floorHeight ?? 0,
                    ceilingY: stats.ceilingHeight ?? 2.5
                )

                var cleanScan = CapturedScan(startTime: scan.startTime)
                cleanScan.meshes = [wallMesh, floorCeilingMesh]
                cleanScan.endTime = scan.endTime
                cleanScan.statistics = scan.statistics
                return cleanScan
            }

        case .fullMesh:
            break
        }

        return scan
    }

    private func saveSession() async {
        // Clear previous error
        saveErrorMessage = nil

        guard !sessionName.isEmpty else {
            saveErrorMessage = "Please enter a session name"
            return
        }

        guard !scan.meshes.isEmpty else {
            saveErrorMessage = "No mesh data to save. Scan something first."
            return
        }

        isSavingSession = true

        do {
            print("[ExportView] Saving session '\(sessionName)' to \(sessionSaveLocation.rawValue) with \(scan.meshes.count) meshes, \(scan.vertexCount) vertices")

            // Always save locally first (we need the file for cloud upload)
            let sessionId = try await sessionManager.saveSession(
                scan,
                name: sessionName,
                mode: scanMode
            )

            print("[ExportView] Session saved locally with ID: \(sessionId)")

            // Upload to cloud if requested
            switch sessionSaveLocation {
            case .local:
                // Already saved locally, nothing more to do
                break

            case .googleDrive:
                try await uploadSessionToGoogleDrive(sessionId: sessionId)

            case .iCloud:
                try await uploadSessionToiCloud(sessionId: sessionId)
            }

            // Dismiss sheet and show success
            showSaveSession = false
            saveErrorMessage = nil
            lastSaveLocation = sessionSaveLocation

            withAnimation {
                sessionSaveSuccess = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    sessionSaveSuccess = false
                }
            }
        } catch {
            print("[ExportView] Save failed: \(error)")
            saveErrorMessage = "Save failed: \(error.localizedDescription)"
            // Don't dismiss sheet - let user see the error and retry
        }

        isSavingSession = false
    }

    private func uploadSessionToGoogleDrive(sessionId: UUID) async throws {
        // Get the session file URL
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsDir = docs.appendingPathComponent("ScanSessions", isDirectory: true)
        let sessionURL = sessionsDir.appendingPathComponent("\(sessionId.uuidString).json")

        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            throw NSError(domain: "ExportView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session file not found"])
        }

        // Sign in if needed
        if !driveManager.isSignedIn {
            guard await driveManager.signIn() else {
                throw NSError(domain: "ExportView", code: 2, userInfo: [NSLocalizedDescriptionKey: driveManager.lastError ?? "Google Drive sign-in failed"])
            }
        }

        // Upload the file
        let success = await driveManager.uploadFile(at: sessionURL, mimeType: "application/json")

        guard success else {
            throw NSError(domain: "ExportView", code: 3, userInfo: [NSLocalizedDescriptionKey: driveManager.lastError ?? "Google Drive upload failed"])
        }

        print("[ExportView] Session uploaded to Google Drive")
    }

    private func uploadSessionToiCloud(sessionId: UUID) async throws {
        // Get the session file URL
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsDir = docs.appendingPathComponent("ScanSessions", isDirectory: true)
        let sessionURL = sessionsDir.appendingPathComponent("\(sessionId.uuidString).json")

        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            throw NSError(domain: "ExportView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session file not found locally"])
        }

        // Create a user-friendly filename with the session name
        let safeSessionName = sessionName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(safeSessionName)_\(sessionId.uuidString.prefix(8)).json"

        // Copy to temp location with friendly name for the picker
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.copyItem(at: sessionURL, to: tempURL)
        } catch {
            throw NSError(domain: "ExportView", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare file: \(error.localizedDescription)"])
        }

        // Store for the document picker and show it
        pendingSessionURL = tempURL
        pendingSessionId = sessionId

        // Dismiss the save session sheet first
        showSaveSession = false

        // Small delay to allow sheet to dismiss before showing picker
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds

        // Show document picker - this will handle the actual save
        showDocumentPicker = true

        print("[ExportView] Opening document picker for iCloud Drive save")
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

struct SaveSessionSheet: View {
    @Binding var sessionName: String
    @Binding var saveLocation: SessionSaveLocation
    @Binding var isSaving: Bool
    @Binding var errorMessage: String?
    let meshCount: Int
    let vertexCount: Int
    let isGoogleDriveConfigured: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var isNameFocused: Bool

    private var canSave: Bool {
        !sessionName.isEmpty && !isSaving && meshCount > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Session name input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Session Name")
                            .font(.headline)

                        TextField("Enter name for this scan", text: $sessionName)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)
                            .submitLabel(.done)
                            .onChange(of: sessionName) { _ in
                                // Clear error when user starts typing
                                errorMessage = nil
                            }
                    }
                    .padding(.horizontal)

                    // Save location picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save Location")
                            .font(.headline)

                        ForEach(SessionSaveLocation.allCases) { location in
                            SaveLocationRow(
                                location: location,
                                isSelected: saveLocation == location,
                                isAvailable: isLocationAvailable(location)
                            ) {
                                if isLocationAvailable(location) {
                                    saveLocation = location
                                    errorMessage = nil
                                }
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Show scan info
                    HStack(spacing: 20) {
                        VStack {
                            Text("\(meshCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(meshCount > 0 ? .primary : .red)
                            Text("Meshes")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        VStack {
                            Text("\(vertexCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("Vertices")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)

                    // Error message
                    if let error = errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("Save Failed")
                                    .font(.headline)
                                    .foregroundColor(.red)
                            }
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }

                    if meshCount == 0 {
                        Text("No scan data to save. Please scan something first.")
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else if errorMessage == nil {
                        Text(locationHelpText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    VStack(spacing: 12) {
                        Button(action: onSave) {
                            HStack {
                                if isSaving {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                }
                                Image(systemName: saveLocation.icon)
                                Text(isSaving ? savingText : "Save to \(saveLocation.rawValue)")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(canSave ? Color.green : Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(!canSave)

                        Button("Cancel", action: onCancel)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .padding(.top)
            }
            .navigationTitle("Save Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onAppear {
                isNameFocused = true
                errorMessage = nil
            }
        }
        .presentationDetents([.large, .medium])
    }

    private func isLocationAvailable(_ location: SessionSaveLocation) -> Bool {
        switch location {
        case .local:
            return true
        case .googleDrive:
            return isGoogleDriveConfigured
        case .iCloud:
            // Document picker is always available - user can save to any location
            return true
        }
    }

    private var locationHelpText: String {
        switch saveLocation {
        case .local:
            return "Save to device storage. Access from Saved Scans tab."
        case .googleDrive:
            return "Save locally and upload to Google Drive for backup."
        case .iCloud:
            return "Save locally, then choose where in iCloud Drive. Visible on icloud.com."
        }
    }

    private var savingText: String {
        switch saveLocation {
        case .local:
            return "Saving..."
        case .googleDrive:
            return "Uploading to Drive..."
        case .iCloud:
            return "Preparing..."
        }
    }
}

struct SaveLocationRow: View {
    let location: SessionSaveLocation
    let isSelected: Bool
    let isAvailable: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: location.icon)
                    .font(.title3)
                    .foregroundColor(iconColor)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(location.rawValue)
                            .font(.body)
                            .foregroundColor(isAvailable ? .primary : .secondary)

                        if !isAvailable {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    if !isAvailable {
                        Text(unavailableReason)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    } else {
                        Text(location.description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isSelected && isAvailable {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if !isAvailable {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.gray)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(backgroundForState)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected && isAvailable ? Color.green : Color.clear, lineWidth: 2)
            )
        }
        .disabled(!isAvailable)
    }

    private var backgroundForState: Color {
        if !isAvailable {
            return Color.orange.opacity(0.05)
        } else if isSelected {
            return Color.green.opacity(0.1)
        } else {
            return Color.gray.opacity(0.05)
        }
    }

    private var iconColor: Color {
        if !isAvailable {
            return .gray
        }
        switch location {
        case .local:
            return .blue
        case .googleDrive:
            return .green
        case .iCloud:
            return .cyan
        }
    }

    private var unavailableReason: String {
        switch location {
        case .local:
            return ""
        case .googleDrive:
            return "Configure in Settings → Google Drive"
        case .iCloud:
            if FileManager.default.ubiquityIdentityToken == nil {
                return "Sign in to iCloud in device Settings"
            } else {
                return "Enable iCloud Drive in device Settings"
            }
        }
    }
}

// Helper to check iCloud status
struct iCloudStatus {
    static var isSignedIn: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    static var isContainerAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
    }

    static var statusMessage: String {
        if !isSignedIn {
            return "Not signed in to iCloud"
        } else if !isContainerAvailable {
            return "iCloud Drive not enabled for this app"
        } else {
            return "iCloud ready"
        }
    }
}

// Document picker for saving to iCloud Drive (visible on icloud.com)
struct DocumentPickerView: UIViewControllerRepresentable {
    let url: URL
    let onSuccess: () -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess, onCancel: onCancel)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSuccess: () -> Void
        let onCancel: () -> Void

        init(onSuccess: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.onSuccess = onSuccess
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            print("[DocumentPicker] File saved to: \(urls.first?.path ?? "unknown")")
            onSuccess()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            print("[DocumentPicker] Cancelled")
            onCancel()
        }
    }
}
