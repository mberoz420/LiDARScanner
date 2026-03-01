# How the Neural Network Works

## The Big Picture

```
  Your Room Scan              Neural Network              Classification
  ─────────────              ──────────────              ──────────────

  ┌─────────────┐           ┌──────────────┐           ┌─────────────┐
  │ • • • • • • │           │              │           │ Floor: 32%  │
  │ • • • • • • │    ───►   │   PointNet   │    ───►   │ Ceiling: 5% │
  │ • • • • • • │           │              │           │ Wall: 61%   │
  │ 4096 points │           │              │           │ Object: 2%  │
  └─────────────┘           └──────────────┘           └─────────────┘
                                                         ↓
                                                       WALL ✓
```

## What Goes In (Input)

Each point has **6 numbers**:

```
Point = [X, Y, Z, NX, NY, NZ]
         ─────────  ─────────
         Position   Normal Direction
```

| Value | What it means |
|-------|---------------|
| X | Left-right position (meters) |
| Y | Up-down position (meters) |
| Z | Forward-back position (meters) |
| NX | Normal X (which way surface faces) |
| NY | Normal Y (up=1, down=-1) |
| NZ | Normal Z |

**Example points:**
```
Floor point:   [1.2, 0.0, 3.4, 0.0, 1.0, 0.0]  ← Y=0 (ground), NY=1 (faces up)
Ceiling point: [1.2, 2.5, 3.4, 0.0, -1.0, 0.0] ← Y=2.5 (high), NY=-1 (faces down)
Wall point:    [0.0, 1.2, 3.4, 1.0, 0.0, 0.0]  ← X=0 (edge), NX=1 (faces right)
```

## What Comes Out (Output)

**4 probabilities** for each point:

```
[0.02, 0.05, 0.91, 0.02]
  │     │     │     │
  │     │     │     └── Object: 2%
  │     │     └──────── Wall: 91%  ← Winner!
  │     └────────────── Ceiling: 5%
  └──────────────────── Floor: 2%
```

The highest probability wins.

---

## Inside the Neural Network

### Architecture: PointNet

```
INPUT                          ENCODER                         GLOBAL FEATURE
[4096 × 6]                    (learns local patterns)          (room-level info)
    │                               │                               │
    │   ┌─────────────────────────────────────────────────┐        │
    │   │                                                 │        │
    ▼   ▼                                                 ▼        ▼
┌───────────┐   ┌───────────┐   ┌───────────┐   ┌───────────┐   ┌─────┐
│ 6 → 64    │──►│ 64 → 128  │──►│ 128 → 256 │──►│ 256 → 512 │──►│ MAX │
│  Conv1D   │   │  Conv1D   │   │  Conv1D   │   │  Conv1D   │   │POOL │
└───────────┘   └───────────┘   └───────────┘   └───────────┘   └─────┘
                                                                    │
                    ┌───────────────────────────────────────────────┘
                    │ Copy to all 4096 points
                    ▼
              ┌───────────┐   ┌───────────┐   ┌───────────┐   ┌───────────┐
              │1088 → 512 │──►│ 512 → 256 │──►│ 256 → 128 │──►│ 128 → 4   │
              │  Conv1D   │   │  Conv1D   │   │  Conv1D   │   │  Conv1D   │
              └───────────┘   └───────────┘   └───────────┘   └───────────┘
                    │                                               │
                DECODER                                         OUTPUT
              (combines local + global)                      [4096 × 4]
```

### What Each Part Does

| Part | Purpose | Example |
|------|---------|---------|
| **Encoder** | Finds local patterns | "This point has upward normal" |
| **Max Pool** | Captures global context | "The room is 2.5m tall" |
| **Decoder** | Combines both | "Upward normal + at floor height = Floor" |

---

## How It Learns

### Training Process

```
                    ┌─────────────────┐
                    │  Your Labels    │
                    │  (Ground Truth) │
                    └────────┬────────┘
                             │
    ┌────────────────────────┼────────────────────────┐
    │                        │                        │
    │    ┌───────────┐       │       ┌───────────┐   │
    │    │           │       ▼       │           │   │
    │    │  Points   │──►[Network]──►│Predictions│   │
    │    │           │               │           │   │
    │    └───────────┘               └─────┬─────┘   │
    │                                      │         │
    │                    ┌─────────────────┘         │
    │                    │                           │
    │                    ▼                           │
    │              ┌───────────┐                     │
    │              │   Loss    │ ← How wrong?        │
    │              │ Function  │                     │
    │              └─────┬─────┘                     │
    │                    │                           │
    │                    ▼                           │
    │              ┌───────────┐                     │
    │              │  Update   │ ← Fix weights       │
    │              │  Weights  │                     │
    │              └───────────┘                     │
    │                                                │
    └────────────────────────────────────────────────┘
                         │
                         │ Repeat 1000s of times
                         ▼
                    Model gets better!
```

### Key Concepts

| Term | Meaning |
|------|---------|
| **Epoch** | One pass through all training data |
| **Loss** | How wrong the predictions are (lower = better) |
| **Learning Rate** | How big the correction steps are |
| **Batch** | Group of samples processed together |
| **Validation** | Test data not used for training (checks overfitting) |

---

## Why This Architecture?

### Problem: Point clouds are unordered

Unlike images (pixels in grid), points have no order:
```
[A, B, C, D] = [B, D, A, C] = [C, A, D, B]
```

### Solution: PointNet uses Max Pooling

```
Points:     [5, 3, 8, 2, 7]
             │  │  │  │  │
Max Pool:    └──┴──┴──┴──┘
                   │
                   ▼
                   8   ← Takes the maximum

Order doesn't matter! Same result regardless of point order.
```

---

## What Each Layer Learns

### Early Layers (Low-level features)
```
"Is this point facing up?"
"Is this point near the ground?"
"Is this surface flat?"
```

### Middle Layers (Mid-level features)
```
"Is this a horizontal surface at floor height?"
"Is this a vertical surface spanning floor to ceiling?"
"Is this an isolated object?"
```

### Final Layers (High-level decisions)
```
"Horizontal + ground level + large area = FLOOR"
"Vertical + full height + room edge = WALL"
"Floating + small + complex shape = OBJECT"
```

---

## Improving the Model

### More Data Helps
```
5 rooms   → 70% accuracy
10 rooms  → 80% accuracy
20 rooms  → 85% accuracy
50 rooms  → 90%+ accuracy
```

### Variety Helps
```
✓ Different room sizes
✓ Different furniture
✓ Different lighting
✓ Different wall colors
✓ Messy rooms too!
```

### Correct Labels Help
```
Wrong: Labeling a bookshelf as "Wall"
Right: Labeling a bookshelf as "Object"

The model learns from YOUR labels - garbage in, garbage out!
```

---

## Numbers at Each Stage

For a typical scan with 4096 points:

| Stage | Shape | Parameters |
|-------|-------|------------|
| Input | 4096 × 6 | 0 |
| After enc1 | 4096 × 64 | 448 |
| After enc2 | 4096 × 128 | 8,320 |
| After enc3 | 4096 × 256 | 33,024 |
| After enc4 | 4096 × 512 | 131,584 |
| After enc5 | 4096 × 1024 | 525,312 |
| Global feature | 1 × 1024 | 0 |
| After concat | 4096 × 1088 | 0 |
| After dec1 | 4096 × 512 | 557,568 |
| After dec2 | 4096 × 256 | 131,328 |
| After dec3 | 4096 × 128 | 32,896 |
| Output | 4096 × 4 | 516 |
| **Total** | | **~1.4M parameters** |

That's 1.4 million numbers the network adjusts during training!
