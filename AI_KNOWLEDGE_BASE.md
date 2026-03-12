# ScanWizard AI Knowledge Base
## System Design Rationale & Training Reference

> This document captures the **WHY** behind every tool, feature, and decision in the ScanWizard ecosystem. It's structured as training material for an AI that needs to understand not just what exists, but the reasoning chain that created it.

---

## 1. System Purpose & Vision

**Problem:** LiDAR scanners capture millions of 3D points but can't tell you what they mean. A wall looks the same as a bookshelf — both are just points in space. Humans can look at a room scan and instantly know "that's a wall, that's a door, that's furniture" but teaching a machine to do this requires massive amounts of labeled data.

**Solution:** A complete pipeline: **Capture → Upload → Label → Train → Improve**

```
iPhone LiDAR ──→ Server ──→ Web Labeler ──→ ML Training ──→ Better Auto-Classification
     ↑                                                              │
     └──────────── Improved model deployed back to app ─────────────┘
```

**Key Insight:** The labeler isn't just a tool — it's a **data factory**. Every action the user takes (drawing a wall line, fitting a plane, trimming geometry) is training data. The action log + notebook captures the expert's reasoning so the AI learns not just WHAT to label, but WHY.

---

## 2. iOS App — Why Each Component Exists

### 2.1 Scanning Pipeline

**MeshManager.swift** — *The orchestrator*
- WHY: ARKit fires mesh updates 30+ times/second. Raw data is useless without processing. MeshManager throttles, filters, classifies, and routes data to the right systems.
- DESIGN CHOICE: Mesh update frequency varies by ScanMode (0.1s for Fast, 0.5s for Organic) because different scan targets need different quality/speed tradeoffs.

**SurfaceClassifier.swift** — *The brain*
- WHY: Real-time surface classification enables the AR overlay that shows users colored surfaces as they scan. Without this, users scan blind.
- DESIGN CHOICE: Hybrid approach (geometry + ML) because geometric heuristics work well for simple rooms but fail on unusual geometry (vaulted ceilings, sloped walls). ML fills the gaps, but geometry provides the fallback when ML is uncertain.
- KEY INSIGHT: Floor and ceiling detection uses normal vectors (Y-component thresholds from AppSettings). Walls use the complement. This works because gravity ensures floors/ceilings are roughly horizontal.
- CALIBRATION: User pauses on floor/ceiling for 3 seconds to lock height planes. This dramatically improves classification because once you know the exact floor height, everything at that height ±tolerance is definitely floor.

**AppSettings.swift** — *The tuning knobs*
- WHY: Every room is different. A warehouse has 12m ceilings; a bathroom has 2.4m. The same angle thresholds don't work for both. Settings let users tune without code changes.
- KEY SETTINGS: `floorCeilingAngle` (32°), `wallAngle` (72°), `protrusionMinDepth` (3cm), room layout filtering mode.

### 2.2 Export Pipeline

**TrainingDataExporter.swift** — *The bridge to ML*
- WHY: The app classifies surfaces in real-time, but these classifications are imperfect. Exporting as `LabeledPoint(x,y,z,nx,ny,nz,label)` format lets the web labeler refine labels, then the corrected data trains better models.
- FORMAT CHOICE: JSON with flat arrays because it's universally readable (Python, JavaScript, C++) and human-inspectable. Binary formats are faster but harder to debug.

**ScanServerManager.swift** — *Automatic upload*
- WHY: Users shouldn't have to manually export and upload. Auto-save after each scan means the data is on the server ready for labeling within seconds of scanning.
- DESIGN CHOICE: Project-based folders because users scan multiple rooms/buildings. Without organization, the server would be a flat mess of hundreds of files.

### 2.3 Photogrammetry Pipeline

**AutoPhotoCapture.swift** — *Automatic photo capture during scanning*
- WHY: LiDAR gives geometry but poor texture. Photos give texture but no geometry. Combining them gives complete reconstructions.
- DESIGN CHOICE: Stillness detection (device speed < threshold for 0.6s) because blurry photos are useless. The 7cm/12° movement requirement between captures prevents redundant shots.
- ENGINEERING: Max 60 photos because upload size grows linearly. Each photo is ~200KB JPEG, so 60 photos ≈ 12MB — manageable on cellular.

