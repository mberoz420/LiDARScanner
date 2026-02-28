import SwiftUI

struct ContentView: View {
    @StateObject private var versionTracker = VersionTracker()
    @StateObject private var updateChecker = UpdateChecker()
    @State private var showSettings = false
    @State private var selectedMode: ScanMode?

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
                }
                .padding(.horizontal)
                .padding(.top, 10)

                // 6-Square Grid
                LazyVGrid(columns: columns, spacing: 16) {
                    // App Settings
                    MainMenuSquare(
                        title: "App Settings",
                        icon: "gear",
                        color: .gray,
                        action: { showSettings = true }
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
        .fullScreenCover(item: $selectedMode) { mode in
            ScanModeView(mode: mode)
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
    @StateObject private var meshManager = MeshManager()
    @State private var showModeSettings = false
    @State private var showExport = false
    @State private var capturedScan: CapturedScan?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(meshManager: meshManager)
                .edgesIgnoringSafeArea(.all)

            VStack {
                // Top Bar
                HStack {
                    // Back button
                    Button(action: { dismiss() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("Menu")
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(20)
                    }

                    Spacer()

                    // Mode info
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: mode.icon)
                                .foregroundColor(mode.color)
                            Text(mode.rawValue)
                                .fontWeight(.bold)
                        }
                        .font(.subheadline)

                        Text(meshManager.scanStatus)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(12)
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

                // Stats during scanning
                if meshManager.isScanning {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Vertices: \(meshManager.vertexCount)")
                                .font(.caption)
                            DeviceOrientationIndicator(orientation: meshManager.deviceOrientation)
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .cornerRadius(8)

                        Spacer()
                    }
                    .padding(.horizontal)
                }

                // Bottom controls
                HStack(spacing: 20) {
                    // Settings button
                    Button(action: { showModeSettings = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.title2)
                            Text("Settings")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                        .frame(width: 70, height: 70)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(16)
                    }
                    .disabled(meshManager.isScanning)

                    // Start/Stop button
                    Button(action: toggleScanning) {
                        VStack(spacing: 4) {
                            Image(systemName: meshManager.isScanning ? "stop.fill" : "play.fill")
                                .font(.system(size: 30))
                            Text(meshManager.isScanning ? "Stop" : "Start")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(width: 90, height: 90)
                        .background(
                            Circle()
                                .fill(meshManager.isScanning ? Color.red : Color.green)
                        )
                    }

                    // Export button
                    if capturedScan != nil && !meshManager.isScanning {
                        Button(action: { showExport = true }) {
                            VStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title2)
                                Text("Export")
                                    .font(.caption2)
                            }
                            .foregroundColor(.white)
                            .frame(width: 70, height: 70)
                            .background(Color.blue)
                            .cornerRadius(16)
                        }
                    } else {
                        Color.clear.frame(width: 70, height: 70)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            meshManager.currentMode = mode
        }
        .sheet(isPresented: $showModeSettings) {
            ModeSettingsView(mode: mode)
        }
        .sheet(isPresented: $showExport) {
            if let scan = capturedScan {
                ExportView(scan: scan)
            }
        }
    }

    private func toggleScanning() {
        if meshManager.isScanning {
            capturedScan = meshManager.stopScanning()
        } else {
            capturedScan = nil
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

    var body: some View {
        Section("Room Scanning") {
            Toggle("Surface Classification", isOn: $surfaceClassification)
            Toggle("Detect Doors & Windows", isOn: $detectDoorsWindows)
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

#Preview {
    ContentView()
}
