import Foundation
import SwiftUI

enum ExportDestination: String, CaseIterable, Identifiable {
    case shareSheet = "Share Sheet"
    case files = "Files App"
    case googleDrive = "Google Drive"
    case iCloud = "iCloud Drive"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .shareSheet: return "square.and.arrow.up"
        case .files: return "folder"
        case .googleDrive: return "externaldrive"
        case .iCloud: return "icloud"
        }
    }

    var description: String {
        switch self {
        case .shareSheet: return "Choose destination each time"
        case .files: return "Save directly to Files app"
        case .googleDrive: return "Save to Google Drive folder"
        case .iCloud: return "Save to iCloud Drive"
        }
    }
}

enum DefaultExportFormat: String, CaseIterable, Identifiable {
    case ask = "Ask Each Time"
    case ply = "PLY"
    case usdz = "USDZ"
    case obj = "OBJ"
    case all = "All Formats"

    var id: String { rawValue }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("defaultExportDestination") var defaultDestination: ExportDestination = .shareSheet
    @AppStorage("defaultExportFormat") var defaultFormat: DefaultExportFormat = .ask
    @AppStorage("autoSaveAfterScan") var autoSaveAfterScan: Bool = false
    @AppStorage("includeColorsInExport") var includeColors: Bool = true
    @AppStorage("googleDriveFolderName") var googleDriveFolderName: String = "LiDAR Scans"

    private init() {}
}

// Extension for AppStorage to work with custom enums
extension ExportDestination: RawRepresentable {
    typealias RawValue = String
}

extension DefaultExportFormat: RawRepresentable {
    typealias RawValue = String
}