**TextureProjector.swift** — *Projects camera color onto mesh*
- WHY: LiDAR mesh vertices have no color by default. This projects the camera image onto the geometry to add color information.
- TECHNICAL: Handles both YCbCr (camera native) and BGRA (processed) pixel formats because ARKit provides different formats in different contexts.

### 2.4 Room Understanding

**RoomBuilder.swift** — *Extracts room structure*
- WHY: Raw mesh contains everything (walls, furniture, cables, reflections). Room builder separates structural elements from contents.
- KEY LOGIC: A wall must span floor-to-ceiling (within tolerance). This single rule eliminates most furniture because bookshelves, tables, etc. don't reach the ceiling.

**MultiRoomManager.swift** — *Stitches rooms together*
- WHY: You can't scan an entire building in one session. Multi-room stitching lets you scan room-by-room and combine later.
- KEY CONCEPT: Door correspondence. "Kitchen door A" connects to "Living room door B". Once doors are matched, the transform to align rooms is determined.

**WallReconstructor.swift** — *Clean wall surfaces*
- WHY: Scanned walls have gaps (behind furniture, LiDAR blind spots). Wall reconstruction fills these gaps to produce watertight geometry for architectural plans.

**RoomSimplifier.swift** — *2D floor plan from 3D mesh*
- WHY: Architects need simple 2D floor plans, not million-point 3D meshes. This extracts the room outline as a 2D polygon.

---

## 3. Server — Why Each Endpoint Exists

### 3.1 Data Ingestion

**upload.php** — *Receives scan JSON from iOS app*
- WHY: The app needs a stateless API to push data immediately after scanning.
- DESIGN: API key auth (not user auth) because the app runs unattended. Project parameter organizes uploads into folders.

**upload_photos.php** — *Receives photogrammetry sessions*
- WHY: Photos + camera poses + depth maps need to travel together as a session. Can't upload individually because the spatial relationship would be lost.
- FORMAT: Base64-encoded images in JSON because multipart form uploads are unreliable on slow cellular connections.

### 3.2 Data Discovery

**list_projects.php** — *Shows available project folders*
- WHY: Both the iOS app (pre-upload folder picker) and web labeler (open dialog) need to know what folders exist.

**list_scans.php** — *Scan inventory with metadata*
- WHY: The labeler needs a manifest to show users what's available to label. Includes point counts and timestamps so users can find the right scan.
- DESIGN: Excludes photo sessions from scan list because they're a different data type with different loading logic.

**get_scan.php** — *Streams raw scan JSON*
- WHY: The labeler needs to download full point cloud data. This streams the file directly (readfile) to avoid PHP memory limits on large scans.

### 3.3 Management

**file_manager.php** — *Full CRUD for server files*
- WHY: The web labeler needs to browse, organize, rename, copy, and delete files without SSH access.
- SECURITY: Path traversal protection (`safePath()`) because this endpoint accepts user-provided paths.

### 3.4 AI-Assisted Labeling

**detect_features.php** — *Claude Vision for door/window detection*
- WHY: Doors and windows are notoriously hard for LiDAR (glass is invisible, doors can be open or closed). Using camera photos + Claude's vision capabilities identifies these features that LiDAR misses.

### 3.5 Authentication

**login.php / api/auth.php** — *User management with approval workflow*
- WHY: Scan data is private (building interiors). Can't be publicly accessible. Approval workflow prevents unauthorized access.
- DESIGN: Admin must approve new registrations because this is a small team, not a public service.

**labeler.php** — *Gateway to PointCloudLabeler.html*
- WHY: `.htaccess` blocks direct access to the HTML file. This PHP wrapper checks session auth before serving the labeler. Prevents unauthenticated access to the labeling tool (and by extension, scan data).

---

