import SwiftUI

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    let version: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // App icon and version
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)

                        Text("LiDAR Scanner")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Version \(version)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    // What's new section
                    VStack(alignment: .leading, spacing: 20) {
                        Text("What's New")
                            .font(.title2)
                            .fontWeight(.bold)

                        FeatureRow(
                            icon: "viewfinder",
                            iconColor: .blue,
                            title: "Multiple Scan Modes",
                            description: "Fast Scan, Walls, Large Objects, Small Objects, and Organic/Faces modes"
                        )

                        FeatureRow(
                            icon: "camera.fill",
                            iconColor: .green,
                            title: "Color Texture Capture",
                            description: "Camera colors are projected onto the 3D mesh for realistic exports"
                        )

                        FeatureRow(
                            icon: "face.smiling",
                            iconColor: .orange,
                            title: "Face Scanning",
                            description: "Use front camera TrueDepth sensor for detailed face mesh capture"
                        )

                        FeatureRow(
                            icon: "square.and.arrow.up",
                            iconColor: .purple,
                            title: "Export Formats",
                            description: "Export to USDZ, PLY (with colors), and OBJ formats"
                        )

                        FeatureRow(
                            icon: "slider.horizontal.3",
                            iconColor: .red,
                            title: "Adjustable Settings",
                            description: "Each scan mode optimized for different object types and detail levels"
                        )
                    }
                    .padding(.horizontal)

                    Spacer(minLength: 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Continue") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.15))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Version Tracker

class VersionTracker: ObservableObject {
    @Published var shouldShowWhatsNew = false

    private let lastVersionKey = "lastSeenVersion"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var fullVersion: String {
        "\(currentVersion) (\(currentBuild))"
    }

    init() {
        checkVersion()
    }

    private func checkVersion() {
        let lastVersion = UserDefaults.standard.string(forKey: lastVersionKey)

        if lastVersion == nil {
            // First install
            shouldShowWhatsNew = true
        } else if lastVersion != fullVersion {
            // Updated version
            shouldShowWhatsNew = true
        }
    }

    func markAsSeen() {
        UserDefaults.standard.set(fullVersion, forKey: lastVersionKey)
        shouldShowWhatsNew = false
    }
}
