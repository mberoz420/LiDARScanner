import SwiftUI

/// View for extracting architectural elements from an organic scan
struct ArchitecturalExtractionView: View {
    let scan: CapturedScan

    @StateObject private var extractor = ArchitecturalExtractor()
    @State private var hasProcessed = false
    @State private var showExport = false
    @State private var cleanScan: CapturedScan?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header info
                VStack(spacing: 8) {
                    Image(systemName: "building.2")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)

                    Text("Extract Architecture")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Separate walls, floor, and ceiling from furniture and objects")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top)

                // Scan info
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Original Scan")
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(scan.meshes.count) meshes")
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Vertices")
                            Spacer()
                            Text("\(scan.vertexCount.formatted())")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal)

                Spacer()

                // Processing state
                if extractor.isProcessing {
                    VStack(spacing: 12) {
                        ProgressView(value: Double(extractor.progress))
                            .progressViewStyle(.linear)
                            .padding(.horizontal, 40)

                        Text(extractor.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if hasProcessed {
                    // Results
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Extracted Elements")
                                .fontWeight(.semibold)
                                .font(.subheadline)

                            Divider()

                            // Floor
                            HStack {
                                Image(systemName: "square.fill")
                                    .foregroundColor(.green)
                                Text("Floor")
                                Spacer()
                                if let floor = extractor.extractedFloor {
                                    Text(String(format: "%.1f m²", floor.area))
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Not found")
                                        .foregroundColor(.red)
                                }
                            }
                            .font(.subheadline)

                            // Ceiling
                            HStack {
                                Image(systemName: "square.fill")
                                    .foregroundColor(.yellow)
                                Text("Ceiling")
                                Spacer()
                                if let ceiling = extractor.extractedCeiling {
                                    Text(String(format: "%.1f m²", ceiling.area))
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Not found")
                                        .foregroundColor(.red)
                                }
                            }
                            .font(.subheadline)

                            // Walls
                            HStack {
                                Image(systemName: "rectangle.portrait.fill")
                                    .foregroundColor(.orange)
                                Text("Walls")
                                Spacer()
                                Text("\(extractor.extractedWalls.count) detected")
                                    .foregroundColor(.secondary)
                            }
                            .font(.subheadline)

                            // Objects
                            HStack {
                                Image(systemName: "cube.fill")
                                    .foregroundColor(.purple)
                                Text("Objects")
                                Spacer()
                                Text("\(extractor.extractedObjects.count) detected")
                                    .foregroundColor(.secondary)
                            }
                            .font(.subheadline)

                            if !extractor.extractedObjects.isEmpty {
                                Divider()

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Object Categories")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    let furniture = extractor.extractedObjects.filter { $0.category == .furniture }.count
                                    let appliances = extractor.extractedObjects.filter { $0.category == .appliance }.count
                                    let clutter = extractor.extractedObjects.filter { $0.category == .clutter }.count

                                    HStack(spacing: 16) {
                                        if furniture > 0 {
                                            Label("\(furniture)", systemImage: "sofa.fill")
                                        }
                                        if appliances > 0 {
                                            Label("\(appliances)", systemImage: "refrigerator.fill")
                                        }
                                        if clutter > 0 {
                                            Label("\(clutter)", systemImage: "shippingbox.fill")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    if !hasProcessed {
                        Button(action: processScean) {
                            Label("Extract Architecture", systemImage: "wand.and.stars")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                        .disabled(extractor.isProcessing)
                    } else {
                        // Export clean architecture
                        Button(action: exportCleanArchitecture) {
                            Label("Export Clean Architecture", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }

                        // Process again
                        Button(action: processScean) {
                            Label("Process Again", systemImage: "arrow.clockwise")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.gray.opacity(0.2))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("AI Extraction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showExport) {
                if let clean = cleanScan {
                    ExportView(scan: clean)
                }
            }
        }
    }

    private func processScean() {
        Task {
            let _ = await extractor.processOrganicScan(scan)
            hasProcessed = true
        }
    }

    private func exportCleanArchitecture() {
        cleanScan = extractor.generateCleanArchitecturalMesh()
        if cleanScan != nil {
            showExport = true
        }
    }
}

#Preview {
    ArchitecturalExtractionView(scan: CapturedScan(startTime: Date()))
}
