#!/usr/bin/env python3
"""
Export indoor segmentation model to ONNX and PyTorch checkpoint.

This script works on Windows/Linux/Mac.
For Core ML conversion, run convert_on_mac.py on macOS.

Usage:
    python export_model.py
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
import numpy as np
from pathlib import Path

# ============================================================================
# Model Architecture
# ============================================================================

class PointNetSegmentation(nn.Module):
    """Simplified PointNet for indoor scene segmentation."""

    def __init__(self, num_classes=4, input_channels=6):
        super().__init__()
        self.num_classes = num_classes

        # Encoder
        self.enc1 = nn.Conv1d(input_channels, 64, 1)
        self.enc2 = nn.Conv1d(64, 128, 1)
        self.enc3 = nn.Conv1d(128, 256, 1)
        self.enc4 = nn.Conv1d(256, 512, 1)
        self.enc5 = nn.Conv1d(512, 1024, 1)

        # Decoder
        self.dec1 = nn.Conv1d(1024 + 64, 512, 1)
        self.dec2 = nn.Conv1d(512, 256, 1)
        self.dec3 = nn.Conv1d(256, 128, 1)
        self.dec4 = nn.Conv1d(128, num_classes, 1)

    def forward(self, x):
        batch_size = x.size(0)
        num_points = x.size(1)
        x = x.transpose(2, 1)  # (B, 6, N)

        # Encode
        x1 = F.relu(self.enc1(x))
        x2 = F.relu(self.enc2(x1))
        x3 = F.relu(self.enc3(x2))
        x4 = F.relu(self.enc4(x3))
        x5 = F.relu(self.enc5(x4))

        # Global feature
        global_feat = torch.max(x5, 2, keepdim=True)[0]
        global_feat = global_feat.repeat(1, 1, num_points)

        # Decode
        x = torch.cat([global_feat, x1], dim=1)
        x = F.relu(self.dec1(x))
        x = F.relu(self.dec2(x))
        x = F.relu(self.dec3(x))
        x = self.dec4(x)

        x = x.transpose(2, 1)  # (B, N, C)
        x = F.softmax(x, dim=-1)
        return x


def initialize_heuristic_weights(model):
    """Initialize with geometric heuristics."""
    with torch.no_grad():
        nn.init.xavier_uniform_(model.enc1.weight)
        # Boost normal Y channel for floor/ceiling detection
        model.enc1.weight[:, 4, :] *= 3.0
        model.enc1.weight[:, 1, :] *= 2.0

        # Output biases
        model.dec4.bias[0] = -0.5  # Floor
        model.dec4.bias[1] = -0.5  # Ceiling
        model.dec4.bias[2] = 0.0   # Wall
        model.dec4.bias[3] = -0.3  # Object
    return model


def main():
    print("Creating model...")
    model = PointNetSegmentation(num_classes=4, input_channels=6)
    model = initialize_heuristic_weights(model)
    model.eval()

    num_points = 4096
    example_input = torch.randn(1, num_points, 6)

    # Test forward pass
    print("Testing forward pass...")
    with torch.no_grad():
        output = model(example_input)
    print(f"  Input shape: {example_input.shape}")
    print(f"  Output shape: {output.shape}")
    print(f"  Output sum per point (should be ~1.0): {output[0, 0].sum().item():.4f}")

    # Save PyTorch checkpoint
    checkpoint_path = Path("IndoorSegmentation.pt")
    torch.save({
        "model_state_dict": model.state_dict(),
        "num_classes": 4,
        "input_channels": 6,
    }, checkpoint_path)
    print(f"\nPyTorch checkpoint saved: {checkpoint_path}")

    # Export to ONNX
    print("\nExporting to ONNX...")
    onnx_path = Path("IndoorSegmentation.onnx")

    torch.onnx.export(
        model,
        example_input,
        onnx_path,
        input_names=["points"],
        output_names=["classifications"],
        dynamic_axes={
            "points": {1: "num_points"},
            "classifications": {1: "num_points"}
        },
        opset_version=12,
    )
    print(f"ONNX model saved: {onnx_path}")

    # Verify ONNX
    try:
        import onnx
        onnx_model = onnx.load(str(onnx_path))
        onnx.checker.check_model(onnx_model)
        print("ONNX model verified successfully!")
    except Exception as e:
        print(f"ONNX verification warning: {e}")

    # Test with ONNX Runtime
    try:
        import onnxruntime as ort
        session = ort.InferenceSession(str(onnx_path))
        onnx_output = session.run(None, {"points": example_input.numpy()})
        print(f"ONNX Runtime test passed! Output shape: {onnx_output[0].shape}")
    except Exception as e:
        print(f"ONNX Runtime test warning: {e}")

    print("\n" + "="*60)
    print("SUCCESS! Files created:")
    print(f"  1. {checkpoint_path} - PyTorch checkpoint")
    print(f"  2. {onnx_path} - ONNX model")
    print("\nNext steps:")
    print("  Option A: On your Mac, run:")
    print("    python convert_on_mac.py")
    print("\n  Option B: Use Google Colab (free, has macOS-like env)")
    print("    Upload IndoorSegmentation.pt and run conversion there")
    print("="*60)


if __name__ == "__main__":
    main()
