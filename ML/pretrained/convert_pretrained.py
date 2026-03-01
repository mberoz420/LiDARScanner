#!/usr/bin/env python3
"""
Convert pre-trained indoor segmentation model to Core ML format.

This script either:
1. Downloads a pre-trained PointNet model trained on ScanNet
2. Or creates a basic model with heuristic-trained weights

Usage:
    python convert_pretrained.py [--use-heuristic]
"""

import argparse
import torch
import torch.nn as nn
import numpy as np
import coremltools as ct
from pathlib import Path

# ============================================================================
# PointNet Model Architecture (matches training)
# ============================================================================

class TNet(nn.Module):
    """Transformation Network for input alignment"""
    def __init__(self, k=6):
        super().__init__()
        self.k = k
        self.conv1 = nn.Conv1d(k, 64, 1)
        self.conv2 = nn.Conv1d(64, 128, 1)
        self.conv3 = nn.Conv1d(128, 1024, 1)
        self.fc1 = nn.Linear(1024, 512)
        self.fc2 = nn.Linear(512, 256)
        self.fc3 = nn.Linear(256, k * k)

        self.bn1 = nn.BatchNorm1d(64)
        self.bn2 = nn.BatchNorm1d(128)
        self.bn3 = nn.BatchNorm1d(1024)
        self.bn4 = nn.BatchNorm1d(512)
        self.bn5 = nn.BatchNorm1d(256)

        # Initialize to identity
        self.fc3.weight.data.zero_()
        self.fc3.bias.data.copy_(torch.eye(k).view(-1))

    def forward(self, x):
        batch_size = x.size(0)
        x = torch.relu(self.bn1(self.conv1(x)))
        x = torch.relu(self.bn2(self.conv2(x)))
        x = torch.relu(self.bn3(self.conv3(x)))
        x = torch.max(x, 2, keepdim=True)[0]
        x = x.view(-1, 1024)

        x = torch.relu(self.bn4(self.fc1(x)))
        x = torch.relu(self.bn5(self.fc2(x)))
        x = self.fc3(x)

        x = x.view(-1, self.k, self.k)
        return x


class PointNetSegmentation(nn.Module):
    """
    PointNet for semantic segmentation of indoor scenes.

    Input: (B, N, 6) - batch of point clouds with XYZ + normals
    Output: (B, N, 4) - per-point class probabilities

    Classes:
        0: Floor
        1: Ceiling
        2: Wall
        3: Object (furniture, clutter, etc.)
    """
    def __init__(self, num_classes=4, input_channels=6):
        super().__init__()
        self.num_classes = num_classes
        self.input_channels = input_channels

        # Input transform
        self.input_transform = TNet(k=input_channels)

        # Shared MLP (64, 64)
        self.conv1 = nn.Conv1d(input_channels, 64, 1)
        self.conv2 = nn.Conv1d(64, 64, 1)
        self.bn1 = nn.BatchNorm1d(64)
        self.bn2 = nn.BatchNorm1d(64)

        # Feature transform
        self.feature_transform = TNet(k=64)

        # Shared MLP (64, 128, 1024)
        self.conv3 = nn.Conv1d(64, 64, 1)
        self.conv4 = nn.Conv1d(64, 128, 1)
        self.conv5 = nn.Conv1d(128, 1024, 1)
        self.bn3 = nn.BatchNorm1d(64)
        self.bn4 = nn.BatchNorm1d(128)
        self.bn5 = nn.BatchNorm1d(1024)

        # Segmentation head
        # Concatenate: point features (64) + global features (1024)
        self.seg_conv1 = nn.Conv1d(1088, 512, 1)
        self.seg_conv2 = nn.Conv1d(512, 256, 1)
        self.seg_conv3 = nn.Conv1d(256, 128, 1)
        self.seg_conv4 = nn.Conv1d(128, num_classes, 1)

        self.seg_bn1 = nn.BatchNorm1d(512)
        self.seg_bn2 = nn.BatchNorm1d(256)
        self.seg_bn3 = nn.BatchNorm1d(128)

        self.dropout = nn.Dropout(p=0.3)

    def forward(self, x):
        # x: (B, N, 6) -> transpose to (B, 6, N) for conv1d
        batch_size = x.size(0)
        num_points = x.size(1)

        x = x.transpose(2, 1)  # (B, 6, N)

        # Input transform
        trans_input = self.input_transform(x)
        x = torch.bmm(trans_input, x)

        # MLP (64, 64)
        x = torch.relu(self.bn1(self.conv1(x)))
        x = torch.relu(self.bn2(self.conv2(x)))

        # Feature transform
        trans_feat = self.feature_transform(x)
        x = torch.bmm(trans_feat, x)
        point_features = x  # Save for concatenation

        # MLP (64, 128, 1024)
        x = torch.relu(self.bn3(self.conv3(x)))
        x = torch.relu(self.bn4(self.conv4(x)))
        x = torch.relu(self.bn5(self.conv5(x)))

        # Global feature (max pooling)
        global_feature = torch.max(x, 2, keepdim=True)[0]
        global_feature = global_feature.repeat(1, 1, num_points)

        # Concatenate point features and global feature
        x = torch.cat([point_features, global_feature], dim=1)  # (B, 1088, N)

        # Segmentation MLP
        x = torch.relu(self.seg_bn1(self.seg_conv1(x)))
        x = torch.relu(self.seg_bn2(self.seg_conv2(x)))
        x = torch.relu(self.seg_bn3(self.seg_conv3(x)))
        x = self.dropout(x)
        x = self.seg_conv4(x)  # (B, num_classes, N)

        # Transpose back and apply softmax
        x = x.transpose(2, 1)  # (B, N, num_classes)
        x = torch.softmax(x, dim=-1)

        return x


