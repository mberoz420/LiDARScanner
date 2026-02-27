import SwiftUI

struct ExportView: View {
    let scan: CapturedScan
    @StateObject private var exporter = MeshExporter()
    @State private var exportedURLs: [ExportFormat: URL] = [:]
    @State private var selectedFormat: ExportFormat = .usdz
    @State private var shareItem: ShareItem?
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
                    Text("Export Format")
                        .font(.headline)

                    ForEach(ExportFormat.allCases) { format in
                        ExportFormatRow(
                            format: format,
                            isExported: exportedURLs[format] != nil,
                            isExporting: exporter.isExporting && selectedFormat == format
                        ) {
                            Task { await exportSingle(format) }
                        } onShare: {
                            if let url = exportedURLs[format] {
                                shareItem = ShareItem(url: url)
                            }
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)

                // Export all button
                Button(action: { Task { await exportAllFormats() } }) {
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
        }
    }

    private func exportSingle(_ format: ExportFormat) async {
        selectedFormat = format
        if let url = await exporter.export(scan, format: format) {
            exportedURLs[format] = url
        }
    }

    private func exportAllFormats() async {
        let results = await exporter.exportAll(scan)
        exportedURLs = results
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
            return "Point cloud format"
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
