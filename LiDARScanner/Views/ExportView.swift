import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    let scan: CapturedScan
    @StateObject private var exporter = MeshExporter()
    @ObservedObject var settings = AppSettings.shared
    @State private var exportedURLs: [ExportFormat: URL] = [:]
    @State private var selectedFormat: ExportFormat = .usdz
    @State private var shareItem: ShareItem?
    @State private var showFilePicker = false
    @State private var fileToSave: URL?
    @State private var showSaveSuccess = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Scan summary
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan Summary")
                        .font(.headline)
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Vertices: \(scan.vertexCount)")
                            Text("Faces: \(scan.faceCount)")
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("Meshes: \(scan.meshes.count)")
                            if scan.hasColors {
                                Label("With Colors", systemImage: "paintpalette.fill")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
        if let url = await exporter.export(scan, format: format) {
            exportedURLs[format] = url
            handleExportedFile(url: url)
        }
    }

    private func exportAllAndHandle() async {
        let results = await exporter.exportAll(scan)
        exportedURLs = results

        // Handle based on settings
        if let firstURL = results.values.first {
            handleExportedFile(url: firstURL, isMultiple: true, allURLs: Array(results.values))
        }
    }

    private func handleExportedFile(url: URL, isMultiple: Bool = false, allURLs: [URL] = []) {
        switch settings.defaultDestination {
        case .shareSheet:
            if isMultiple && allURLs.count > 1 {
                shareItem = ShareItem(url: url) // Share first, user can share others individually
            } else {
                shareItem = ShareItem(url: url)
            }

        case .files, .googleDrive, .iCloud:
            fileToSave = url
            showFilePicker = true
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