## 4. PointCloudLabeler — Why Each Tool Exists

### 4.1 The Core Problem

You have a cloud of 50,000+ 3D points. Some are walls, some are floor, some are furniture, some are noise. You need to label every single one correctly. Manual point-by-point labeling would take hours. The labeler provides tools to label efficiently:

1. **Automatic classification** handles 70-80% correctly
2. **Boundary drawing** fixes the room outline (fixes wall classification)
3. **Paint/erase** fixes individual regions
4. **Guide geometry** documents structural features for training data

### 4.2 Drawing Tools

**Polyline (L)** — *Trace wall edges and structural lines*
- WHY: Wall reconstruction needs explicit wall centerlines. The polyline tool lets users trace walls from the top-down view.
- DESIGN: Right-click menu to finish (not double-click) because double-click could be mistaken for two points.

**Polygon (G)** — *Outline closed regions*
- WHY: Floor plans are closed shapes. Polygon mode auto-closes when you click near the first point.

**Spline (S)** — *Smooth curves*
- WHY: Not all architectural features are straight lines. Curved walls, arched doorways, and organic shapes need smooth curves.

**Marker (M)** — *Reference points*
- WHY: Mark specific locations (door corners, measurement references) without drawing lines. Markers are snap targets for other tools.

### 4.3 Edit Tools

**Trim (T)** — *Cut lines at intersections*
- WHY: When tracing walls, lines often overshoot past intersections. Trim cuts them back to the intersection point.
- LOGIC: Finds all intersections of clicked segment with other lines, splits at the nearest one to the click position.

**Extend (X)** — *Two-click: make two lines meet*
- WHY: Wall corners are where two walls meet. Often you draw two walls that don't quite reach each other. Extend makes them meet at their mathematical intersection.
- DESIGN: Two-click workflow because extend needs TWO lines to work. First click selects, second click completes.
- VISUAL: First selected line highlights yellow so you know what you've picked.

**Auto Extend All (⟷)** — *Batch extend every endpoint*
- WHY: After drawing 20 wall segments, extending them one pair at a time is tedious. This automatically extends every endpoint to its nearest intersecting neighbor.
- LOGIC: For each true endpoint (first or last point of an open polyline), finds the nearest other line in the outward direction and moves the endpoint to the intersection.

### 4.4 Analysis Tools

**Build Walls** — *Convert 2D lines to 3D wall planes*
- WHY: Guide lines are just 2D traces. Build Walls extrudes them into vertical planes (floor to ceiling) and handles intersections — extending short segments and trimming overshoots.
- KEY LOGIC: For each segment, finds all pairwise intersections with other segments, keeps the nearest intersection at each end (whether that means extending or trimming).

**Density Lines** — *Auto-detect walls from point density*
- WHY: In top-down view, walls appear as dense ridges of points. This automatically detects those ridges using grid density + Laplacian edge detection + PCA line fitting.
- USE CASE: First pass at wall detection before manual refinement.

**Plane Fit** — *Fit geometric planes to point clusters*
- WHY: Point clouds are noisy. Fitting mathematical planes gives clean surface definitions for export. Orthogonal mode snaps to cardinal axes (most walls/floors are axis-aligned). Free mode handles sloped surfaces.

### 4.5 Classification System

**classifyByFarthestPlanes()** — *The core auto-classification algorithm*
- WHY THIS APPROACH: Most rooms have a key property — walls are the farthest points from the center at any angle. This is exploited by:
  1. Divide 360° into 1° bins
  2. In each bin, the farthest cluster of points at any height = wall
  3. Lowest dense Y-cluster = floor, highest = ceiling
  4. Everything else = object
- WHY NOT JUST NORMAL-BASED: Normal-based classification fails when furniture touches walls (which surface is wall vs. object?). Distance-based classification handles this because the wall is always farther from center than the furniture.
- BOUNDARY OVERRIDE: Manual boundary drawing fixes cases where auto-detection fails (e.g., large windows where the farthest points are reflections outside the room).

### 4.6 Construction Layer

