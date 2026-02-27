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

                // Surface type legend (when classification is enabled)
                if meshManager.isScanning && meshManager.surfaceClassificationEnabled && meshManager.currentMode == .walls {
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