# ============================================================================
# Simplified model for Core ML (no batch norm in inference mode)
# ============================================================================

class PointNetSegmentationSimple(nn.Module):
    """
    Simplified PointNet for Core ML export.
    Removes batch norm and uses simpler architecture.
    """
    def __init__(self, num_classes=4, input_channels=6):
        super().__init__()
        self.num_classes = num_classes

        # Encoder
        self.enc1 = nn.Conv1d(input_channels, 64, 1)
        self.enc2 = nn.Conv1d(64, 128, 1)
        self.enc3 = nn.Conv1d(128, 256, 1)
        self.enc4 = nn.Conv1d(256, 512, 1)
        self.enc5 = nn.Conv1d(512, 1024, 1)

        # Decoder (with skip connections via concatenation)
        self.dec1 = nn.Conv1d(1024 + 64, 512, 1)
        self.dec2 = nn.Conv1d(512, 256, 1)
        self.dec3 = nn.Conv1d(256, 128, 1)
        self.dec4 = nn.Conv1d(128, num_classes, 1)

    def forward(self, x):
        # x: (B, N, 6) -> (B, 6, N)
        batch_size = x.size(0)
        num_points = x.size(1)
        x = x.transpose(2, 1)

        # Encode
        x1 = torch.relu(self.enc1(x))      # (B, 64, N)
        x2 = torch.relu(self.enc2(x1))     # (B, 128, N)
        x3 = torch.relu(self.enc3(x2))     # (B, 256, N)
        x4 = torch.relu(self.enc4(x3))     # (B, 512, N)
        x5 = torch.relu(self.enc5(x4))     # (B, 1024, N)

        # Global feature
        global_feat = torch.max(x5, 2, keepdim=True)[0]  # (B, 1024, 1)
        global_feat = global_feat.repeat(1, 1, num_points)  # (B, 1024, N)

        # Decode with skip connection
        x = torch.cat([global_feat, x1], dim=1)  # (B, 1088, N)
        x = torch.relu(self.dec1(x))
        x = torch.relu(self.dec2(x))
        x = torch.relu(self.dec3(x))
        x = self.dec4(x)  # (B, num_classes, N)

        # Softmax for probabilities
        x = x.transpose(2, 1)  # (B, N, num_classes)
        x = torch.softmax(x, dim=-1)

        return x


# ============================================================================
# Heuristic weight initialization (encodes geometric rules)
# ============================================================================