**Why separate from Guide Lines?**
- Guide lines = final geometry (walls, boundaries, annotations)
- Construction lines = temporary working geometry (reference lines, initial traces, build output)
- Like CAD: construction geometry helps you draw but isn't part of the final output
- Edit tools (trim, extend) work across both layers — you can extend a guide line to meet a construction line

### 4.7 Draw Plane Lock

**Why lock Y height?**
- In top-down view, click positions project to a plane perpendicular to the camera. Without locking, slight camera tilt means points end up at random Y heights.
- Locking to a specific Y (typically floor height) ensures all drawn geometry is coplanar — critical for wall reconstruction.

### 4.8 Multi-Scan Support

**Why combine scans?**
- Single iPhone scan covers ~5m radius reliably. Larger rooms need multiple scans from different positions.
- Insert + Align + Nudge lets you combine partial scans into a complete room.
- Wall Edge Alignment uses ICP on density ridges to automatically align overlapping scans.

### 4.9 Camera Distance Heatmap

**Why show distance from camera?**
- Points far from the camera have lower accuracy (LiDAR uncertainty grows with distance).
- Visualizing distance reveals which areas need rescanning.
- The distance filter slider hides unreliable distant points before classification.

---

## 5. Design Decisions & Rationale

### 5.1 Why a Web-Based Labeler?

- **Cross-platform**: Works on any device with a browser
- **No installation**: Just navigate to URL
- **Server integration**: Direct load/save to scan server
- **Collaboration**: Multiple people can label different scans simultaneously
- **Three.js**: Handles 100K+ points in real-time with WebGL

### 5.2 Why Single-File HTML?

- **Deployment simplicity**: Upload one file to server, done
- **No build system**: No webpack, no npm, no dependencies to manage
- **Offline capable**: Download the file and open locally
- **Version control**: One file to track, one diff to review

### 5.3 Why JSON for Scan Data (Not PLY/LAS)?

- **Human-readable**: Can inspect with any text editor
- **Flexible schema**: Easy to add new fields (labels, normals, colors, scan IDs)
- **Web-native**: JavaScript parses JSON natively, no binary parsers needed
- **Training-ready**: Python reads JSON directly into NumPy arrays

### 5.4 Why Action Logging?

Traditional ML training uses only **final labeled data**. But the process of labeling contains valuable information:
- "The expert drew a line here first, then extended it" → teaches wall topology strategy
- "The expert painted these points as 'object' after looking from the side view" → teaches viewpoint-dependent recognition
- "The expert trimmed this line after building walls" → teaches iterative refinement
- Notebook entries capture the **reasoning** that no amount of final-state data can provide

### 5.5 Why the Notebook?

Action logs capture WHAT happened. The notebook captures WHY. Together they form a complete training signal:
- `action: extend_both, meeting_point: {x: 1.2, z: -0.4}` — what
- `note: "extending these walls because the scanner missed the corner behind the couch"` — why

This is the difference between:
- Teaching an AI to mimic button clicks (useless)
- Teaching an AI to understand room geometry and make intelligent decisions (valuable)

---

## 6. Workflow Patterns (How Experts Use the System)

### 6.1 Standard Room Labeling Workflow

1. **Load scan** from server (Project > Open from Server)
2. **Switch to Top view** — see room from above
3. **Auto-classify** — let the algorithm do first pass
4. **Draw boundary** — if auto-detection missed the room outline, draw it manually
5. **Fix labels with paint** — correct misclassified regions
6. **Draw guide lines** — trace wall centerlines with polyline tool
7. **Auto-extend** — make all wall lines meet at corners
8. **Build walls** — extrude to 3D wall planes
9. **Annotate** — notebook entries explaining decisions
10. **Save** — project saved with all geometry + action log + notes

### 6.2 Multi-Scan Alignment Workflow

