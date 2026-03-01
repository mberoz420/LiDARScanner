#!/usr/bin/env python3
"""
Export trained PointNet model to Core ML format.

Usage:
    python export_coreml.py --checkpoint checkpoints/best_model.ckpt
"""

import argparse
import torch
import torch.nn as nn
import torch.nn.functional as F
import numpy as np
import coremltools as ct
from pathlib import Path


class PointNetSegmentationExport(nn.Module):
    """
    PointNet for export to Core ML.
    Simplified version without batch norm (uses running stats).
    """

    def __init__(self, num_classes=4, input_channels=6):
        super().__init__()
        self.num_classes = num_classes

        # Encoder (no batch norm for simpler export)
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
        x = x.transpose(2, 1)

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

        # Output probabilities
        x = x.transpose(2, 1)
        x = F.softmax(x, dim=-1)

        return x


def fuse_batch_norm(conv, bn):
    """Fuse batch normalization into convolution weights."""
    # Get batch norm parameters
    gamma = bn.weight.data
    beta = bn.bias.data
    mean = bn.running_mean
    var = bn.running_var
    eps = bn.eps

    # Fuse into conv
    std = torch.sqrt(var + eps)
    scale = gamma / std

    # Update conv weights and bias
    conv.weight.data = conv.weight.data * scale.view(-1, 1, 1)
    if conv.bias is not None:
        conv.bias.data = (conv.bias.data - mean) * scale + beta
    else:
        conv.bias = nn.Parameter((- mean) * scale + beta)

    return conv


def convert_checkpoint(checkpoint_path, output_path, num_points=4096):
    """Convert trained checkpoint to Core ML."""

    print(f"Loading checkpoint: {checkpoint_path}")
    checkpoint = torch.load(checkpoint_path, map_location="cpu")

    # Load into training model to get batch norm stats
    from train_pointnet import PointNetSegmentation
    train_model = PointNetSegmentation(num_classes=4)
    train_model.load_state_dict(checkpoint["model_state_dict"])
    train_model.eval()

    # Create export model
    export_model = PointNetSegmentationExport(num_classes=4)

    # Copy weights and fuse batch norm
    with torch.no_grad():
        # Encoder
        export_model.enc1 = fuse_batch_norm(train_model.enc1, train_model.bn1)
        export_model.enc2 = fuse_batch_norm(train_model.enc2, train_model.bn2)
        export_model.enc3 = fuse_batch_norm(train_model.enc3, train_model.bn3)
        export_model.enc4 = fuse_batch_norm(train_model.enc4, train_model.bn4)
        export_model.enc5 = fuse_batch_norm(train_model.enc5, train_model.bn5)

        # Decoder
        export_model.dec1 = fuse_batch_norm(train_model.dec1, train_model.dec_bn1)
        export_model.dec2 = fuse_batch_norm(train_model.dec2, train_model.dec_bn2)
        export_model.dec3 = fuse_batch_norm(train_model.dec3, train_model.dec_bn3)
        export_model.dec4.weight.copy_(train_model.dec4.weight)
        export_model.dec4.bias.copy_(train_model.dec4.bias)

    export_model.eval()

    # Verify outputs match
    print("Verifying model outputs...")
    test_input = torch.randn(1, num_points, 6)
    train_out = F.softmax(train_model(test_input), dim=-1)
    export_out = export_model(test_input)
    diff = (train_out - export_out).abs().max().item()
    print(f"  Max output difference: {diff:.6f}")

    if diff > 0.01:
        print("  WARNING: Large difference detected. Check batch norm fusion.")

    # Trace model
    print("Tracing model...")
    traced = torch.jit.trace(export_model, test_input)

    # Convert to Core ML
    print("Converting to Core ML...")
    mlmodel = ct.convert(
        traced,
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
    mlmodel.short_description = "Indoor scene semantic segmentation (trained on ScanNet)"
    mlmodel.version = "1.0"
    mlmodel.input_description["points"] = "Point cloud (N x 6): XYZ position + XYZ normal"
    mlmodel.output_description["classifications"] = "Per-point probabilities (N x 4): floor, ceiling, wall, object"

    # Class labels
    mlmodel.user_defined_metadata["classes"] = "floor,ceiling,wall,object"

    # Save
    mlmodel.save(output_path)
    print(f"\nModel saved to: {output_path}")

    # Print model info
    spec = mlmodel.get_spec()
    print(f"\nModel info:")
    print(f"  Input: {spec.description.input[0].name}")
    print(f"  Output: {spec.description.output[0].name}")

    return mlmodel


def main():
    parser = argparse.ArgumentParser(description="Export trained model to Core ML")
    parser.add_argument("--checkpoint", type=str, required=True, help="Path to checkpoint")
    parser.add_argument("--output", type=str, default="IndoorSegmentation.mlpackage", help="Output path")
    parser.add_argument("--num_points", type=int, default=4096, help="Number of points for tracing")
    args = parser.parse_args()

    convert_checkpoint(args.checkpoint, args.output, args.num_points)

    print("\nDone! Next steps:")
    print("1. Drag the .mlpackage into your Xcode project")
    print("2. Call extractor.loadMLModel(named: \"IndoorSegmentation\")")


if __name__ == "__main__":
    main()
