import SwiftUI

struct ContentView: View {
    @StateObject private var versionTracker = VersionTracker()
    @StateObject private var updateChecker = UpdateChecker()
    @State private var showSettings = false
    @State private var showSavedScans = false
    @State private var selectedMode: ScanMode?
    @State private var resumeSessionId: UUID?
    @State private var resumeRepairMode = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LiDarScanner-Wizard")
                            .font(.title2)
                            .fontWeight(.bold)

                        HStack(spacing: 8) {
                            Text("v\(versionTracker.fullVersion)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // Update indicator
                            if let update = updateChecker.updateAvailable {
                                Button(action: { updateChecker.showUpdateProgress = true }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text("Update")
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green)
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }

                    Spacer()

                    // Check update button
                    Button(action: {
                        Task { await updateChecker.forceCheckForUpdates() }
                    }) {
                        if updateChecker.isChecking {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.title3)
                                .foregroundColor(.blue)
                        }
                    }
                    .disabled(updateChecker.isChecking)

                    // Settings button
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gear")
                            .font(.title3)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)

                // 6-Square Grid
                LazyVGrid(columns: columns, spacing: 16) {
                    // Saved Scans
                    MainMenuSquare(
                        title: "Saved Scans",
                        icon: "square.stack.3d.up",
                        color: .indigo,
                        action: { showSavedScans = true }
                    )

                    // Fast Scan
                    MainMenuSquare(
                        title: "Fast Scan",
                        icon: ScanMode.fast.icon,
                        color: ScanMode.fast.color,
                        action: { selectedMode = .fast }
                    )

                    // Walls & Rooms
                    MainMenuSquare(
                        title: "Walls & Rooms",
                        icon: ScanMode.walls.icon,
                        color: ScanMode.walls.color,
                        action: { selectedMode = .walls }
                    )

                    // Large Objects
                    MainMenuSquare(
                        title: "Large Objects",
                        icon: ScanMode.largeObjects.icon,
                        color: ScanMode.largeObjects.color,
                        action: { selectedMode = .largeObjects }
                    )

                    // Small Objects
                    MainMenuSquare(
                        title: "Small Objects",
                        icon: ScanMode.smallObjects.icon,
                        color: ScanMode.smallObjects.color,
                        action: { selectedMode = .smallObjects }
                    )

                    // Organic & Faces
                    MainMenuSquare(
                        title: "Organic & Faces",
                        icon: ScanMode.organic.icon,
                        color: ScanMode.organic.color,
                        action: { selectedMode = .organic }
                    )
                }
                .padding(.horizontal)

                Spacer()

                // Footer info
                Text("3D scanning with texture capture")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
        }
        .sheet(isPresented: $versionTracker.shouldShowWhatsNew, onDismiss: {
            versionTracker.markAsSeen()
        }) {
            WhatsNewView(version: versionTracker.fullVersion)
        }
        .sheet(isPresented: $showSettings) {
            AppSettingsView()
        }
        .sheet(isPresented: $showSavedScans) {
            SavedSessionsView()
        }
        .fullScreenCover(item: $selectedMode, onDismiss: {
            // Reset resume state after scanning session ends
            resumeSessionId = nil
            resumeRepairMode = false
        }) { mode in
            ScanModeView(
                mode: mode,
                resumeSessionId: resumeSessionId,
                resumeRepairMode: resumeRepairMode
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeScanSession)) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? UUID,
               let repairMode = notification.userInfo?["repairMode"] as? Bool {
                // Get the scan mode from session metadata
                if let session = ScanSessionManager.shared.savedSessions.first(where: { $0.id == sessionId }) {
                    resumeSessionId = sessionId
                    resumeRepairMode = repairMode
                    selectedMode = ScanMode(rawValue: session.scanMode) ?? .fast
                }
            }
        }
        .sheet(isPresented: $updateChecker.showUpdateProgress) {
            UpdateProgressView(updateChecker: updateChecker)
        }
        .updateCompleteAlert(isPresented: $updateChecker.showUpdateComplete, version: versionTracker.fullVersion)
        .checkForUpdates(using: updateChecker)
        .task {
            await updateChecker.checkForUpdates()
        }
    }
}

// MARK: - Main Menu Square

struct MainMenuSquare: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundColor(.white)

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(color.gradient)
                    .shadow(color: color.opacity(0.4), radius: 8, x: 0, y: 4)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Scan Mode View (Full Screen)

struct ScanModeView: View {
    let mode: ScanMode
    var resumeSessionId: UUID? = nil
    var resumeRepairMode: Bool = false

