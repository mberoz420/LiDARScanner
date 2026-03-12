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
- **PhotogrammetryView.swift** - Multi-mode scanning (Object/Cube, Free, Photo, LiDAR). Project picker on stop. Uploads photos and LiDAR scans to selected project folder. Box toggle for LiDAR/Free/Photo modes. Done overlay with New Scan/Back buttons
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
- **ScanServerManager.swift** - Uploads scans to ScanWizard server. Manages project folders (list, create). API key auth. Notifies Eva brain after upload
- **EvaBrainManager.swift** - Eva AI central brain sync. Pulls/pushes knowledge (rules, params, decisions, learnings) to/from server. Syncs on app launch
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
- **upload_photos.php** - Receives photos + camera poses as base64 JSON. Supports `?project=` to save under `scans/{project}/photos/`
- **file_manager.php** - Full CRUD file manager API: list, mkdir, delete, copy, rename, move. Path sanitized against traversal
- **detect_features.php** - AI door/window detection via Anthropic API (Claude Vision)
- **build_status.php** - Build/processing status
- **index.php** - Web dashboard (auth-protected, shows user menu with admin link)
- **login.php** - Login/Register tabbed UI. New registrations go to 'pending' status
- **labeler.php** - Session-checking wrapper that serves PointCloudLabeler.html to authenticated users
- **admin.php** - Admin panel: view pending/approved/rejected users, approve/reject with email notifications
- **setup_db.php** - One-time DB setup: creates users table + default admin account. DELETE after running
- **reset-password.php** - Password reset landing page (from email link), verifies token and accepts new password
- **api/auth.php** - Auth API: login, register, logout, approve, reject, list_users, verify_reset_token, reset_password
- **api/eva.php** - Eva AI central brain API: GET/POST knowledge base (params, rules, decisions, learnings, scan history). Shared by Swift app, Ollama, PointCloudLabeler, and Claude
- **includes/config.php** - DB credentials, API keys, paths, limits, ADMIN_EMAIL
- **includes/db.php** - PDO connection helper (singleton)
- **includes/.htaccess** - Blocks direct web access to include files
- **.htaccess** - Blocks direct access to PointCloudLabeler.html, config.php, setup_db.php

---

## Web Tools

- **tools/PointCloudLabeler.html** - Browser-based point cloud labeler with:
  - Load from local/server, auto-classify, manual label (paint/erase)
  - Guide drawing (polygon, polyline, spline, trim, extend, marker) with AutoCAD crosshair cursor
  - Tube-based thick guide lines (TubeGeometry) with configurable width and color
  - Circle+dot vertex markers on guide lines (canvas sprite textures)
  - Drawing sessions stay active during pan/zoom/rotate; right-click to finish
  - Window zoom, boundary construction, multi-scan insert/align/nudge
  - Camera distance heatmap color mode (green→red, from camera_track data)
  - Density lines: top-down XZ ridge detection with PCA line fitting for wall detection
  - Construction layer (separate from guide lines, reddish color, togglable)
  - Two-click extend: select two lines → both extend to intersection point
  - Auto Extend All: batch-extend every polyline endpoint to nearest neighbor
  - Build Walls: extend+trim guide lines at intersections, extrude to 3D wall planes
  - Plane Fit tool: PCA plane fitting with orthogonal/free mode toggle
  - Draw plane lock (XZ plane at configurable Y height)
  - Custom SVG cursors for trim/extend/planefit tools
  - Action logging system: records every tool action with camera state for AI training
  - Notebook: floating draggable panel with live activity feed, "Why?" annotations per action
  - Tagged notes (Observation, Decision, Issue, Technique, Rule) with camera pinning
  - Action log + notebook saved with project, exportable as training data
  - Unified Save Project dialog (server/local, folder picker, create folder)
  - Top menu bar: Project (Open/Save local & server, Export GLB/JSON/ML/Action Log)
  - Visibility toggles (collapsible left toolbar, 240px wide), photogrammetry layer
  - Right sidebar (260px, compact controls)
  - Ctrl+O/S/Shift+S/Z shortcuts, S for spline, N for note, Shift+N for notebook
  - File Manager: browse server files, create folders, rename, copy, delete
  - Auto front-direction from vertical surface normals (scan orientation)
  - Density magnet: cursor snaps toward dense point regions when drawing (XZ weighted centroid)
  - Eva AI: auto-complete room boundary via A* pathfinding through density grid
  - Eva AI: Draw Boundary — outside-in ray-casting with learnable parameters
  - Eva AI: Detect Glass — find LiDAR pass-through window artifacts (beyond boundary + annotation + sparse region detection)
  - Eva AI: Learn from Corrections — compares Eva's boundary to user edits, asks Ollama for parameter adjustments
  - Eva AI: Ask Eva — chat input that sends scan context to local Ollama (Llama 3.1 8B) for intelligent analysis
  - Eva Central Brain — syncs knowledge (rules, params, learnings, decisions) with server via api/eva.php
  - Observer arrows: directional camera/viewpoint indicators, two-click placement (A key)
  - Annotation circles: tagged area markers (gap/window/noise/door/obstruction/other) with color coding (C key)
  - Annotation polygons: irregular area markers with tagged fill, used to teach Eva about regions (G key)
  - Action replay: re-execute drawing actions from action log with animation
  - Vertex numbering: numbered labels on guide line vertices (canvas sprite textures)
  - Why-history auto-fill: suggests reasons for actions based on user history and built-in defaults
