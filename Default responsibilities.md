# Default Responsibilities

## After Every Code Change

1. **Commit to Git**
   - Stage all modified files
   - Write a descriptive commit message summarizing what changed and why
   - Push to `origin master`

2. **Trigger Codemagic Build**
   - App ID: `69a0ccc39374c00bf5f24cb8`
   - Default workflow: `ios-adhoc` (quick test builds)
   - Use `ios-workflow` for TestFlight / release builds
   - Trigger via Codemagic API:
     ```
     POST https://api.codemagic.io/builds
     Headers: x-auth-token: <CM_API_TOKEN>
     Body: { "appId": "69a0ccc39374c00bf5f24cb8", "workflowId": "ios-adhoc", "branch": "master" }
     ```
   - Build page: https://codemagic.io/app/69a0ccc39374c00bf5f24cb8

## Notes
- The Codemagic API token (`CM_API_TOKEN`) must be provided by the user or stored in the environment.
- Always commit first, then trigger the build so Codemagic picks up the latest push.
- Report the build URL after triggering so the user can monitor progress.

---

# Project Architecture & File Responsibilities

## iOS App (Swift / SwiftUI)

### Entry Point
- **LiDARScannerApp.swift** - App entry, launches ContentView

### Main Views
- **ContentView.swift** - Home screen, scan mode selection, scan lifecycle (start/stop), project picker after scan, upload to server
- **ScannerView.swift** - Alternate scanner UI with same scan lifecycle, project picker, upload flow

### Views/
- **ProjectPickerView.swift** - Post-scan sheet: pick or create a server project folder before uploading. Selected project persists as default
- **ExportView.swift** - Export scan to PLY/USDZ/OBJ formats
- **SettingsView.swift** - App settings UI (export prefs, classification params, auto-save toggle, room layout mode)
- **SavedSessionsView.swift** - Browse, rename, resume saved scan sessions
- **PhotogrammetryView.swift** - Photo-based reconstruction from auto-captured images
- **MultiRoomView.swift** - Multi-room scanning with door connections between rooms
- **ArchitecturalExtractionView.swift** - Extract architectural features from scans
- **AnnotationView.swift** - Annotate scan features
- **TextureOverlayView.swift** - Texture projection overlay on mesh
- **TestModeOverlayView.swift** - Full-screen reticle for test/calibration mode
- **UpdateProgressView.swift** - OTA update download progress
- **WhatsNewView.swift** - Version changelog display

### Managers/
- **MeshManager.swift** - Core scanning engine: ARSession, mesh capture, surface classification, edge detection, auto photo capture coordination
- **SurfaceClassifier.swift** - Classifies mesh faces as floor/ceiling/wall/object/protrusion/door/window using normals + height calibration + ML
- **ScanServerManager.swift** - Uploads scans to ScanWizard server. Manages project folders (list, create). API key auth
- **ScanSessionManager.swift** - Local persistence of scan sessions (save, load, update, delete)
- **TrainingDataExporter.swift** - Exports scans as NumPy-compatible JSON (points + normals + labels) for ML training and server upload
- **MeshExporter.swift** - Exports meshes to PLY, USDZ, OBJ with surface type grouping
- **MeshImporter.swift** - Imports mesh files back into the app
- **GoogleDriveManager.swift** - Google Drive upload (legacy, replaced by ScanServerManager)
- **AutoPhotoCapture.swift** - Auto-captures photos during scanning at regular intervals/distances
- **EdgeVisualizer.swift** - Visualizes detected edges in AR overlay
- **MultiRoomManager.swift** - Multi-room scans: room list, door labeling, alignment transforms
- **RoomBuilder.swift** - Builds room geometry from classified surfaces
- **RoomSimplifier.swift** - Simplifies room geometry, snaps to right angles
- **WallReconstructor.swift** - Reconstructs wall surfaces from point cloud
- **ArchitecturalExtractor.swift** - Extracts doors, windows, openings from mesh
- **TextureOverlayManager.swift** - Texture overlay state and rendering
- **TextureProjector.swift** - Projects camera textures onto mesh
- **TestModeDetector.swift** - Edge/feature detection in test mode
- **UpdateChecker.swift** - Checks GitHub for new app versions

### Models/
- **AppSettings.swift** - All @AppStorage settings: export prefs, classification params, selected server project, calibration toggles
- **CapturedMesh.swift** - Captured mesh model (vertices, faces, normals, classification)
- **SavedScanSession.swift** - Persistable scan session (UUID, name, dates, mesh data)
- **ScanMode.swift** - Scan mode enum (walls, floor, ceiling, test, etc.)

### Extensions/
- **ARMeshGeometry+Extensions.swift** - Helpers for ARMeshGeometry vertex/face/normal extraction

---

## Server (PHP) - scanwizard.robo-wizard.com

### tools/server/ (development copy)
### tools/upload_to_server/ (deployment copy - upload these to server)

- **upload.php** - POST scan JSON with X-API-Key. Supports `?project=` and `?filename=` params. Saves to `scans/{project}/`
- **list_projects.php** - GET: project folder list. POST: create new project folder
- **list_scans.php** - Returns scan manifest (JSON scans only, excludes photo sessions)
- **get_scan.php** - Returns specific scan JSON by filename
- **upload_photos.php** - Receives photos + camera poses as base64 JSON
- **detect_features.php** - AI door/window detection via Anthropic API (Claude Vision)
- **build_status.php** - Build/processing status
- **index.php** - Web dashboard
- **login.php** - Authentication
- **includes/config.php** - DB credentials, API keys, paths, limits

---

## Web Tools

- **tools/PointCloudLabeler.html** - Browser-based point cloud labeler with:
  - Load from local/server, auto-classify, manual label (paint/erase)
  - Guide drawing (polygon, polyline, trim, extend) with AutoCAD crosshair cursor
  - Drawing sessions stay active during pan/zoom/rotate; right-click to finish
  - Window zoom, boundary construction, multi-scan insert/align/nudge
  - Top menu bar: Project (Open/Save local & server, Export GLB/JSON/ML)
  - Visibility toggles (collapsible left toolbar), photogrammetry layer
  - Ctrl+O/S/Shift+S/Z shortcuts

- **tools/watch_scans.py** - Local dev scan watcher
- **tools/analyze_floor.py** - Floor analysis utility
- **tools/Start Labeler.bat** - Windows launcher for local labeler

---

## Data Flow

1. **Scan**: iOS captures LiDAR mesh via ARKit -> MeshManager classifies surfaces
2. **Export**: TrainingDataExporter converts to NumPy JSON (points + normals + labels)
3. **Project Selection**: ProjectPickerView shows server folders, user picks (persists as default)
4. **Upload**: ScanServerManager POSTs JSON to upload.php with `?project=` param
5. **Server Storage**: Saves to `scans/{project}/scan_TIMESTAMP.json`, updates manifest
6. **Labeling**: PointCloudLabeler loads from server, user refines labels, saves back
7. **Training**: Export labeled data for ML training

---

## Key Configuration

- **Server URL**: `https://scanwizard.robo-wizard.com`
- **API Key**: `ScanWizard2025Secret` (match in ScanServerManager.swift and config.php)
- **Max upload**: 128 MB
- **Scans path**: `scans/` (with project subfolders)
