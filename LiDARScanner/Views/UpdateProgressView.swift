import SwiftUI

struct UpdateProgressView: View {
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.dismiss) private var dismiss
    @State private var isOpening = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Icon
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                // Version info
                if let update = updateChecker.updateAvailable {
                    VStack(spacing: 8) {
                        Text("Update Available")
                            .font(.title2)
                            .fontWeight(.bold)

                        HStack(spacing: 12) {
                            VStack {
                                Text("Current")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(update.currentVersion)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }

                            Image(systemName: "arrow.right")
                                .foregroundColor(.green)

                            VStack {
                                Text("New")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(update.newVersion)
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                    .foregroundColor(.green)
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    // Release notes
                    if let notes = update.releaseNotes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What's New")
                                .font(.headline)

                            Text(notes)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    Spacer()

                    // Download button or progress
                    if isOpening {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Opening Diawi...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    } else {
                        VStack(spacing: 12) {
                            Button(action: startDownload) {
                                HStack {
                                    Image(systemName: "arrow.down.to.line")
                                    Text("Download & Install")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(Color.green)
                                .cornerRadius(12)
                            }

                            if !update.isRequired {
                                Button("Later") {
                                    dismiss()
                                }
                                .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Instructions
                    VStack(spacing: 4) {
                        Text("After downloading:")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("1. Tap 'Install' in Diawi")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("2. Go to Settings > General > VPN & Device Management")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("3. Trust the developer certificate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
            .navigationTitle("Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func startDownload() {
        isOpening = true

        // Save that we're attempting to update to this version
        updateChecker.markUpdateAttempted()

        // Delay slightly to show progress, then open URL
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            updateChecker.openDownloadURL()

            // Dismiss after opening
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                dismiss()
            }
        }
    }
}

// MARK: - Update Complete Alert

struct UpdateCompleteAlert: ViewModifier {
    @Binding var isPresented: Bool
    let version: String

    func body(content: Content) -> some View {
        content
            .alert("Update Complete!", isPresented: $isPresented) {
                Button("OK") {}
            } message: {
                Text("You're now running version \(version)")
            }
    }
}

extension View {
    func updateCompleteAlert(isPresented: Binding<Bool>, version: String) -> some View {
        modifier(UpdateCompleteAlert(isPresented: isPresented, version: version))
    }
}

#Preview {
    UpdateProgressView(updateChecker: UpdateChecker())
}
