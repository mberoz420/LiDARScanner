# Quick Reference Card

## File Locations

| What | Where |
|------|-------|
| Training notebook | `ML/training/Train_IndoorSegmentation.ipynb` |
| PyTorch model | `ML/pretrained/IndoorSegmentation.pt` |
| Core ML model | `LiDARScanner/ML/IndoorSegmentation.mlpackage` |
| Conversion script | `ML/pretrained/convert_on_mac.py` |
| Training data (on iPhone) | `Documents/TrainingData/*.json` |

---

## Annotation Workflow

```
1. Scan a room (Walls & Rooms mode)
2. Stop → Save
3. Saved Sessions → Select scan
4. "Annotate for Training" (orange button)
5. Tap meshes to label (Floor/Ceiling/Wall/Object)
6. Export → JSON saved to TrainingData folder
7. Repeat for 10+ rooms
```

---

## Training Workflow

```
1. Copy JSONs from iPhone to computer
2. Open Google Colab
3. Upload Train_IndoorSegmentation.ipynb
4. Upload your JSON files
5. Run all cells
6. Download IndoorSegmentation.mlpackage
7. Add to Xcode project
```

---

## Label Colors

| Color | Label | Typical surfaces |
|-------|-------|------------------|
| Green | Floor | Ground, rugs, mats |
| Yellow | Ceiling | Top of room, light fixtures |
| Blue | Wall | Room boundaries, doors, windows |
| Red | Object | Furniture, clutter, people |

---

## ML Badge Status

| What you see | Meaning |
|--------------|---------|
| Purple "ML" badge | Model loaded, AI-enhanced detection |
| No badge | Geometric heuristics only |

---

## Keyboard Shortcuts (Colab)

| Keys | Action |
|------|--------|
| Shift+Enter | Run cell and move to next |
| Ctrl+Enter | Run cell and stay |
| Ctrl+M B | Insert cell below |
| Ctrl+M D | Delete cell |

---

## Common Issues

| Problem | Solution |
|---------|----------|
| ML badge not showing | Add .mlpackage to Xcode project |
| Training data not found | Make sure you tapped "Export" |
| Low accuracy | Need more training data (10+ rooms) |
| Model file too large | Use FLOAT16 precision (already set) |

---

## Model Classes

```python
0 = Floor    # Ground surfaces
1 = Ceiling  # Top surfaces
2 = Wall     # Vertical room boundaries
3 = Object   # Everything else (furniture, etc.)
```

---

## Useful Commands

**Check PyTorch model:**
```python
import torch
checkpoint = torch.load("IndoorSegmentation.pt")
print(checkpoint.keys())
```

**Test model:**
```python
model.eval()
with torch.no_grad():
    output = model(test_points)
    predictions = output.argmax(dim=-1)
```

**Convert to Core ML:**
```bash
cd ML/pretrained
python3 convert_on_mac.py
```
