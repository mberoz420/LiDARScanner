# Indoor Scene Segmentation ML Models

This folder contains scripts for training and converting Core ML models for architectural element extraction.

## Quick Start: Pre-trained Model

1. Install dependencies:
```bash
pip install torch torchvision coremltools numpy onnx onnx-simplifier
```

2. Run the conversion script:
```bash
cd pretrained
python convert_pretrained.py
```

3. Copy the generated `IndoorSegmentation.mlpackage` to your Xcode project.

## Custom Training

For better results tailored to your scanning style:

1. Download ScanNet dataset (requires academic agreement):
   - Visit: http://www.scan-net.org/
   - Request access for research use

2. Install training dependencies:
```bash
pip install torch torchvision pytorch-lightning wandb open3d
```

3. Run training:
```bash
cd training
python train_pointnet.py --data_path /path/to/scannet --epochs 100
```

4. Export to Core ML:
```bash
python export_coreml.py --checkpoint best_model.ckpt
```

## Model Architecture

We use PointNet for its simplicity and mobile compatibility:

- **Input**: N x 6 (x, y, z, nx, ny, nz) - points with normals
- **Output**: N x 4 (floor, ceiling, wall, object probabilities)

## Integration

After generating the `.mlpackage`:

1. Drag into Xcode project
2. The `ArchitecturalExtractor` will automatically use it:
```swift
extractor.loadMLModel(named: "IndoorSegmentation")
```
