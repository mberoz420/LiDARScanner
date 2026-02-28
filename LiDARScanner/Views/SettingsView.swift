import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var updateChecker = UpdateChecker()
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• Share Sheet: Choose destination each time")
                        Text("• Files App: Opens file picker to save locally")
                        Text("• Google Drive: Auto-uploads to your Google Drive (configure below)")
                        Text("• iCloud Drive: Saves directly to iCloud (requires iCloud enabled)")
                    }
                    .font(.caption2)
                }

                // Google Drive configuration
                if settings.defaultDestination == .googleDrive {
                    Section {
                        // Sign-in status
                        HStack {
                            Text("Status")
                            Spacer()
                            if GoogleDriveManager.shared.isSignedIn {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text(GoogleDriveManager.shared.userEmail ?? "Signed In")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("Not signed in")
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Sign in/out button
                        if GoogleDriveManager.shared.isSignedIn {
                            Button("Sign Out") {
                                GoogleDriveManager.shared.signOut()
                            }
                            .foregroundColor(.red)
                        } else {
                            Button("Sign In to Google") {
                                Task {
                                    await GoogleDriveManager.shared.signIn()
                                }
                            }
                            .disabled(settings.googleClientID.isEmpty)
                        }

                        // Client ID
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Google Client ID")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("xxxxx.apps.googleusercontent.com", text: $settings.googleClientID)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .autocapitalization(.none)
                        }

                        // Folder name
                        TextField("Folder Name", text: $settings.googleDriveFolderName)
                    } header: {
                        Text("Google Drive")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("To set up Google Drive:")
                            Text("1. Go to console.cloud.google.com")
                            Text("2. Create a project and enable Google Drive API")
                            Text("3. Create OAuth 2.0 Client ID (iOS app)")
                            Text("4. Copy the Client ID and paste above")
                        }
                        .font(.caption2)
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

                // Room Layout Mode
                Section {
                    ForEach(RoomLayoutMode.allCases) { mode in
                        Button(action: {
                            settings.roomLayoutMode = mode
                        }) {
                            HStack {
                                Image(systemName: mode.icon)
                                    .foregroundColor(.blue)
                                    .frame(width: 30)

                                VStack(alignment: .leading) {
                                    Text(mode.rawValue)
                                        .foregroundColor(.primary)
                                    Text(mode.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if settings.roomLayoutMode == mode {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }

                    // Show additional options based on mode
                    if settings.roomLayoutMode == .filterLarge {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Min Object Size to Ignore")
                                Spacer()
                                Text("\(Int(settings.minObjectSizeToIgnore))cm")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.minObjectSizeToIgnore, in: 10...100, step: 5)
                            Text("Objects larger than this will be filtered out")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if settings.roomLayoutMode == .filterByHeight {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Max Height from Floor")
                                Spacer()
                                Text("\(Int(settings.maxObjectHeightFromFloor))cm")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.maxObjectHeightFromFloor, in: 50...300, step: 10)
                            Text("Objects below this height will be filtered out")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if settings.roomLayoutMode == .custom {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Include Surfaces")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Toggle(isOn: $settings.includeFloor) {
                                Label("Floor", systemImage: "square.fill")
                                    .foregroundColor(.green)
                            }

                            Toggle(isOn: $settings.includeCeiling) {
                                Label("Ceiling", systemImage: "square.fill")
                                    .foregroundColor(.yellow)
                            }

                            Toggle(isOn: $settings.includeWalls) {
                                Label("Walls", systemImage: "square.fill")
                                    .foregroundColor(.blue)
                            }

                            Toggle(isOn: $settings.includeProtrusions) {
                                Label("Protrusions (beams, ducts)", systemImage: "square.fill")
                                    .foregroundColor(.orange)
                            }

                            Toggle(isOn: $settings.includeDoors) {
                                Label("Doors", systemImage: "door.left.hand.open")
                                    .foregroundColor(.brown)
                            }

                            Toggle(isOn: $settings.includeWindows) {
                                Label("Windows", systemImage: "window.horizontal")
                                    .foregroundColor(.cyan)
                            }

                            Toggle(isOn: $settings.includeObjects) {
                                Label("Objects (furniture)", systemImage: "square.fill")
                                    .foregroundColor(.red)
                            }

                            Toggle(isOn: $settings.includeEdges) {
                                Label("Edges (corners)", systemImage: "square.fill")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                } header: {
                    Text("Room Layout Mode")
                } footer: {
                    Text("Filter out furniture and objects to capture clean room structure.")
                }

                // Surface Classification
                Section {
                    Toggle("Enable Surface Classification", isOn: $settings.surfaceClassificationEnabled)

                    if settings.surfaceClassificationEnabled {
                        Toggle("Detect Doors & Windows", isOn: $settings.detectDoorsWindows)
                    }

                    if settings.surfaceClassificationEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Floor/Ceiling Angle")
                                Spacer()
                                Text("±\(Int(settings.floorCeilingAngle))°")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.floorCeilingAngle, in: 15...60, step: 5)
                            Text("Surfaces within this angle from horizontal are floor/ceiling")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Wall Angle")
                                Spacer()
                                Text("±\(Int(settings.wallAngle))°")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.wallAngle, in: 60...85, step: 5)
                            Text("Surfaces within this angle from vertical are walls")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Protrusion Detection")
                                Spacer()
                                Text("\(Int(settings.protrusionMinDepth))-\(Int(settings.protrusionMaxDepth))cm")
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Min")
                                    .font(.caption)
                                Slider(value: $settings.protrusionMinDepth, in: 3...20, step: 1)
                                Text("Max")
                                    .font(.caption)
                                Slider(value: $settings.protrusionMaxDepth, in: 30...100, step: 5)
                            }
                            Text("Depth range below ceiling to detect beams/ducts")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Surface Classification")
                } footer: {
                    Text("Identifies floors, ceilings, walls, and ceiling protrusions (beams, ducts) using device orientation.")
                }

                // Room Simplification
                Section {
                    Toggle("Enable Simplified Export", isOn: $settings.simplifyRoomExport)

                    if settings.simplifyRoomExport {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Grid Resolution")
                                Spacer()
                                Text("\(Int(settings.simplificationGridSize))cm")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.simplificationGridSize, in: 5...30, step: 5)
                            Text("Smaller = more detail, larger = simpler")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Min Wall Length")
                                Spacer()
                                Text("\(Int(settings.minWallLength))cm")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.minWallLength, in: 10...100, step: 10)
                            Text("Walls shorter than this are removed")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Toggle("Snap to 90° Angles", isOn: $settings.snapToRightAngles)
                    }
                } header: {
                    Text("Room Simplification")
                } footer: {
                    Text("Converts dense mesh to simple room outline: floor + ceiling + walls. Reduces thousands of vertices to ~50-100.")
                }

                // Updates
                Section {
                    Toggle("Auto-check for Updates", isOn: $settings.autoCheckUpdates)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Version Check URL")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("https://example.com/version.json", text: $settings.versionCheckURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                    }

                    Button("Check Now") {
                        Task {
                            await updateChecker.forceCheckForUpdates()
                        }
                    }
                    .disabled(settings.versionCheckURL.isEmpty)

                    if updateChecker.isChecking {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Checking...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = updateChecker.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Host a version.json file with latest version info and Diawi download URL.")
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
            .checkForUpdates(using: updateChecker)
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
