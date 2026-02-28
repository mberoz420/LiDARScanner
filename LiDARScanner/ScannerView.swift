import SwiftUI
import ARKit
import RealityKit

struct ScannerView: View {
    @StateObject private var meshManager = MeshManager()
    @State private var showExport = false
    @State private var showModeSelector = false
    @State private var capturedScan: CapturedScan?

    var body: some View {
        ZStack {
            ARViewContainer(meshManager: meshManager)
                .edgesIgnoringSafeArea(.all)

            // Trial 1: Wall-ceiling detection overlay
            if AppSettings.shared.trial1Enabled && meshManager.isScanning {
                Trial1OverlayView(
                    detector: meshManager.trial1Detector,
                    floorHeight: meshManager.surfaceClassifier.statistics.floorHeight
                )
            }

            VStack {
                // Top bar with stats and mode
                HStack {
                    // Stats overlay - tap to change mode when not scanning
                    Button(action: {
                        if !meshManager.isScanning {
                            showModeSelector = true
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: meshManager.currentMode.icon)
                                    .foregroundColor(meshManager.currentMode.color)
                                Text(meshManager.currentMode.rawValue)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                if !meshManager.isScanning {
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                            }
                            Text(meshManager.scanStatus)
                                .font(.caption2)
                                .lineLimit(2)
                            if meshManager.isScanning {
                                HStack(spacing: 8) {
                                    Text("Vertices: \(meshManager.vertexCount)")
                                        .font(.caption2)
                                    // Show device orientation indicator
                                    DeviceOrientationIndicator(orientation: meshManager.deviceOrientation)
                                }
                            } else {
                                Text("Tap to change mode")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(meshManager.isScanning)

                    Spacer()

                    VStack(spacing: 8) {
                        // Camera toggle for organic mode
                        if meshManager.currentMode == .organic && meshManager.faceTrackingAvailable {
                            Button(action: { meshManager.toggleCamera() }) {
                                Image(systemName: meshManager.usingFrontCamera ? "camera.rotate" : "camera.rotate.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.black.opacity(0.7))
                                    .cornerRadius(22)
                            }
                        }

                        // Surface classification toggle
                        if meshManager.isScanning && meshManager.currentMode == .walls {
                            Button(action: {
                                meshManager.surfaceClassificationEnabled.toggle()
                            }) {
                                Image(systemName: meshManager.surfaceClassificationEnabled ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
                                    .font(.title3)
                                    .foregroundColor(meshManager.surfaceClassificationEnabled ? .cyan : .white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.black.opacity(0.7))
                                    .cornerRadius(22)
                            }
                        }
                    }
                }
                .padding()

                Spacer()

                // Guided room scanning UI
                if meshManager.isScanning && meshManager.currentMode == .walls && meshManager.useEdgeVisualization {
                    RoomScanPhaseIndicator(
                        phase: meshManager.currentPhase,
                        progress: meshManager.phaseProgress,
                        stats: meshManager.surfaceClassifier.statistics,
                        onSkip: { meshManager.skipPhase() }
                    )
                    .padding(.horizontal)
                }
                // Surface type legend (when classification is enabled but NOT in guided mode)
                else if meshManager.isScanning && meshManager.surfaceClassificationEnabled && meshManager.currentMode == .walls && !meshManager.useEdgeVisualization {
                    HStack {
                        SurfaceTypeLegend()
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                // Quick mode selector (when not scanning)
                if !meshManager.isScanning {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ScanMode.allCases) { mode in
                                QuickModeButton(
                                    mode: mode,
                                    isSelected: mode == meshManager.currentMode,
                                    action: { meshManager.currentMode = mode }
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 8)
                }

                // Controls
                HStack(spacing: 16) {
                    // Mode selector button
                    Button(action: { showModeSelector = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: meshManager.currentMode.icon)
                                .font(.title2)
                            Text("Mode")
                                .font(.caption2)
                        }
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(meshManager.isScanning ? Color.gray.opacity(0.5) : meshManager.currentMode.color)
                        .cornerRadius(12)
                    }
                    .disabled(meshManager.isScanning)

                    // Start/Stop button
                    Button(action: toggleScanning) {
                        Text(meshManager.isScanning ? "Stop" : "Start")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 100, height: 50)
                            .background(meshManager.isScanning ? Color.red : Color.green)
                            .cornerRadius(25)
                    }

                    // Export button
                    if capturedScan != nil && !meshManager.isScanning {
                        Button(action: { showExport = true }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.blue)
                                .cornerRadius(25)
                        }
                    } else {
                        // Placeholder to keep layout balanced
                        Color.clear.frame(width: 50, height: 50)
                    }
                }
                .padding(.bottom, 50)
            }
        }
        .navigationTitle("Scanner")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) {
            if let scan = capturedScan {
                ExportView(scan: scan)
            }
        }
        .sheet(isPresented: $showModeSelector) {
            ModeSelectorView(selectedMode: $meshManager.currentMode)
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

struct ModeSelectorView: View {
    @Binding var selectedMode: ScanMode
    @Environment(\.dismiss) private var dismiss
    @State private var expandedMode: ScanMode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(ScanMode.allCases) { mode in
                        ModeCard(
                            mode: mode,
                            isSelected: mode == selectedMode,
                            isExpanded: mode == expandedMode,
                            onSelect: {
                                selectedMode = mode
                                dismiss()
                            },
                            onToggleExpand: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedMode = expandedMode == mode ? nil : mode
                                }
                            }
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Scan Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ModeCard: View {
    let mode: ScanMode
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            Button(action: onSelect) {
                HStack(spacing: 16) {
                    Image(systemName: mode.icon)
                        .font(.title2)
                        .foregroundColor(mode.color)
                        .frame(width: 40)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.rawValue)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(mode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                .padding()
            }

            // Info toggle button
            Button(action: onToggleExpand) {
                HStack {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text(isExpanded ? "Hide Details" : "Show Details")
                        .font(.caption)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .foregroundColor(.blue)
                .padding(.horizontal)
                .padding(.bottom, isExpanded ? 8 : 12)
            }

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()

                    // Specs grid
                    HStack(spacing: 16) {
                        SpecItem(title: "Object Size", value: mode.sizeRange, icon: "ruler")
                        SpecItem(title: "Distance", value: mode.optimalDistance, icon: "arrow.left.and.right")
                    }

                    HStack(spacing: 16) {
                        SpecItem(title: "Accuracy", value: mode.accuracy, icon: "scope")
                        SpecItem(title: "Min Detail", value: mode.minFeatureSize, icon: "magnifyingglass")
                    }

                    Divider()

                    // Tips
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tips")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        ForEach(mode.tips, id: \.self) { tip in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lightbulb.fill")
                                    .font(.caption2)
                                    .foregroundColor(.yellow)
                                Text(tip)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    // Guidance
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.fill")
                            .foregroundColor(mode.color)
                        Text(mode.guidanceText)
                            .font(.caption)
                            .italic()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
        }
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? mode.color : Color.clear, lineWidth: 2)
        )
    }
}

struct SpecItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ARViewContainer: UIViewRepresentable {
    let meshManager: MeshManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Configure AR session with mesh reconstruction
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]

        arView.session.run(config)

        Task { @MainActor in
            meshManager.setup(arView: arView)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Device Orientation Indicator

struct DeviceOrientationIndicator: View {
    let orientation: DeviceOrientation

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption2)
                .foregroundColor(iconColor)
            Text(shortLabel)
                .font(.caption2)
                .foregroundColor(iconColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(iconColor.opacity(0.2))
        .cornerRadius(4)
    }

    private var iconName: String {
        switch orientation {
        case .lookingUp:
            return "arrow.up.circle.fill"
        case .lookingSlightlyUp:
            return "arrow.up.right.circle"
        case .lookingHorizontal:
            return "arrow.right.circle"
        case .lookingSlightlyDown:
            return "arrow.down.right.circle"
        case .lookingDown:
            return "arrow.down.circle.fill"
        }
    }

    private var shortLabel: String {
        switch orientation {
        case .lookingUp: return "Ceiling"
        case .lookingSlightlyUp: return "Up"
        case .lookingHorizontal: return "Level"
        case .lookingSlightlyDown: return "Down"
        case .lookingDown: return "Floor"
        }
    }

    private var iconColor: Color {
        switch orientation {
        case .lookingUp:
            return .yellow
        case .lookingDown:
            return .green
        default:
            return .blue
        }
    }
}

// MARK: - Surface Type Legend

struct SurfaceTypeLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Surfaces")
                .font(.caption2)
                .fontWeight(.bold)

            ForEach([SurfaceType.floor, .ceiling, .ceilingProtrusion, .wall, .door, .window, .object], id: \.rawValue) { type in
                HStack(spacing: 6) {
                    Circle()
                        .fill(colorFor(type))
                        .frame(width: 8, height: 8)
                    Text(type.rawValue)
                        .font(.caption2)
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.7))
        .foregroundColor(.white)
        .cornerRadius(8)
    }

    private func colorFor(_ type: SurfaceType) -> Color {
        let c = type.color
        return Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b))
    }
}