1. **Load primary scan** from server
2. **Insert secondary scan** — appears offset in different color
3. **Switch to By Scan color mode** — distinguish scans visually
4. **Top view** — look down for alignment
5. **Nudge** — arrow keys to manually position, or use Wall Edge Alignment for auto
6. **Verify** — check alignment in perspective view
7. **Classify** — run auto-classify on combined data
8. **Save** — combined scan with alignment preserved

### 6.3 Photogrammetry + LiDAR Workflow

1. **iOS: Scan with LiDAR** — captures geometry
2. **iOS: Auto-capture photos** — captures texture
3. **Both upload automatically** to server
4. **Labeler: Load LiDAR scan** — point cloud appears
5. **Labeler: Toggle photogrammetry layer** — see camera positions
6. **Detect features** — Claude Vision identifies doors/windows in photos
7. **Apply detected features** — update labels for door/window points
8. **Save** — enriched scan with both LiDAR and photo data

---

## 7. Data Format Reference

### 7.1 Point Cloud JSON (Scan File)

```json
{
  "points": [
    {"x": 1.23, "y": 0.01, "z": -2.45, "nx": 0, "ny": 1, "nz": 0, "label": 0, "r": 128, "g": 130, "b": 125}
  ],
  "num_points": 50000,
  "camera_track": [[x, y, z, timestamp], ...],
  "room_planes": [...],
  "guide_lines": [{"type": "polyline", "points": [{x,y,z},...], "closed": false}],
  "construction_lines": [...],
  "guide_markers": [{x,y,z}],
  "action_log": [...],
  "notebook": [...],
  "custom_labels": [{"id": 10, "name": "Pipe"}],
  "saved_at": "2026-03-12T10:30:00Z"
}
```

### 7.2 Label Index Map

| Index | Name | Color | Description |
|-------|------|-------|-------------|
| -1 | Unlabeled | Gray | Not yet classified |
| 0 | Floor | Green | Bottom horizontal surface |
| 1 | Ceiling | Yellow | Top horizontal surface |
| 2 | Wall | Blue | Vertical boundary surfaces |
| 3 | Object | Red | Furniture, interior items |
| 4 | Noise | Purple | Reflections, outliers |
| 5 | Object Top | Light Red | Horizontal surface on objects |
| 6 | Back Reflection | Magenta | Secondary LiDAR returns |
| 7 | Door | Brown | Door openings |
| 8 | Window | Cyan | Window openings |
| 9 | Coving | Orange | Ceiling-wall transition strip |
| 10+ | Custom | Auto HSL | User-defined labels |

### 7.3 Action Log Entry

```json
{
  "t": 1710245400000,
  "dt": "2026-03-12T10:30:00.000Z",
  "session": "m1a2b3c4",
  "action": "extend_both",
  "tool": "extend",
  "camera": {
    "pos": {"x": 0, "y": 5.2, "z": 0},
    "target": {"x": 1.1, "y": 0, "z": -0.8},
    "zoom": 1.0
  },
  "meeting_point": {"x": 1.23, "y": 0, "z": -0.45},
  "line1": {"layer": "guide", "idx": 0},
  "line2": {"layer": "guide", "idx": 1},
  "why": "extending walls to close the corner gap behind the couch"
}
```

### 7.4 Notebook Entry

```json
{
  "id": 1710245400123,
  "t": 1710245400123,
  "dt": "2026-03-12T10:30:00.123Z",
  "tag": "decision",
  "text": "Using orthogonal plane fit here because this wall is clearly axis-aligned despite the noisy points",
  "action_index": 42,
  "last_action": "plane_fit",
  "camera": {"pos": {...}, "target": {...}}
}
```

---

## 8. Architecture: How Everything Connects

