import Foundation
import SwiftUI

enum ScanMode: String, CaseIterable, Identifiable {
    case fast = "Fast Scan"
    case walls = "Walls & Rooms"
    case largeObjects = "Large Objects"
    case smallObjects = "Small Objects"
    case organic = "Organic & Faces"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .fast: return "hare.fill"
        case .walls: return "square.split.bottomrightquarter"
        case .largeObjects: return "cube.fill"
        case .smallObjects: return "screwdriver.fill"
        case .organic: return "leaf.fill"
        }
    }

    var description: String {
        switch self {
        case .fast:
            return "Quick low-detail scan"
        case .walls:
            return "Room edges and architecture"
        case .largeObjects:
            return "Furniture, vehicles, sculptures"
        case .smallObjects:
            return "Nails, nuts, bolts, detailed parts"
        case .organic:
            return "Plants, faces, human body"
        }
    }

    var color: Color {
        switch self {
        case .fast: return .orange
        case .walls: return .blue
        case .largeObjects: return .purple
        case .smallObjects: return .red
        case .organic: return .green
        }
    }

    // Mesh update interval (lower = more updates, higher detail)
    var updateInterval: TimeInterval {
        switch self {
        case .fast: return 0.5
        case .walls: return 0.3
        case .largeObjects: return 0.2
        case .smallObjects: return 0.1
        case .organic: return 0.15
        }
    }

    // Whether to use front camera (TrueDepth for face scanning)
    var useFrontCamera: Bool {
        switch self {
        case .organic: return false // Start with back, can switch
        default: return false
        }
    }

    // Guidance text shown during scanning
    var guidanceText: String {
        switch self {
        case .fast:
            return "Move quickly around the area"
        case .walls:
            return "Point at walls and corners slowly"
        case .largeObjects:
            return "Circle around the object slowly"
        case .smallObjects:
            return "Hold steady, move very slowly"
        case .organic:
            return "Keep subject still, move around them"
        }
    }
}