- **AI_KNOWLEDGE_BASE.md** - Comprehensive design rationale document for AI training: system purpose, tool explanations, workflow patterns, data formats, decision reasoning

- **tools/watch_scans.py** - Local dev scan watcher
- **tools/analyze_floor.py** - Floor analysis utility
- **tools/Start Labeler.bat** - Windows launcher for local labeler

---

## Data Flow

1. **App Launch**: iOS syncs Eva's brain from server (rules, params, learnings) via EvaBrainManager
2. **Scan**: iOS captures LiDAR mesh via ARKit -> MeshManager classifies surfaces
3. **Export**: TrainingDataExporter converts to NumPy JSON (points + normals + labels)
4. **Project Selection**: ProjectPickerView shows server folders, user picks (persists as default)
5. **Upload**: ScanServerManager POSTs JSON to upload.php with `?project=` param
6. **Eva Notified**: After upload, EvaBrainManager logs scan summary + decision to server brain
7. **Server Storage**: Saves to `scans/{project}/scan_TIMESTAMP.json`, updates manifest
8. **Labeling**: PointCloudLabeler loads from server, syncs Eva brain, user refines labels
9. **Eva Learns**: User corrects Eva's boundary → Ollama analyzes → params updated → pushed to server brain
10. **Training**: Export labeled data for ML training
11. **Next Session**: All systems (iOS, Labeler, Ollama, Claude) pull Eva's latest knowledge from server

## Eva AI Architecture

```
┌─────────────────────────────────────────────────┐
│        Eva Central Brain (server)               │
│        /api/eva.php → /eva/knowledge.json       │
│                                                 │
│  params, rules, decisions, learnings, history   │
└──────┬──────────┬──────────┬──────────┬─────────┘
       │          │          │          │
  ┌────┴───┐ ┌───┴────┐ ┌───┴───┐ ┌───┴──────┐
  │ Swift  │ │Labeler │ │Ollama │ │ Claude   │
  │iOS App │ │  Web   │ │Local  │ │ Sessions │
  │        │ │        │ │  AI   │ │          │
  └────────┘ └────────┘ └───────┘ └──────────┘
```

---

## Key Configuration

- **Server URL**: `https://scanwizard.robo-wizard.com`
- **API Key**: `ScanWizard2025Secret` (match in ScanServerManager.swift, EvaBrainManager.swift, and config.php)
- **Eva Brain API**: `https://scanwizard.robo-wizard.com/api/eva.php`
- **Eva Knowledge Store**: `eva/knowledge.json` on server
- **Ollama (local AI)**: `http://localhost:11434` — Llama 3.1 8B model
- **Max upload**: 128 MB
- **Scans path**: `scans/` (with project subfolders)