    @StateObject private var meshManager = MeshManager()
    @ObservedObject private var sessionManager = ScanSessionManager.shared
    @State private var showModeSettings = false
    @State private var showExport = false
    @State private var capturedScan: CapturedScan?
    @State private var isLoadingSession = false
    @State private var repairModeEnabled = false
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(meshManager: meshManager)
                .edgesIgnoringSafeArea(.all)

            // Loading overlay for session resume
            if isLoadingSession {
                Color.black.opacity(0.7)
                    .edgesIgnoringSafeArea(.all)
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Loading session...")
                        .foregroundColor(.white)
                        .font(.headline)
                }
            }

            // Edge detection reticle (center of screen)
            if meshManager.isScanning && mode == .walls {
                VStack {
                    // Active input methods + confirmed corners
                    HStack(spacing: 8) {
                        // Active input method icons
                        InputMethodIndicator()

                        if meshManager.isListening {
                            HStack(spacing: 4) {
                                Image(systemName: "mic.fill")
                                    .foregroundColor(.red)
                                Text("Listening")
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(12)
                        }

                        if meshManager.confirmedCornerCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("\(meshManager.confirmedCornerCount) corners")
                            }
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(12)
                        }
                    }
                    .offset(y: -60)

                    EdgeTargetReticle(
                        edgeDetected: meshManager.edgeInReticle,
                        edgeConfirmed: meshManager.edgeConfirmed,
                        isPaused: meshManager.isPaused
                    )

                    // Last voice command indicator
                    if let command = meshManager.lastVoiceCommand {
                        Text("Voice: \"\(command)\"")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(12)
                            .offset(y: 60)
                            .transition(.opacity)
                    }
                }
            }

            VStack {
                // Top Bar - minimal
                HStack {
                    // Back button
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }

                    Spacer()

                    // Repair mode indicator (when resuming)
                    if resumeSessionId != nil && repairModeEnabled {
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.and.screwdriver")
                            Text("Repair")
                        }
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange)
                        .cornerRadius(8)
                    }

                    // Mode badge
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .foregroundColor(mode.color)
                        Text(mode.rawValue)
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(20)
                }
                .padding()

                Spacer()

                // Guided room scanning UI
                if meshManager.isScanning && mode == .walls && meshManager.useEdgeVisualization {
                    RoomScanPhaseIndicator(
                        phase: meshManager.currentPhase,
                        progress: meshManager.phaseProgress,
                        stats: meshManager.surfaceClassifier.statistics,
                        onSkip: { meshManager.skipPhase() }
                    )
                    .padding(.horizontal)
                }

                // Status bar at bottom (narrow, transparent)
                if meshManager.isScanning {
                    ScanStatusBar(
                        status: meshManager.scanStatus,
                        vertexCount: meshManager.vertexCount,
                        orientation: meshManager.deviceOrientation
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                // Bottom controls
                HStack(spacing: 20) {
                    // Settings button
                    Button(action: { showModeSettings = true }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(14)
                    }
                    .disabled(meshManager.isScanning)
                    .opacity(meshManager.isScanning ? 0.5 : 1)

                    // Start/Stop button
                    Button(action: toggleScanning) {
                        Image(systemName: meshManager.isScanning ? "stop.fill" : "play.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .frame(width: 80, height: 80)
                            .background(
                                Circle()
                                    .fill(meshManager.isScanning ? Color.red : Color.green)
                            )
                    }

                    // Export button
                    if capturedScan != nil && !meshManager.isScanning {
                        Button(action: { showExport = true }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(Color.blue)
                                .cornerRadius(14)
                        }
                    } else {
                        Color.clear.frame(width: 56, height: 56)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            meshManager.currentMode = mode
            repairModeEnabled = resumeRepairMode

            // Load session if resuming
            if let sessionId = resumeSessionId {
                Task {
                    await loadResumeSession(sessionId)
                }
            }
        }
        .sheet(isPresented: $showModeSettings) {
            ModeSettingsView(mode: mode)
        }
        .sheet(isPresented: $showExport) {
            if let scan = capturedScan {
                ExportView(scan: scan, scanMode: mode)
            }
        }
        .alert("Load Error", isPresented: .init(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button("OK") { loadError = nil }
        } message: {
            if let error = loadError {
                Text(error)
            }
        }
    }

    private func loadResumeSession(_ sessionId: UUID) async {
        isLoadingSession = true

        do {
            let result = try await sessionManager.loadSession(sessionId)
            capturedScan = result.scan
            meshManager.loadExistingMeshes(result.scan, repairMode: repairModeEnabled)
            meshManager.scanStatus = "Session loaded - tap Start to continue"
        } catch {
            loadError = error.localizedDescription
        }

        isLoadingSession = false
    }

    private func toggleScanning() {
        if meshManager.isScanning {
            capturedScan = meshManager.stopScanning()

            // Auto-save if resuming a session
            if let sessionId = resumeSessionId, let scan = capturedScan {
                Task {
                    try? await sessionManager.updateSession(sessionId, with: scan)
                }
            }
        } else {
            // If not resuming, clear the scan
            if resumeSessionId == nil {
                capturedScan = nil
            }
            meshManager.startScanning()
        }
    }
}

// MARK: - Mode Settings View

struct ModeSettingsView: View {
    let mode: ScanMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: mode.icon)
                            .font(.title)
                            .foregroundColor(mode.color)
                            .frame(width: 50)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.rawValue)
                                .font(.headline)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Specifications") {
                    SettingRow(label: "Object Size", value: mode.sizeRange)
                    SettingRow(label: "Distance", value: mode.optimalDistance)
                    SettingRow(label: "Accuracy", value: mode.accuracy)
                    SettingRow(label: "Min Detail", value: mode.minFeatureSize)
                }

                Section("Tips") {
                    ForEach(mode.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text(tip)
                                .font(.subheadline)
                        }
                    }
                }

                // Mode-specific settings
                switch mode {
                case .walls:
                    WallsModeSettings()
                case .smallObjects:
                    SmallObjectsSettings()
                case .organic:
                    OrganicModeSettings()
                default:
                    EmptyView()
                }
            }
            .navigationTitle("\(mode.rawValue) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SettingRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Mode-Specific Settings

struct WallsModeSettings: View {
    @AppStorage("surfaceClassificationEnabled") private var surfaceClassification = true
    @AppStorage("detectDoorsWindows") private var detectDoorsWindows = true

    // Input methods
    @AppStorage("autoDetectionEnabled") private var autoDetection = true
    @AppStorage("pauseGestureEnabled") private var pauseGesture = true
    @AppStorage("voiceCommandsEnabled") private var voiceCommands = true

    // Feedback
    @AppStorage("speechFeedbackEnabled") private var speechFeedback = true
    @AppStorage("hapticFeedbackEnabled") private var hapticFeedback = true

    var body: some View {
        Section("Room Scanning") {
            Toggle("Surface Classification", isOn: $surfaceClassification)
            Toggle("Detect Doors & Windows", isOn: $detectDoorsWindows)
        }

        Section {
            Toggle(isOn: $autoDetection) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Auto Detection", systemImage: "eye")
                    Text("Automatically detect edges and corners")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Toggle(isOn: $pauseGesture) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Pause Gesture", systemImage: "hand.raised")
                    Text("Hold phone still over edge to confirm")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Toggle(isOn: $voiceCommands) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Voice Commands", systemImage: "mic.fill")
                    Text("Say: edge, corner, door, window, furniture")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Input Methods")
        } footer: {
            Text("Enable one or more methods to mark corners and features. Try different combinations to find what works best.")
        }

        Section("Feedback") {
            Toggle(isOn: $speechFeedback) {
                Label("Voice Feedback", systemImage: "speaker.wave.2")
            }
            Toggle(isOn: $hapticFeedback) {
                Label("Haptic Feedback", systemImage: "iphone.radiowaves.left.and.right")
            }
        }
    }
}

struct SmallObjectsSettings: View {
    @AppStorage("highPrecisionMode") private var highPrecision = true

    var body: some View {
        Section("Precision") {
            Toggle("High Precision Mode", isOn: $highPrecision)
        }
    }
}

struct OrganicModeSettings: View {
    @AppStorage("useFrontCamera") private var useFrontCamera = false

    var body: some View {
        Section("Camera") {
            Toggle("Use Front Camera (Face)", isOn: $useFrontCamera)
        }
    }
}

// MARK: - App Settings View (General)

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultExportFormat") private var defaultFormat = "USDZ"
    @AppStorage("autoSaveScans") private var autoSave = false
    @AppStorage("versionCheckURL") private var versionCheckURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Export") {
                    Picker("Default Format", selection: $defaultFormat) {
                        Text("USDZ").tag("USDZ")
                        Text("PLY").tag("PLY")
                        Text("OBJ").tag("OBJ")
                    }
                    Toggle("Auto-save Scans", isOn: $autoSave)
                }

                Section("Updates") {
                    TextField("Version Check URL", text: $versionCheckURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                }

                Section("About") {
                    HStack {
                        Text("App")
                        Spacer()
                        Text("LiDarScanner-Wizard")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("App Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Scan Status Bar (Bottom)

struct ScanStatusBar: View {
    let status: String
    let vertexCount: Int
    let orientation: DeviceOrientation

    var body: some View {
        HStack(spacing: 12) {
            // Status text
            Text(status)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            // Vertex count
            HStack(spacing: 4) {
                Image(systemName: "cube")
                    .font(.caption2)
                Text("\(formatCount(vertexCount))")
                    .font(.caption)
                    .fontWeight(.medium)
            }

            // Orientation indicator
            DeviceOrientationIndicator(orientation: orientation)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
        )
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1000000 {
            return String(format: "%.1fM", Double(n) / 1000000)
        } else if n >= 1000 {
            return String(format: "%.1fK", Double(n) / 1000)
        }
        return "\(n)"
    }
}

// MARK: - Edge Target Reticle

struct EdgeTargetReticle: View {
    let edgeDetected: Bool
    var edgeConfirmed: Bool = false
    var isPaused: Bool = false

    @AppStorage("autoDetectionEnabled") private var autoDetection = true
    @AppStorage("pauseGestureEnabled") private var pauseGesture = true

    // Colors based on state
    private var mainColor: Color {
        if edgeConfirmed {
            return .yellow  // Confirmed - strong feedback
        } else if edgeDetected {
            return .green   // Edge in view (auto-detection)
        } else if isPaused && pauseGesture {
            if autoDetection {
                return .orange  // Paused but no edge detected
            } else {
                return .cyan    // Manual mode - ready to mark
            }
        } else {
            return .white.opacity(0.5)  // Scanning
        }
    }

    private var lineWidth: CGFloat {
        edgeConfirmed ? 3 : 2
    }

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(mainColor, lineWidth: lineWidth)
                .frame(width: 80, height: 80)

            // Inner crosshair
            Group {
                // Horizontal line
                Rectangle()
                    .fill(mainColor)
                    .frame(width: 30, height: 2)

                // Vertical line
                Rectangle()
                    .fill(mainColor)
                    .frame(width: 2, height: 30)
            }

            // Corner brackets
            ForEach(0..<4, id: \.self) { i in
                CornerBracket(color: mainColor, lineWidth: lineWidth)
                    .rotationEffect(.degrees(Double(i) * 90))
            }

            // Center indicator based on state
            if edgeConfirmed {
                // Confirmed - solid yellow with checkmark feel
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 16, height: 16)

                // Expanding ring animation for confirmation
                Circle()
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: 60, height: 60)
                    .scaleEffect(1.3)
                    .opacity(0.6)

                // "LOCKED" text indicator
                Text("EDGE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.yellow)
                    .offset(y: 55)

            } else if edgeDetected {
                // Edge in view - green dot
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                // Pulsing effect
                Circle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: 60, height: 60)
                    .opacity(0.5)
                    .scaleEffect(1.2)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: edgeDetected)

                // Instruction
                Text("Hold still")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green)
                    .offset(y: 55)

            } else if isPaused && pauseGesture {
                if autoDetection {
                    // Paused but no edge detected
                    Circle()
                        .stroke(Color.orange, lineWidth: 1)
                        .frame(width: 12, height: 12)

                    Text("No edge")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.orange)
                        .offset(y: 55)
                } else {
                    // Manual mode - will mark on pause
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 12, height: 12)

                    Text("Marking...")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.cyan)
                        .offset(y: 55)
                }
            }
        }
    }
}

struct CornerBracket: View {
    let color: Color
    var lineWidth: CGFloat = 2

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 35, y: 0))
            path.addLine(to: CGPoint(x: 35, y: -10))
            path.addLine(to: CGPoint(x: 25, y: -10))
        }
        .stroke(color, lineWidth: lineWidth)
        .offset(y: -35)
    }
}

// MARK: - Input Method Indicator

struct InputMethodIndicator: View {
    @AppStorage("autoDetectionEnabled") private var autoDetection = true
    @AppStorage("pauseGestureEnabled") private var pauseGesture = true
    @AppStorage("voiceCommandsEnabled") private var voiceCommands = true

    var body: some View {
        HStack(spacing: 6) {
            if autoDetection {
                Image(systemName: "eye")
                    .foregroundColor(.green)
            }
            if pauseGesture {
                Image(systemName: "hand.raised")
                    .foregroundColor(.cyan)
            }
            if voiceCommands {
                Image(systemName: "mic")
                    .foregroundColor(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.6))
        .cornerRadius(12)
    }
}

#Preview {
    ContentView()
}