```
┌─────────────── iOS App ───────────────────┐
│                                            │
│  ARKit LiDAR → MeshManager                 │
│       ↓                                    │
│  SurfaceClassifier (geometry + ML)         │
│       ↓                                    │
│  TrainingDataExporter → JSON               │
│       ↓                                    │
│  ScanServerManager → POST upload.php       │
│                                            │
│  AutoPhotoCapture → JPEG + depth           │
│       ↓                                    │
│  ScanServerManager → POST upload_photos.php│
└────────────────────────────────────────────┘
              ↓
┌─────────── Server (PHP) ──────────────────┐
│                                            │
│  /scans/{project}/scan_*.json              │
│  /scans/{project}/photos/session_*/        │
│                                            │
│  APIs: upload, list, get, manage           │
│  Auth: session-based for web, API key app  │
│  AI: detect_features.php (Claude Vision)   │
└────────────────────────────────────────────┘
              ↓
┌──── PointCloudLabeler (Browser) ──────────┐
│                                            │
│  Load scan → Three.js 3D render            │
│       ↓                                    │
│  Auto-classify (boundary detection)        │
│       ↓                                    │
│  Manual refinement:                        │
│    Paint/erase labels                      │
│    Draw guide geometry                     │
│    Trim/extend/build walls                 │
│    Fit planes                              │
│       ↓                                    │
│  Action log + notebook (training data)     │
│       ↓                                    │
│  Save → upload.php (refined labels)        │
└────────────────────────────────────────────┘
              ↓
┌───── ML Training Pipeline ────────────────┐
│                                            │
│  Export labeled JSON → Python              │
│  Action log → workflow training            │
│  Notebook → reasoning training             │
│       ↓                                    │
│  Train improved SurfaceClassifier model    │
│       ↓                                    │
│  Deploy CoreML model back to iOS app       │
└────────────────────────────────────────────┘
```

---

## 9. Key URLs & Credentials

| Resource | URL/Value |
|----------|-----------|
| Server | https://scanwizard.robo-wizard.com |
| API Key | ScanWizard2025Secret |
| Admin Email | mberoz61@gmail.com |
| Server Host | 46.202.142.125:65002 |
| SSH User | u429345666 |
| Web Root | /home/u429345666/domains/robo-wizard.com/public_html/scanwizard/ |
| Scans Path | /scans/ (with project subfolders) |
| Max Upload | 128 MB (PHP), 256 MB (.user.ini override) |

---

## 10. Evolution Log — Why Features Were Added

| Feature | Triggered By | Reasoning |
|---------|-------------|-----------|
| Draw Plane Lock | Lines drawing in 3D space when in top view | Snap system was providing 3D positions that bypassed the camera plane projection |
| Construction Layer | Need to separate working geometry from final output | Like CAD: construction lines help but aren't part of the deliverable |
| Two-Click Extend | Original extend only worked on one line | Wall corners need BOTH lines to meet — need to select two lines |
| Auto Extend All | Tedious to extend 20+ lines one pair at a time | Batch operation: extend every endpoint to its nearest neighbor |
| Build Walls (extend+trim) | First version only extended, didn't trim | Real walls need both: short segments extend, long segments get trimmed at intersections |
| Plane Fit (ortho mode) | Walls should snap to axis but free-fit gave tilted planes | Orthogonal mode snaps normal to nearest axis — perfect for architectural geometry |
| Action Logging | Need to teach AI HOW to label, not just the final result | Actions + camera state = complete training signal for workflow AI |
| Notebook | Actions capture WHAT, but not WHY | Human reasoning is the most valuable training signal |
| Density Lines | Manual wall tracing is slow | Auto-detection from point density gives 80% of walls instantly |
| Camera Distance Heatmap | No way to assess scan quality | Distance visualization reveals coverage gaps and low-confidence regions |
| Multi-Scan Nudge | Single scan can't cover large rooms | Arrow key nudging lets users align partial scans precisely |
| Vertex Markers (reduced size) | Markers were "soo huge" | Scale was `camDist * 0.015`, reduced to `0.008` for proportional display |
| Custom SVG Cursors | No visual feedback when edit tools are active | Trim/extend cursor changed to selection crosshair so users know the tool is active |
| Right-click context menu fix | "Finish" button didn't work | `mousedown` dismiss listener fired before `onclick` on menu items — changed to check if click is inside menu |

---

*This document should be updated as new features are added. Each entry should explain not just WHAT was built, but WHY it was needed and what problem it solves.*