// MARK: - Quick Mode Button

struct QuickModeButton: View {
    let mode: ScanMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.title3)
                Text(mode.rawValue)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 70, height: 60)
            .background(isSelected ? mode.color.opacity(0.3) : Color.black.opacity(0.5))
            .foregroundColor(isSelected ? mode.color : .white)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? mode.color : Color.clear, lineWidth: 2)
            )
        }
    }
}

// MARK: - Room Scan Phase Indicator

struct RoomScanPhaseIndicator: View {
    let phase: RoomScanPhase
    let progress: Double
    let stats: ScanStatistics
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Phase progress steps
            HStack(spacing: 4) {
                ForEach(RoomScanPhase.allCases.filter { $0 != .ready }, id: \.id) { p in
                    PhaseStep(
                        phase: p,
                        isActive: p == phase,
                        isComplete: phaseIndex(p) < phaseIndex(phase)
                    )
                }
            }

            // Current phase info
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: phase.icon)
                            .foregroundColor(phase.color)
                        Text(phase.rawValue)
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .lineLimit(1)
                    }

                    Text(phase.detailedHint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // Progress bar
                    if phase != .complete && phase != .ready {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.2))
                                Rectangle()
                                    .fill(phase.color)
                                    .frame(width: geo.size.width * CGFloat(progress))
                            }
                        }
                        .frame(height: 4)
                        .cornerRadius(2)
                    }
                }

                Spacer()

                // Skip button (except for complete phase)
                if phase != .complete && phase != .ready {
                    Button(action: onSkip) {
                        Text("Skip")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.gray.opacity(0.5))
                            .cornerRadius(12)
                    }
                }
            }

            // Room dimensions (when complete)
            if phase == .complete, let dims = stats.roomDimensions {
                HStack(spacing: 16) {
                    DimensionLabel(label: "Width", value: dims.width)
                    DimensionLabel(label: "Depth", value: dims.depth)
                    DimensionLabel(label: "Height", value: dims.height)
                }
                .padding(.top, 4)
            }

            // Stats summary
            if phase == .walls || phase == .complete {
                HStack(spacing: 16) {
                    StatBadge(icon: "square.dashed", value: "\(stats.cornerCount)", label: "Corners")
                    if !stats.detectedDoors.isEmpty {
                        StatBadge(icon: "door.left.hand.open", value: "\(stats.detectedDoors.count)", label: "Doors")
                    }
                    if !stats.detectedWindows.isEmpty {
                        StatBadge(icon: "window.horizontal", value: "\(stats.detectedWindows.count)", label: "Windows")
                    }
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
        .foregroundColor(.white)
        .cornerRadius(12)
    }

    private func phaseIndex(_ p: RoomScanPhase) -> Int {
        switch p {
        case .ready: return 0
        case .floor: return 1
        case .ceiling: return 2
        case .walls: return 3
        case .complete: return 4
        }
    }
}

struct PhaseStep: View {
    let phase: RoomScanPhase
    let isActive: Bool
    let isComplete: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : (isActive ? phase.color : Color.gray.opacity(0.3)))
                    .frame(width: 24, height: 24)

                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .fontWeight(.bold)
                } else {
                    Image(systemName: phase.icon)
                        .font(.caption2)
                }
            }
            .foregroundColor(.white)

            Text(shortLabel)
                .font(.system(size: 8))
                .foregroundColor(isActive ? .white : .gray)
        }
        .frame(maxWidth: .infinity)
    }

    private var shortLabel: String {
        switch phase {
        case .ready: return "Ready"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .walls: return "Walls"
        case .complete: return "Done"
        }
    }
}

struct DimensionLabel: View {
    let label: String
    let value: Float

    var body: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1fm", value))
                .font(.headline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct StatBadge: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(value)
                .font(.caption)
                .fontWeight(.bold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.15))
        .cornerRadius(8)
    }
}
