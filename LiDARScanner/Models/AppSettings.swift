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
        case .files: return "Open file picker to save locally"
        case .googleDrive: return "Auto-upload to Google Drive (requires setup)"
        case .iCloud: return "Save directly to iCloud Drive"
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

enum RoomLayoutMode: String, CaseIterable, Identifiable {
    case includeAll = "Include Everything"
    case roomOnly = "Room Structure Only"
    case filterLarge = "Filter Large Objects"
    case filterByHeight = "Filter by Height"
    case custom = "Custom Filter"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .includeAll:
            return "Capture all surfaces including furniture"
        case .roomOnly:
            return "Only walls, floor, ceiling, and protrusions"
        case .filterLarge:
            return "Ignore objects larger than threshold"
        case .filterByHeight:
            return "Ignore objects below height threshold"
        case .custom:
            return "Choose exactly what to include"
        }
    }

    var icon: String {
        switch self {
        case .includeAll: return "cube.fill"
        case .roomOnly: return "square.split.bottomrightquarter"
        case .filterLarge: return "shippingbox.fill"
        case .filterByHeight: return "ruler"
        case .custom: return "slider.horizontal.3"
        }
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // Export settings
    @AppStorage("defaultExportDestination") var defaultDestination: ExportDestination = .shareSheet
    @AppStorage("defaultExportFormat") var defaultFormat: DefaultExportFormat = .ask
    @AppStorage("autoSaveAfterScan") var autoSaveAfterScan: Bool = false
    @AppStorage("includeColorsInExport") var includeColors: Bool = true
    @AppStorage("googleDriveFolderName") var googleDriveFolderName: String = "LiDAR Scans"

    // Google Drive settings
    @AppStorage("googleClientID") var googleClientID: String = ""

    // Surface classification settings
    @AppStorage("surfaceClassificationEnabled") var surfaceClassificationEnabled: Bool = true
    @AppStorage("floorCeilingAngle") var floorCeilingAngle: Double = 32.0  // Degrees from horizontal
    @AppStorage("wallAngle") var wallAngle: Double = 72.0  // Degrees from horizontal
    @AppStorage("protrusionMinDepth") var protrusionMinDepth: Double = 8.0  // cm
    @AppStorage("protrusionMaxDepth") var protrusionMaxDepth: Double = 60.0  // cm

    // Room layout settings (object filtering)
    @AppStorage("roomLayoutMode") var roomLayoutMode: RoomLayoutMode = .includeAll
    @AppStorage("minObjectSizeToIgnore") var minObjectSizeToIgnore: Double = 30.0  // cm - objects larger than this can be ignored
    @AppStorage("maxObjectHeightFromFloor") var maxObjectHeightFromFloor: Double = 200.0  // cm - ignore objects below this height
    @AppStorage("ignoreObjectsNearWalls") var ignoreObjectsNearWalls: Bool = false  // Ignore objects within X cm of walls

    // Custom filter toggles (used when roomLayoutMode == .custom)
    @AppStorage("includeFloor") var includeFloor: Bool = true
    @AppStorage("includeCeiling") var includeCeiling: Bool = true
    @AppStorage("includeWalls") var includeWalls: Bool = true
    @AppStorage("includeProtrusions") var includeProtrusions: Bool = true
    @AppStorage("includeDoors") var includeDoors: Bool = true
    @AppStorage("includeWindows") var includeWindows: Bool = true
    @AppStorage("includeObjects") var includeObjects: Bool = true
    @AppStorage("includeEdges") var includeEdges: Bool = true

    // Door/window detection settings
    @AppStorage("detectDoorsWindows") var detectDoorsWindows: Bool = true

    // Input methods for marking features
    @AppStorage("pauseGestureEnabled") var pauseGestureEnabled: Bool = true   // Pause to confirm edge
    @AppStorage("voiceCommandsEnabled") var voiceCommandsEnabled: Bool = true  // Speak to mark features
    @AppStorage("autoDetectionEnabled") var autoDetectionEnabled: Bool = true  // Automatic edge detection

    // Feedback settings
    @AppStorage("speechFeedbackEnabled") var speechFeedbackEnabled: Bool = true
    @AppStorage("hapticFeedbackEnabled") var hapticFeedbackEnabled: Bool = true

    // Update checking - default to GitHub raw file
    @AppStorage("versionCheckURL") var versionCheckURL: String = "https://raw.githubusercontent.com/mberoz420/LiDARScanner/master/version.json"
    @AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = true

    // Room simplification
    @AppStorage("simplifyRoomExport") var simplifyRoomExport: Bool = false
    @AppStorage("simplificationGridSize") var simplificationGridSize: Double = 10.0  // cm
    @AppStorage("minWallLength") var minWallLength: Double = 30.0  // cm
    @AppStorage("snapToRightAngles") var snapToRightAngles: Bool = true

    // Computed thresholds for use in SurfaceClassifier
    var horizontalSurfaceThreshold: Float {
        // Convert angle to cosine (normal Y component)
        Float(cos(floorCeilingAngle * .pi / 180))
    }

    var wallThreshold: Float {
        // Convert angle to cosine
        Float(cos(wallAngle * .pi / 180))
    }

    var protrusionMinDepthMeters: Float {
        Float(protrusionMinDepth / 100.0)
    }

    var protrusionMaxDepthMeters: Float {
        Float(protrusionMaxDepth / 100.0)
    }

    var minObjectSizeMeters: Float {
        Float(minObjectSizeToIgnore / 100.0)
    }

    var maxObjectHeightMeters: Float {
        Float(maxObjectHeightFromFloor / 100.0)
    }

    private init() {}
}

// Extension for AppStorage to work with custom enums
extension ExportDestination: RawRepresentable {
    typealias RawValue = String
}

extension DefaultExportFormat: RawRepresentable {
    typealias RawValue = String
}

extension RoomLayoutMode: RawRepresentable {
    typealias RawValue = String
}
