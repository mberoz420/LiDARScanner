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
            return "Hold steady 15-30cm away, move very slowly"
        case .organic:
            return "Keep subject still, move around them"
        }
    }

    // Recommended object size range
    var sizeRange: String {
        switch self {
        case .fast:
            return "Any size"
        case .walls:
            return "Rooms 2m - 20m"
        case .largeObjects:
            return "50cm - 5m"
        case .smallObjects:
            return "2cm - 15cm"
        case .organic:
            return "30cm - 2m"
        }
    }

    // Optimal scanning distance
    var optimalDistance: String {
        switch self {
        case .fast:
            return "1 - 5m"
        case .walls:
            return "1 - 5m"
        case .largeObjects:
            return "0.5 - 3m"
        case .smallObjects:
            return "15 - 30cm"
        case .organic:
            return "0.5 - 2m"
        }
    }

    // Expected accuracy
    var accuracy: String {
        switch self {
        case .fast:
            return "±3-5cm"
        case .walls:
            return "±2-3cm"
        case .largeObjects:
            return "±1-2cm"
        case .smallObjects:
            return "±0.5-1cm"
        case .organic:
            return "±0.5-1cm (face), ±1-2cm (body)"
        }
    }

    // Minimum detectable feature size
    var minFeatureSize: String {
        switch self {
        case .fast:
            return "~5cm"
        case .walls:
            return "~3cm"
        case .largeObjects:
            return "~2cm"
        case .smallObjects:
            return "~1cm"
        case .organic:
            return "~0.5cm (face)"
        }
    }

    // Tips for best results
    var tips: [String] {
        switch self {
        case .fast:
            return [
                "Good for quick area overview",
                "Move at walking pace",
                "Don't expect fine details"
            ]
        case .walls:
            return [
                "Start in a corner",
                "Pan slowly along walls",
                "Include ceiling and floor edges"
            ]
        case .largeObjects:
            return [
                "Walk slowly around the object",
                "Maintain consistent distance",
                "Overlap coverage areas"
            ]
        case .smallObjects:
            return [
                "Objects must be >2cm to capture",
                "Hold device very steady",
                "Good lighting helps",
                "Place object on contrasting surface"
            ]
        case .organic:
            return [
                "Subject must stay completely still",
                "Use front camera for face detail",
                "Use back camera for full body",
                "Multiple slow passes improve quality"
            ]
        }
    }
}
