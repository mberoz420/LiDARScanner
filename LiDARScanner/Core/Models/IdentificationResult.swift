import Foundation

/// Result from object identification process
struct IdentificationResult: Identifiable, Codable {
    let id: UUID
    let name: String
    let description: String?
    let confidence: Float
    let source: IdentificationSource
    let category: ObjectCategory?
    let relatedSearchTerms: [String]
    let imageURL: URL?
    let productURL: URL?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        confidence: Float,
        source: IdentificationSource,
        category: ObjectCategory? = nil,
        relatedSearchTerms: [String] = [],
        imageURL: URL? = nil,
        productURL: URL? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.confidence = confidence
        self.source = source
        self.category = category
        self.relatedSearchTerms = relatedSearchTerms
        self.imageURL = imageURL
        self.productURL = productURL
        self.timestamp = timestamp
    }

    /// Confidence level for display
    var confidenceLevel: ConfidenceLevel {
        switch confidence {
        case 0.8...1.0: return .high
        case 0.5..<0.8: return .medium
        default: return .low
        }
    }

    enum ConfidenceLevel {
        case high, medium, low

        var color: String {
            switch self {
            case .high: return "green"
            case .medium: return "orange"
            case .low: return "red"
            }
        }

        var description: String {
            switch self {
            case .high: return "High Confidence"
            case .medium: return "Medium Confidence"
            case .low: return "Low Confidence"
            }
        }
    }
}

/// Source of the identification result
enum IdentificationSource: String, Codable {
    case visualSearch = "Visual Search"
    case mlClassification = "ML Classification"
    case dimensionMatch = "Dimension Match"
    case userInput = "User Input"
    case combined = "Combined Analysis"

    var iconName: String {
        switch self {
        case .visualSearch: return "magnifyingglass"
        case .mlClassification: return "brain"
        case .dimensionMatch: return "ruler"
        case .userInput: return "person.fill"
        case .combined: return "sparkles"
        }
    }
}

/// Object category for classification
enum ObjectCategory: String, Codable, CaseIterable {
    // Mechanical
    case bolt
    case nut
    case screw
    case washer
    case bearing
    case gear
    case pulley
    case shaft
    case bracket
    case fitting
    case valve
    case pump
    case motor

    // Electronics
    case connector
    case cable
    case adapter
    case sensor
    case switch_
    case relay
    case pcb
    case enclosure

    // Household
    case furniture
    case appliance
    case container
    case tool
    case fixture

    // General
    case other
    case unknown

    var displayName: String {
        switch self {
        case .switch_: return "Switch"
        default: return rawValue.capitalized
        }
    }

    var parentCategory: String {
        switch self {
        case .bolt, .nut, .screw, .washer, .bearing, .gear, .pulley, .shaft, .bracket, .fitting, .valve, .pump, .motor:
            return "Mechanical"
        case .connector, .cable, .adapter, .sensor, .switch_, .relay, .pcb, .enclosure:
            return "Electronics"
        case .furniture, .appliance, .container, .tool, .fixture:
            return "Household"
        case .other, .unknown:
            return "General"
        }
    }

    /// Related CAD search terms
    var searchTerms: [String] {
        switch self {
        case .bolt: return ["bolt", "hex bolt", "machine bolt", "cap screw"]
        case .nut: return ["nut", "hex nut", "lock nut", "wing nut"]
        case .screw: return ["screw", "machine screw", "wood screw", "self-tapping"]
        case .bearing: return ["bearing", "ball bearing", "roller bearing", "bushing"]
        case .gear: return ["gear", "spur gear", "helical gear", "bevel gear"]
        case .connector: return ["connector", "plug", "socket", "terminal"]
        default: return [rawValue]
        }
    }
}

/// Combined identification result with multiple sources
struct CombinedIdentification {
    let topResult: IdentificationResult
    let allResults: [IdentificationResult]
    let scannedObject: ScannedObject
    let searchTerms: [String]

    /// Get unique search terms from all results
    var uniqueSearchTerms: [String] {
        var terms = Set<String>()
        terms.insert(topResult.name)
        for result in allResults {
            terms.formUnion(result.relatedSearchTerms)
        }
        return Array(terms)
    }
}
