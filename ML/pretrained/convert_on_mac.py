#!/usr/bin/env python3
"""
Convert PyTorch checkpoint to Core ML format.

Run this on macOS (required for coremltools full functionality).

Usage:
    python convert_on_mac.py
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
import numpy as np
import coremltools as ct
from pathlib import Path


class PointNetSegmentation(nn.Module):
    """Simplified PointNet for indoor scene segmentation."""

    def __init__(self, num_classes=4, input_channels=6):
        super().__init__()
        self.num_classes = num_classes

        self.enc1 = nn.Conv1d(input_channels, 64, 1)
        self.enc2 = nn.Conv1d(64, 128, 1)
        self.enc3 = nn.Conv1d(128, 256, 1)
        self.enc4 = nn.Conv1d(256, 512, 1)
        self.enc5 = nn.Conv1d(512, 1024, 1)

        self.dec1 = nn.Conv1d(1024 + 64, 512, 1)
        self.dec2 = nn.Conv1d(512, 256, 1)
        self.dec3 = nn.Conv1d(256, 128, 1)
        self.dec4 = nn.Conv1d(128, num_classes, 1)

    def forward(self, x):
        batch_size = x.size(0)
        num_points = x.size(1)
        x = x.transpose(2, 1)

        x1 = F.relu(self.enc1(x))
        x2 = F.relu(self.enc2(x1))
        x3 = F.relu(self.enc3(x2))
        x4 = F.relu(self.enc4(x3))
        x5 = F.relu(self.enc5(x4))

        global_feat = torch.max(x5, 2, keepdim=True)[0]
        global_feat = global_feat.repeat(1, 1, num_points)

        x = torch.cat([global_feat, x1], dim=1)
        x = F.relu(self.dec1(x))
        x = F.relu(self.dec2(x))
        x = F.relu(self.dec3(x))
        x = self.dec4(x)

        x = x.transpose(2, 1)
        x = F.softmax(x, dim=-1)
        return x


def main():
    checkpoint_path = Path("IndoorSegmentation.pt")

    if not checkpoint_path.exists():
        print(f"Error: {checkpoint_path} not found!")
        print("Run 'python export_model.py' on Windows first.")
        return

    print(f"Loading checkpoint: {checkpoint_path}")
    checkpoint = torch.load(checkpoint_path, map_location="cpu")

    model = PointNetSegmentation(
        num_classes=checkpoint.get("num_classes", 4),
        input_channels=checkpoint.get("input_channels", 6)
    )
    model.load_state_dict(checkpoint["model_state_dict"])
    model.eval()

    print("Tracing model...")
    num_points = 4096
    example_input = torch.randn(1, num_points, 6)
    traced_model = torch.jit.trace(model, example_input)

    print("Converting to Core ML...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.TensorType(
                name="points",
                shape=(1, ct.RangeDim(100, 100000, num_points), 6),
                dtype=np.float32
            )
        ],
        outputs=[
            ct.TensorType(name="classifications", dtype=np.float32)
        ],
        minimum_deployment_target=ct.target.iOS15,
        compute_precision=ct.precision.FLOAT16,
    )

    # Metadata
    mlmodel.author = "LiDAR Scanner"
    mlmodel.short_description = "Indoor scene semantic segmentation"
    mlmodel.version = "1.0"
    mlmodel.input_description["points"] = "Point cloud (N x 6): XYZ + normals"
    mlmodel.output_description["classifications"] = "Per-point probabilities (N x 4)"
    mlmodel.user_defined_metadata["classes"] = "floor,ceiling,wall,object"

    output_path = "IndoorSegmentation.mlpackage"
    mlmodel.save(output_path)
    print(f"\nCore ML model saved: {output_path}")

    print("\nDone! Copy IndoorSegmentation.mlpackage to your Xcode project.")


if __name__ == "__main__":
    main()
