# ML Training Guide for LiDAR Scanner

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        YOUR WORKFLOW                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  BEFORE          DURING              AFTER                      │
│  ───────         ──────              ─────                      │
│                                                                 │
│  (nothing       ML badge shows      1. Save scan                │
│   needed)       if model loaded     2. Annotate for Training    │
│                                     3. Export training data     │
│                                     4. Train in Colab           │
│                                     5. Add new model to app     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## BEFORE Scanning

**Nothing special required.** Just:
1. Open the app
2. Select **"Walls & Rooms"** mode
3. The app will automatically try to load the ML model

---

## DURING Scanning (Walls & Rooms Mode)

### What You'll See

```
┌─────────────────────────────────────────┐
│  ┌──────────────────────────────────┐   │
│  │                                  │   │
│  │         AR Camera View           │   │
│  │      (colored mesh overlay)      │   │
│  │                                  │   │
│  │   Green = Floor                  │   │
│  │   Yellow = Ceiling               │   │
│  │   Blue = Wall                    │   │
│  │   Red = Object                   │   │
│  │                                  │   │
│  └──────────────────────────────────┘   │
│                                         │
│  ┌──────────────────────────────────┐   │
│  │ ◯ Scan Floor    [ML] ←── Purple  │   │
│  │ "Point at floor"        badge!   │   │
│  └──────────────────────────────────┘   │
│                                         │
│       [ Settings ]  [ STOP ]  [ Camera ]│
└─────────────────────────────────────────┘
```

### The Purple "ML" Badge

| Badge Status | Meaning |
|--------------|---------|
| **ML** badge visible | Core ML model is loaded and enhancing detection |
| No badge | Using geometric heuristics only (still works fine) |

### How ML Enhances Scanning

**Without ML (geometric only):**
- Floor = surfaces with upward normals
- Ceiling = surfaces with downward normals
- Wall = vertical surfaces
- Sometimes misclassifies complex shapes

**With ML:**
- Learns patterns from training data
- Better at distinguishing furniture from walls
- Handles edge cases better
- Combines with geometric rules for best accuracy

---

## AFTER Scanning

### Step 1: Save Your Scan

```
Tap STOP → Scan is auto-saved
```

### Step 2: Open Saved Sessions

```
Home → Saved Sessions → Select your scan
```

### Step 3: Choose Your Action

You'll see these buttons:

| Button | Color | Purpose |
|--------|-------|---------|
| **Continue Scanning** | Green | Add more to this scan |
| **Extract Architecture** | Purple | AI separates walls from furniture |
| **Annotate for Training** | Orange | Label data to train the model |
| **Export** | Blue | Export as OBJ/USDZ/PLY |

---

## Using "Annotate for Training"

### The Annotation Screen

```
┌─────────────────────────────────────────┐
│  ← Cancel          Annotate Scan        │
├─────────────────────────────────────────┤
│                                         │
│     ┌───────────────────────────┐       │
│     │                           │       │
│     │    3D Preview of Scan     │       │
│     │                           │       │
│     │   Tap meshes to label     │       │
│     │                           │       │
│     └───────────────────────────┘       │
│                                         │
│  Labeled: 45/120 meshes                 │
│  Green:12  Yellow:8  Blue:20  Red:5     │
│                                         │
│  ┌──────┬──────┬──────┬──────┐         │
│  │      │      │      │      │         │
│  │Floor │Ceil  │Wall  │Object│         │
│  └──────┴──────┴──────┴──────┘         │
│         ↑ Current tool                  │
│                                         │
│  [Auto-Label All]  [Clear]   [Export]   │
└─────────────────────────────────────────┘
```

### How to Annotate

1. **Select a label tool** (Floor/Ceiling/Wall/Object)
2. **Tap meshes** in the 3D view to apply that label
3. Colors show current labels:
   - Green = Floor
   - Yellow = Ceiling
   - Blue = Wall
   - Red = Object

### Quick Actions

| Button | What it does |
|--------|--------------|
| **Auto-Label All** | Uses geometric rules to label everything automatically |
| **Clear** | Remove all labels, start fresh |
| **Export** | Save labeled data as JSON for training |

