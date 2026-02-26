# LiDAR Scanner - 3D Object Scanner & CAD Finder

An iOS app that uses iPhone's LiDAR sensor to scan physical objects, extract dimensions, identify them via web search and ML, and find matching CAD files from online repositories.

## Features

- **LiDAR Scanning**: Capture 3D mesh data using iPhone's LiDAR sensor
- **Dimension Extraction**: Automatically calculate object dimensions (L×W×H)
- **Shape Analysis**: Detect primitive shapes (box, cylinder, sphere, etc.)
- **Object Identification**: Multi-strategy identification using:
  - Visual search (Google Vision API)
  - ML classification (Core ML)
  - Dimension-based matching
- **CAD File Search**: Find matching CAD files from:
  - GrabCAD
  - TraceParts
  - Thingiverse
- **3D Viewer**: View and compare scanned meshes with CAD models
- **AR Preview**: Overlay CAD models on real objects using AR

## Requirements

- iPhone 12 Pro or newer (LiDAR equipped)
- iOS 17.0+
- Xcode 15+
- macOS Sonoma or newer (for development)

## Getting Started

### Development Setup

Since you're developing on Windows, you have two options:

#### Option A: Cloud Mac (Recommended)
1. Sign up for [MacinCloud](https://www.macincloud.com) (~$30/month)
2. Connect via Remote Desktop
3. Install Xcode from the Mac App Store
4. Clone this repository
5. Open `LiDARScanner.xcodeproj` in Xcode

#### Option B: GitHub Actions (CI/CD only)
1. Push code changes to GitHub
2. Configure GitHub Actions with `macos-latest` runner
3. Build and distribute via TestFlight

### API Keys Required

Create a file `Config/APIKeys.swift` (not tracked in git):

```swift
enum APIKeys {
    static let googleCloud = "your-google-cloud-api-key"
    static let grabcad = "your-grabcad-api-key"  // Optional
    static let traceparts = "your-traceparts-api-key"  // Optional
    static let thingiverse = "your-thingiverse-api-key"  // Optional
}
```

### Building the Project

1. Open the project in Xcode
2. Select your development team in Signing & Capabilities
3. Connect your iPhone (12 Pro or newer)
4. Build and run (⌘+R)

## Project Structure

```
LiDARScanner/
├── App/                          # App entry point and main views
├── Features/
│   ├── Scanner/                  # LiDAR scanning functionality
│   │   ├── Views/
│   │   ├── ViewModels/
│   │   └── Services/
│   ├── Processor/                # Dimension & shape extraction
│   ├── Identifier/               # Object identification
│   ├── CADFinder/               # CAD file search & download
│   │   └── Providers/
│   └── Viewer/                   # 3D model viewing
├── Core/
│   ├── Models/                   # Data models
│   ├── Networking/               # API client
│   └── Utilities/                # Extensions & helpers
└── Resources/
    └── MLModels/                 # Core ML models
```

## Usage

1. **Scan an Object**
   - Open the app and point your camera at an object
   - Tap the capture button to start scanning
   - Move around the object to capture all angles
   - Tap again to stop and process

2. **Review Dimensions**
   - View extracted dimensions (L×W×H)
   - See detected shape type
   - Export mesh as OBJ, STL, or USDZ

3. **Identify Object**
   - Tap "Identify Object"
   - Review identification results
   - Select the most accurate match

4. **Find CAD Files**
   - View matching CAD files from online repositories
   - Download files in your preferred format
   - Compare with your scanned mesh

5. **View & Compare**
   - Open downloaded CAD files in 3D viewer
   - Use AR mode to overlay CAD on real object
   - Side-by-side comparison view

## Architecture

The app follows MVVM architecture with clear separation of concerns:

- **Views**: SwiftUI views for UI
- **ViewModels**: Business logic and state management
- **Services**: Data fetching and processing
- **Models**: Data structures

Key frameworks used:
- **ARKit/RealityKit**: LiDAR scanning and AR
- **SceneKit**: 3D model rendering
- **Vision/Core ML**: Image classification
- **ModelIO**: 3D model import/export

## Supported File Formats

| Format | Import | Export |
|--------|--------|--------|
| USDZ   | ✓      | ✓      |
| OBJ    | ✓      | ✓      |
| STL    | ✓      | ✓      |
| STEP   | -      | -      |

## Contributing

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

MIT License - see LICENSE file for details

## Acknowledgments

- [ARKit Documentation](https://developer.apple.com/arkit/)
- [GrabCAD Community](https://grabcad.com)
- [TraceParts](https://www.traceparts.com)
- [Thingiverse](https://www.thingiverse.com)
