import SwiftUI
import ARKit
import RealityKit

struct ScannerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ScannerViewModel()
    @State private var showExportSheet = false
    @State private var showBoundingBoxEditor = false

    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(viewModel: viewModel)
                .ignoresSafeArea()

            // Overlay UI
            VStack {
                // Top bar - status and controls
                HStack {
                    // Device status
                    DeviceStatusBadge(isLiDARAvailable: LiDARCapture.isLiDARAvailable)

                    Spacer()

                    // Scan progress
                    if viewModel.isScanning {
                        ScanProgressView(progress: viewModel.scanProgress)
                    }
                }
                .padding()

                Spacer()

                // Dimension overlay (when object is captured)
                if let metrics = viewModel.currentMetrics {
                    DimensionOverlay(metrics: metrics)
                        .padding()
                }

                // Bottom controls
                VStack(spacing: 16) {
                    // Bounding box toggle
                    if viewModel.isScanning {
                        Toggle("Bounding Box", isOn: $viewModel.showBoundingBox)
                            .toggleStyle(.button)
                            .tint(.blue)
                    }

                    // Main action buttons
                    HStack(spacing: 32) {
                        // Reset button
                        Button(action: viewModel.reset) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title2)
                                .frame(width: 60, height: 60)
                                .background(Color.secondary.opacity(0.3))
                                .clipShape(Circle())
                        }
                        .disabled(!viewModel.canReset)

                        // Main scan/capture button
                        Button(action: viewModel.toggleScanning) {
                            ZStack {
                                Circle()
                                    .fill(viewModel.isScanning ? Color.red : Color.white)
                                    .frame(width: 80, height: 80)

                                if viewModel.isScanning {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white)
                                        .frame(width: 30, height: 30)
                                } else {
                                    Circle()
                                        .stroke(Color.black, lineWidth: 3)
                                        .frame(width: 65, height: 65)
                                }
                            }
                        }
                        .disabled(!LiDARCapture.isLiDARAvailable)

                        // Export button
                        Button(action: { showExportSheet = true }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .frame(width: 60, height: 60)
                                .background(Color.secondary.opacity(0.3))
                                .clipShape(Circle())
                        }
                        .disabled(viewModel.capturedMesh == nil)
                    }

                    // Identify button (after capture)
                    if viewModel.capturedMesh != nil {
                        Button(action: {
                            Task {
                                await viewModel.identifyObject()
                            }
                        }) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                Text("Identify Object")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 30)
            }

            // Processing overlay
            if viewModel.isProcessing {
                ProcessingOverlay(message: viewModel.processingMessage)
            }

            // Error overlay
            if let error = viewModel.error {
                ErrorOverlay(error: error) {
                    viewModel.dismissError()
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.identificationComplete) { _, complete in
            if complete, let results = viewModel.identificationResults {
                appState.identificationResults = results
            }
        }
    }
}

// MARK: - AR View Container

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ScannerViewModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false

        // Enable mesh visualization
        arView.debugOptions.insert(.showSceneUnderstanding)

        viewModel.setupARView(arView)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Update bounding box visualization
        if viewModel.showBoundingBox {
            viewModel.updateBoundingBoxVisualization(in: uiView)
        }
    }
}

// MARK: - Supporting Views

struct DeviceStatusBadge: View {
    let isLiDARAvailable: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLiDARAvailable ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isLiDARAvailable ? "LiDAR Ready" : "LiDAR Unavailable")
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(20)
    }
}

struct ScanProgressView: View {
    let progress: Float

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(progress))
                .frame(width: 100)
                .tint(.blue)
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.6))
        .cornerRadius(20)
    }
}

struct DimensionOverlay: View {
    let metrics: ObjectMetrics
    @AppStorage("measurementUnit") private var unit = "mm"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dimensions")
                .font(.headline)

            Text(metrics.dimensionString(unit: unit))
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)

            HStack {
                Label(metrics.primitiveType.displayName, systemImage: metrics.primitiveType.iconName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
    }
}

struct ProcessingOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text(message)
                .font(.headline)
        }
        .padding(32)
        .background(Color.black.opacity(0.8))
        .cornerRadius(16)
    }
}

struct ErrorOverlay: View {
    let error: Error
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.yellow)

            Text("Error")
                .font(.headline)

            Text(error.localizedDescription)
                .font(.body)
                .multilineTextAlignment(.center)

            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(Color.black.opacity(0.9))
        .cornerRadius(16)
        .padding(32)
    }
}

struct ExportSheet: View {
    @ObservedObject var viewModel: ScannerViewModel
    @Environment(\.dismiss) var dismiss
    @State private var selectedFormat: ExportFormat = .usdz
    @State private var filename = "scan"
    @State private var isExporting = false
    @State private var exportedURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Filename") {
                    TextField("Filename", text: $filename)
                }

                Section("Format") {
                    Picker("Export Format", selection: $selectedFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(selectedFormat.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let url = exportedURL {
                    Section("Exported File") {
                        ShareLink(item: url) {
                            Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Export Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") {
                        Task {
                            isExporting = true
                            exportedURL = await viewModel.exportMesh(format: selectedFormat, filename: filename)
                            isExporting = false
                        }
                    }
                    .disabled(filename.isEmpty || isExporting)
                }
            }
            .overlay {
                if isExporting {
                    ProgressView("Exporting...")
                        .padding()
                        .background(Color.secondary.opacity(0.5))
                        .cornerRadius(8)
                }
            }
        }
    }
}

#Preview {
    ScannerView()
        .environmentObject(AppState())
}