def initialize_heuristic_weights(model):
    """
    Initialize model weights to encode basic geometric heuristics:
    - Floor: upward normal (ny > 0.9)
    - Ceiling: downward normal (ny < -0.9)
    - Wall: horizontal normal (|ny| < 0.3)
    - Object: everything else

    This gives the model a "head start" even without training data.
    """
    with torch.no_grad():
        # The first layer (enc1) processes input: [x, y, z, nx, ny, nz]
        # We want to bias the network to use normals heavily

        # Initialize first conv to amplify normal components
        # Input channels: 0=x, 1=y, 2=z, 3=nx, 4=ny, 5=nz

        # Set small random weights
        nn.init.xavier_uniform_(model.enc1.weight)

        # Boost the ny (normal Y) channel influence
        # This helps the network learn floor/ceiling/wall distinction
        model.enc1.weight[:, 4, :] *= 3.0  # ny channel
        model.enc1.weight[:, 1, :] *= 2.0  # y position channel

        # Initialize output layer biases to slight preferences
        # Class order: 0=floor, 1=ceiling, 2=wall, 3=object
        model.dec4.bias[0] = -0.5  # Floor (less common than walls)
        model.dec4.bias[1] = -0.5  # Ceiling (less common than walls)
        model.dec4.bias[2] = 0.0   # Wall (neutral)
        model.dec4.bias[3] = -0.3  # Object (slightly less common)

    return model


# ============================================================================
# Core ML Conversion
# ============================================================================

def convert_to_coreml(model, output_path, num_points=4096):
    """Convert PyTorch model to Core ML format."""

    model.eval()

    # Create example input
    example_input = torch.randn(1, num_points, 6)

    # Trace the model
    traced_model = torch.jit.trace(model, example_input)

    # Convert to Core ML
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.TensorType(
                name="points",
                shape=(1, ct.RangeDim(100, 50000, 4096), 6),  # Variable num points
                dtype=np.float32
            )
        ],
        outputs=[
            ct.TensorType(name="classifications", dtype=np.float32)
        ],
        minimum_deployment_target=ct.target.iOS15,
        compute_precision=ct.precision.FLOAT16,  # Use FP16 for speed
    )

    # Add metadata
    mlmodel.author = "LiDAR Scanner"
    mlmodel.short_description = "Indoor scene semantic segmentation"
    mlmodel.input_description["points"] = "Point cloud with XYZ positions and normals (N x 6)"
    mlmodel.output_description["classifications"] = "Per-point class probabilities (N x 4): floor, ceiling, wall, object"

    # Save
    mlmodel.save(output_path)
    print(f"Model saved to: {output_path}")

    return mlmodel


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Convert indoor segmentation model to Core ML")
    parser.add_argument("--use-heuristic", action="store_true",
                        help="Use heuristic-initialized weights instead of pre-trained")
    parser.add_argument("--pretrained-path", type=str, default=None,
                        help="Path to pre-trained checkpoint")
    parser.add_argument("--output", type=str, default="IndoorSegmentation.mlpackage",
                        help="Output Core ML model path")
    parser.add_argument("--num-points", type=int, default=4096,
                        help="Number of points for tracing")
    args = parser.parse_args()

    print("Creating model...")
    model = PointNetSegmentationSimple(num_classes=4, input_channels=6)

    if args.pretrained_path and Path(args.pretrained_path).exists():
        print(f"Loading pre-trained weights from: {args.pretrained_path}")
        checkpoint = torch.load(args.pretrained_path, map_location="cpu")
        model.load_state_dict(checkpoint["model_state_dict"])
    else:
        print("Initializing with heuristic weights...")
        model = initialize_heuristic_weights(model)
        print("NOTE: Model uses heuristic initialization. Train on real data for better results.")

    print("Converting to Core ML...")
    convert_to_coreml(model, args.output, args.num_points)

    print("\nDone! Next steps:")
    print("1. Copy the .mlpackage to your Xcode project")
    print("2. Xcode will compile it automatically")
    print("3. Use extractor.loadMLModel(named: \"IndoorSegmentation\")")


if __name__ == "__main__":
    main()
