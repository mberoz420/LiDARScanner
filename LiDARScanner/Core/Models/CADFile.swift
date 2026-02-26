import Foundation

/// Represents a CAD file from an online repository
struct CADFile: Identifiable, Codable {
    let id: UUID
    let name: String
    let description: String?
    let format: CADFormat
    let source: CADSource
    let sourceURL: URL
    let downloadURL: URL?
    let thumbnailURL: URL?
    let fileSize: Int64?
    let downloadDate: Date?
    var localFileURL: URL?

    /// Dimensions from CAD metadata (if available)
    var dimensions: SIMD3<Float>?

    /// Category/tags for the model
    var tags: [String]

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        format: CADFormat,
        source: CADSource,
        sourceURL: URL,
        downloadURL: URL? = nil,
        thumbnailURL: URL? = nil,
        fileSize: Int64? = nil,
        downloadDate: Date? = nil,
        localFileURL: URL? = nil,
        dimensions: SIMD3<Float>? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.format = format
        self.source = source
        self.sourceURL = sourceURL
        self.downloadURL = downloadURL
        self.thumbnailURL = thumbnailURL
        self.fileSize = fileSize
        self.downloadDate = downloadDate
        self.localFileURL = localFileURL
        self.dimensions = dimensions
        self.tags = tags
    }

    /// Check if file is downloaded locally
    var isDownloaded: Bool {
        guard let url = localFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Formatted file size string
    var fileSizeString: String? {
        guard let size = fileSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

/// Supported CAD file formats
enum CADFormat: String, Codable, CaseIterable {
    case step = "step"
    case stp = "stp"
    case stl = "stl"
    case obj = "obj"
    case iges = "iges"
    case igs = "igs"
    case fbx = "fbx"
    case usdz = "usdz"
    case threeds = "3ds"
    case dxf = "dxf"
    case dwg = "dwg"

    var displayName: String {
        switch self {
        case .step, .stp: return "STEP"
        case .stl: return "STL"
        case .obj: return "OBJ"
        case .iges, .igs: return "IGES"
        case .fbx: return "FBX"
        case .usdz: return "USDZ"
        case .threeds: return "3DS"
        case .dxf: return "DXF"
        case .dwg: return "DWG"
        }
    }

    /// Formats that can be directly rendered in SceneKit/RealityKit
    var isNativelySupported: Bool {
        switch self {
        case .usdz, .obj, .stl: return true
        default: return false
        }
    }

    /// File extension with dot
    var fileExtension: String {
        ".\(rawValue)"
    }
}

/// CAD file source repositories
enum CADSource: String, Codable, CaseIterable {
    case grabcad = "GrabCAD"
    case traceparts = "TraceParts"
    case thingiverse = "Thingiverse"
    case mcmastercarr = "McMaster-Carr"
    case contentcentral = "3D ContentCentral"
    case local = "Local"

    var baseURL: URL? {
        switch self {
        case .grabcad: return URL(string: "https://grabcad.com")
        case .traceparts: return URL(string: "https://www.traceparts.com")
        case .thingiverse: return URL(string: "https://www.thingiverse.com")
        case .mcmastercarr: return URL(string: "https://www.mcmaster.com")
        case .contentcentral: return URL(string: "https://www.3dcontentcentral.com")
        case .local: return nil
        }
    }

    var iconName: String {
        switch self {
        case .grabcad: return "cube.fill"
        case .traceparts: return "gearshape.2.fill"
        case .thingiverse: return "printer.fill"
        case .mcmastercarr: return "wrench.and.screwdriver.fill"
        case .contentcentral: return "square.3.layers.3d"
        case .local: return "folder.fill"
        }
    }
}

/// Search result from CAD repository
struct CADSearchResult: Identifiable {
    let id: UUID
    let file: CADFile
    let relevanceScore: Float
    let matchType: MatchType

    enum MatchType: String {
        case nameMatch = "Name Match"
        case dimensionMatch = "Dimension Match"
        case categoryMatch = "Category Match"
        case combined = "Multiple Matches"
    }

    init(file: CADFile, relevanceScore: Float, matchType: MatchType) {
        self.id = UUID()
        self.file = file
        self.relevanceScore = relevanceScore
        self.matchType = matchType
    }
}