### Tips for Good Training Data

```
DO:
✓ Label at least 5-10 different rooms
✓ Include variety (different room sizes, furniture)
✓ Correct auto-label mistakes manually
✓ Make sure edges between surfaces are labeled correctly

DON'T:
✗ Label everything as one type
✗ Skip rooms that look "messy"
✗ Ignore furniture (label it as Object)
```

---

## Training Your Model (Google Colab)

### Step 1: Get Your Training Files

Training data is saved to: `Documents/TrainingData/*.json`

**To access on Mac:**
- Connect iPhone to Mac
- Open Finder → iPhone → Files → LiDAR Scanner → TrainingData
- Copy all `.json` files to your computer

**To access on Windows:**
- Connect iPhone to PC
- Open iTunes or File Explorer
- Navigate to Apps → LiDAR Scanner → Documents → TrainingData
- Copy all `.json` files

### Step 2: Open the Training Notebook

1. Go to: https://colab.research.google.com
2. File → Upload notebook
3. Upload: `ML/training/Train_IndoorSegmentation.ipynb`

### Step 3: Run Training

```python
# Cell 1: Install dependencies
!pip install torch numpy matplotlib tqdm

# Cell 2: Upload your JSON files
# (Click "Upload" button that appears)

# Cell 3-7: Training runs automatically
# Takes ~10-30 minutes depending on data size

# Cell 8: Download trained model
# You'll get: IndoorSegmentation.mlpackage
```

### What the Training Does

1. **Loads your labeled data** - Points with floor/ceiling/wall/object labels
2. **Augments data** - Rotates, scales, adds noise for variety
3. **Trains PointNet** - Neural network learns to classify points
4. **Validates** - Tests on held-out data to check accuracy
5. **Exports** - Converts to Core ML format for iPhone

### Step 4: Add Model to App

**Option A: Manual (for testing)**
1. Download `IndoorSegmentation.mlpackage` from Colab
2. Drag into Xcode project under `LiDARScanner/ML/`
3. Build and run on your device

**Option B: Via Codemagic (for production)**
1. Commit `IndoorSegmentation.pt` to `ML/pretrained/`
2. Push to GitHub
3. Codemagic auto-converts to Core ML during build

---

## Complete Workflow Example

```
Week 1: Collect Data
├── Monday:    Scan living room, annotate
├── Tuesday:   Scan bedroom, annotate
├── Wednesday: Scan kitchen, annotate
├── Thursday:  Scan office, annotate
└── Friday:    Scan bathroom, annotate

Week 2: Train & Deploy
├── Export all training JSONs from iPhone
├── Upload to Google Colab
├── Train model (~30 min)
├── Download .mlpackage
└── Add to Xcode project

Week 3+: Use Improved Model
├── Scan new rooms
├── ML badge shows model is active
├── Better wall/floor/ceiling detection
└── Repeat: annotate mistakes → retrain
```

---

## Quick Reference

| Task | Where | How |
|------|-------|-----|
| See if ML is active | During scan | Look for purple "ML" badge |
| Label training data | Saved Sessions → Annotate | Tap meshes with label tools |
| Export training data | Annotation view → Export | Creates JSON in Documents |
| Train new model | Google Colab | Upload JSONs, run notebook |
| Use new model | Add .mlpackage to Xcode | Rebuild app |

---

## Troubleshooting

### ML badge not showing?
- Model file might not be in the app bundle
- Check `LiDARScanner/ML/IndoorSegmentation.mlpackage` exists in Xcode

### Training accuracy is low?
- Need more training data (aim for 10+ rooms)
- Make sure labels are correct (check auto-label results)
- Try training for more epochs (increase from 50 to 100)

### Can't find training data on iPhone?
- Make sure you tapped "Export" in the Annotation view
- Check Files app → On My iPhone → LiDAR Scanner → TrainingData

### Model not improving wall detection?
- Include more wall examples in training
- Make sure walls are labeled correctly (not as objects)
- Include rooms with different wall colors/textures
