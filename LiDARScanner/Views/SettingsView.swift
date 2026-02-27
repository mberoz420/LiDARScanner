import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Export Destination
                Section {
                    ForEach(ExportDestination.allCases) { destination in
                        Button(action: {
                            settings.defaultDestination = destination
                        }) {
                            HStack {
                                Image(systemName: destination.icon)
                                    .foregroundColor(.blue)
                                    .frame(width: 30)

                                VStack(alignment: .leading) {
                                    Text(destination.rawValue)
                                        .foregroundColor(.primary)
                                    Text(destination.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if settings.defaultDestination == destination {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Default Export Destination")
                } footer: {
                    Text("Google Drive and iCloud require their apps to be installed and configured in Files.")
                }

                // Google Drive folder name
                if settings.defaultDestination == .googleDrive {
                    Section {
                        TextField("Folder Name", text: $settings.googleDriveFolderName)
                    } header: {
                        Text("Google Drive Folder")
                    } footer: {
                        Text("Scans will be saved to this folder in Google Drive.")
                    }
                }

                // Default Format
                Section {
                    Picker("Default Format", selection: $settings.defaultFormat) {
                        ForEach(DefaultExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                } header: {
                    Text("Export Format")
                }

                // Auto-save
                Section {
                    Toggle("Auto-save After Scan", isOn: $settings.autoSaveAfterScan)
                    Toggle("Include Colors in Export", isOn: $settings.includeColors)
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("Auto-save will automatically export when you stop scanning.")
                }

                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(VersionTracker().fullVersion)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("LiDAR")
                        Spacer()
                        Text(checkLiDARAvailability() ? "Available" : "Not Available")
                            .foregroundColor(checkLiDARAvailability() ? .green : .red)
                    }

                    HStack {
                        Text("TrueDepth")
                        Spacer()
                        Text(checkFaceTrackingAvailability() ? "Available" : "Not Available")
                            .foregroundColor(checkFaceTrackingAvailability() ? .green : .red)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func checkLiDARAvailability() -> Bool {
        if #available(iOS 13.4, *) {
            return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        }
        return false
    }

    private func checkFaceTrackingAvailability() -> Bool {
        return ARFaceTrackingConfiguration.isSupported
    }
}

import ARKit

#Preview {
    SettingsView()
}
