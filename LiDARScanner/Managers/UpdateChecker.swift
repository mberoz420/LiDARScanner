import Foundation
import SwiftUI

/// Response from version check endpoint
struct VersionInfo: Codable {
    let latestVersion: String
    let buildNumber: Int
    let diawiURL: String?
    let releaseNotes: String?
    let required: Bool  // Force update?

    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest_version"
        case buildNumber = "build_number"
        case diawiURL = "diawi_url"
        case releaseNotes = "release_notes"
        case required
    }
}

/// Update availability result
struct UpdateAvailable {
    let currentVersion: String
    let newVersion: String
    let releaseNotes: String?
    let downloadURL: URL?
    let isRequired: Bool
}

@MainActor
class UpdateChecker: ObservableObject {
    // MARK: - Configuration

    /// URL to your version.json file
    /// Host this on GitHub Pages, Firebase Hosting, your server, etc.
    /// Example: "https://yourusername.github.io/lidarscanner/version.json"
    private var versionCheckURL: String {
        AppSettings.shared.versionCheckURL
    }

    // MARK: - Published State
    @Published var isChecking = false
    @Published var updateAvailable: UpdateAvailable?
    @Published var lastError: String?
    @Published var showUpdateAlert = false
    @Published var lastCheckResult: CheckResult?

    enum CheckResult {
        case upToDate
        case updateAvailable
        case error(String)
        case notConfigured
    }

    // MARK: - Check for Updates

    /// Check for updates (respects autoCheckUpdates setting)
    func checkForUpdates() async {
        guard AppSettings.shared.autoCheckUpdates else { return }
        await performUpdateCheck()
    }

    /// Force check for updates (ignores autoCheckUpdates setting)
    func forceCheckForUpdates() async {
        await performUpdateCheck()
    }

    private func performUpdateCheck() async {
        guard !versionCheckURL.isEmpty,
              let url = URL(string: versionCheckURL) else {
            lastError = "Configure update URL in Settings"
            lastCheckResult = .notConfigured
            return
        }

        isChecking = true
        lastError = nil
        lastCheckResult = nil

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                lastError = "Server returned error"
                isChecking = false
                return
            }

            let versionInfo = try JSONDecoder().decode(VersionInfo.self, from: data)

            // Compare versions
            let currentVersion = currentAppVersion
            let currentBuild = currentBuildNumber

            if isNewerVersion(versionInfo.latestVersion, than: currentVersion) ||
               versionInfo.buildNumber > currentBuild {

                updateAvailable = UpdateAvailable(
                    currentVersion: "\(currentVersion) (\(currentBuild))",
                    newVersion: "\(versionInfo.latestVersion) (\(versionInfo.buildNumber))",
                    releaseNotes: versionInfo.releaseNotes,
                    downloadURL: versionInfo.diawiURL.flatMap { URL(string: $0) },
                    isRequired: versionInfo.required
                )
                lastCheckResult = .updateAvailable
                showUpdateAlert = true
            } else {
                lastCheckResult = .upToDate
            }

        } catch {
            lastError = error.localizedDescription
            lastCheckResult = .error(error.localizedDescription)
        }

        isChecking = false
    }

    // MARK: - Open Download

    func openDownloadURL() {
        guard let url = updateAvailable?.downloadURL else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Version Helpers

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var currentBuildNumber: Int {
        let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return Int(buildString) ?? 1
    }

    /// Compare semantic versions (e.g., "1.2.0" vs "1.1.5")
    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(newParts.count, currentParts.count) {
            let newPart = i < newParts.count ? newParts[i] : 0
            let currentPart = i < currentParts.count ? currentParts[i] : 0

            if newPart > currentPart {
                return true
            } else if newPart < currentPart {
                return false
            }
        }

        return false  // Equal versions
    }
}

// MARK: - Update Alert View Modifier

struct UpdateAlertModifier: ViewModifier {
    @ObservedObject var checker: UpdateChecker

    func body(content: Content) -> some View {
        content
            .alert("Update Available", isPresented: $checker.showUpdateAlert) {
                if let update = checker.updateAvailable {
                    Button("Download") {
                        checker.openDownloadURL()
                    }

                    if !update.isRequired {
                        Button("Later", role: .cancel) {}
                    }
                }
            } message: {
                if let update = checker.updateAvailable {
                    VStack {
                        Text("Version \(update.newVersion) is available.")
                        if let notes = update.releaseNotes {
                            Text("\n\(notes)")
                        }
                        Text("\nCurrent: \(update.currentVersion)")
                    }
                }
            }
    }
}

extension View {
    func checkForUpdates(using checker: UpdateChecker) -> some View {
        modifier(UpdateAlertModifier(checker: checker))
    }
}
