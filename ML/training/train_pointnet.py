#!/usr/bin/env python3
"""
Train PointNet for indoor scene semantic segmentation.

Supports:
- ScanNet dataset (automatic download with academic agreement)
- Custom labeled data from your app

Usage:
    python train_pointnet.py --data_path /path/to/scannet --epochs 100

For custom data:
    python train_pointnet.py --data_path /path/to/custom --custom_format
"""

import argparse
import json
import os
from pathlib import Path
from datetime import datetime

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
import torch.nn.functional as F

# Try to import optional dependencies
try:
    import pytorch_lightning as pl
    from pytorch_lightning.callbacks import ModelCheckpoint, EarlyStopping
    from pytorch_lightning.loggers import WandbLogger
    HAS_LIGHTNING = True
except ImportError:
    HAS_LIGHTNING = False
    print("PyTorch Lightning not found. Using basic training loop.")

try:
    import wandb
    HAS_WANDB = True
except ImportError:
    HAS_WANDB = False


# ============================================================================
# Dataset Classes
# ============================================================================

class ScanNetDataset(Dataset):
    """
    ScanNet dataset for indoor scene segmentation.

    Expected structure:
    data_path/
        scans/
            scene0000_00/
                scene0000_00_vh_clean_2.ply  (mesh)
                scene0000_00_vh_clean_2.labels.ply  (labels)
            ...
    """

    # ScanNet label mapping to our 4 classes
    LABEL_MAP = {
        1: 2,   # wall -> wall
        2: 0,   # floor -> floor
        22: 1,  # ceiling -> ceiling
        # Everything else -> object (3)
    }

    def __init__(self, data_path, split="train", num_points=4096, augment=True):
        self.data_path = Path(data_path)
        self.num_points = num_points
        self.augment = augment and split == "train"

        # Load scene list
        split_file = self.data_path / f"scannetv2_{split}.txt"
        if split_file.exists():
            with open(split_file) as f:
                self.scenes = [line.strip() for line in f.readlines()]
        else:
            # Use all scenes if no split file
            scans_dir = self.data_path / "scans"
            if scans_dir.exists():
                self.scenes = [d.name for d in scans_dir.iterdir() if d.is_dir()]
            else:
                self.scenes = []

        print(f"Loaded {len(self.scenes)} scenes for {split}")

    def __len__(self):
        return len(self.scenes)

    def __getitem__(self, idx):
        scene_name = self.scenes[idx]
        scene_path = self.data_path / "scans" / scene_name

        # Load point cloud and labels
        points, labels = self._load_scene(scene_path, scene_name)

        # Sample points
        if len(points) > self.num_points:
            indices = np.random.choice(len(points), self.num_points, replace=False)
        else:
            indices = np.random.choice(len(points), self.num_points, replace=True)

        points = points[indices]
        labels = labels[indices]

        # Augmentation
        if self.augment:
            points = self._augment(points)

        # Normalize point positions to unit sphere
        centroid = np.mean(points[:, :3], axis=0)
        points[:, :3] -= centroid
        scale = np.max(np.linalg.norm(points[:, :3], axis=1))
        if scale > 0:
            points[:, :3] /= scale

        return {
            "points": torch.FloatTensor(points),
            "labels": torch.LongTensor(labels),
            "scene": scene_name
        }

    def _load_scene(self, scene_path, scene_name):
        """Load scene point cloud and labels."""
        try:
            import open3d as o3d

            # Load mesh
            mesh_file = scene_path / f"{scene_name}_vh_clean_2.ply"
            mesh = o3d.io.read_triangle_mesh(str(mesh_file))
            mesh.compute_vertex_normals()

            # Get vertices and normals
            vertices = np.asarray(mesh.vertices)
            normals = np.asarray(mesh.vertex_normals)

            # Stack XYZ + normals
            points = np.hstack([vertices, normals]).astype(np.float32)

            # Load labels
            labels_file = scene_path / f"{scene_name}_vh_clean_2.labels.ply"
            if labels_file.exists():
                labels_mesh = o3d.io.read_point_cloud(str(labels_file))
                # Labels stored in colors (red channel)
                raw_labels = np.asarray(labels_mesh.colors)[:, 0] * 255
                raw_labels = raw_labels.astype(np.int32)

                # Map to our 4 classes
                labels = np.full(len(raw_labels), 3, dtype=np.int64)  # Default: object
                for scannet_label, our_label in self.LABEL_MAP.items():
                    labels[raw_labels == scannet_label] = our_label
            else:
                # No labels - use heuristic
                labels = self._heuristic_labels(points)

            return points, labels

        except ImportError:
            print("Open3D not installed. Using synthetic data.")
            return self._synthetic_data()

    def _heuristic_labels(self, points):
        """Generate pseudo-labels using geometric heuristics."""
        labels = np.full(len(points), 3, dtype=np.int64)  # Default: object

        # Floor: lowest points with upward normal
        y_positions = points[:, 1]
        normals_y = points[:, 4]

        floor_mask = (y_positions < np.percentile(y_positions, 10)) & (normals_y > 0.8)
        ceiling_mask = (y_positions > np.percentile(y_positions, 90)) & (normals_y < -0.8)
        wall_mask = np.abs(normals_y) < 0.3

        labels[floor_mask] = 0
        labels[ceiling_mask] = 1
        labels[wall_mask] = 2

        return labels

    def _synthetic_data(self):
        """Generate synthetic room data for testing."""
        # Create a simple box room
        num_points = self.num_points

        points = []
        labels = []

        # Floor (y = 0)
        n_floor = num_points // 4
        floor_pts = np.random.rand(n_floor, 3) * [5, 0.01, 5] - [2.5, 0, 2.5]
        floor_normals = np.tile([0, 1, 0], (n_floor, 1))
        points.append(np.hstack([floor_pts, floor_normals]))
        labels.extend([0] * n_floor)

        # Ceiling (y = 2.5)
        n_ceiling = num_points // 4
        ceiling_pts = np.random.rand(n_ceiling, 3) * [5, 0.01, 5] - [2.5, -2.5, 2.5]
        ceiling_normals = np.tile([0, -1, 0], (n_ceiling, 1))
        points.append(np.hstack([ceiling_pts, ceiling_normals]))
        labels.extend([1] * n_ceiling)

        # Walls
        n_wall = num_points // 4
        # Wall at x = -2.5
        wall_pts = np.random.rand(n_wall, 3) * [0.01, 2.5, 5] - [2.5, 0, 2.5]
        wall_normals = np.tile([1, 0, 0], (n_wall, 1))
        points.append(np.hstack([wall_pts, wall_normals]))
        labels.extend([2] * n_wall)

        # Objects (random boxes)
        n_obj = num_points // 4
        obj_pts = np.random.rand(n_obj, 3) * [1, 1, 1] + [0, 0.5, 0]
        obj_normals = np.random.randn(n_obj, 3)
        obj_normals /= np.linalg.norm(obj_normals, axis=1, keepdims=True)
        points.append(np.hstack([obj_pts, obj_normals]))
        labels.extend([3] * n_obj)

        points = np.vstack(points).astype(np.float32)
        labels = np.array(labels, dtype=np.int64)

        return points, labels

    def _augment(self, points):
        """Apply data augmentation."""
        # Random rotation around Y axis
        angle = np.random.uniform(0, 2 * np.pi)
        cos_a, sin_a = np.cos(angle), np.sin(angle)
        rotation = np.array([
            [cos_a, 0, sin_a],
            [0, 1, 0],
            [-sin_a, 0, cos_a]
        ])

        points[:, :3] = points[:, :3] @ rotation.T
        points[:, 3:6] = points[:, 3:6] @ rotation.T

        # Random scaling
        scale = np.random.uniform(0.9, 1.1)
        points[:, :3] *= scale

        # Random jitter
        jitter = np.random.normal(0, 0.01, points[:, :3].shape)
        points[:, :3] += jitter

        return points


class CustomDataset(Dataset):
    """
    Custom dataset from your app's labeled exports.

    Expected format (JSON):
    {
        "points": [[x, y, z, nx, ny, nz], ...],
        "labels": [0, 1, 2, 3, ...]  // 0=floor, 1=ceiling, 2=wall, 3=object
    }
    """

    def __init__(self, data_path, split="train", num_points=4096, augment=True):
        self.data_path = Path(data_path)
        self.num_points = num_points
        self.augment = augment and split == "train"

        # Find all JSON files
        self.files = list(self.data_path.glob("*.json"))

        # Split
        np.random.seed(42)
        np.random.shuffle(self.files)
        split_idx = int(len(self.files) * 0.8)

        if split == "train":
            self.files = self.files[:split_idx]
        else:
            self.files = self.files[split_idx:]

        print(f"Loaded {len(self.files)} files for {split}")

    def __len__(self):
        return len(self.files)

    def __getitem__(self, idx):
        with open(self.files[idx]) as f:
            data = json.load(f)

        points = np.array(data["points"], dtype=np.float32)
        labels = np.array(data["labels"], dtype=np.int64)

        # Sample
        if len(points) > self.num_points:
            indices = np.random.choice(len(points), self.num_points, replace=False)
        else:
            indices = np.random.choice(len(points), self.num_points, replace=True)

        points = points[indices]
        labels = labels[indices]

        # Normalize
        centroid = np.mean(points[:, :3], axis=0)
        points[:, :3] -= centroid
        scale = np.max(np.linalg.norm(points[:, :3], axis=1))
        if scale > 0:
            points[:, :3] /= scale

        return {
            "points": torch.FloatTensor(points),
            "labels": torch.LongTensor(labels),
            "scene": self.files[idx].stem
        }


# ============================================================================
# Model (same as in convert_pretrained.py)
# ============================================================================

class PointNetSegmentation(nn.Module):
    """PointNet for semantic segmentation."""

    def __init__(self, num_classes=4, input_channels=6):
        super().__init__()
        self.num_classes = num_classes

        # Encoder
        self.enc1 = nn.Conv1d(input_channels, 64, 1)
        self.enc2 = nn.Conv1d(64, 128, 1)
        self.enc3 = nn.Conv1d(128, 256, 1)
        self.enc4 = nn.Conv1d(256, 512, 1)
        self.enc5 = nn.Conv1d(512, 1024, 1)

        self.bn1 = nn.BatchNorm1d(64)
        self.bn2 = nn.BatchNorm1d(128)
        self.bn3 = nn.BatchNorm1d(256)
        self.bn4 = nn.BatchNorm1d(512)
        self.bn5 = nn.BatchNorm1d(1024)

        # Decoder
        self.dec1 = nn.Conv1d(1024 + 64, 512, 1)
        self.dec2 = nn.Conv1d(512, 256, 1)
        self.dec3 = nn.Conv1d(256, 128, 1)
        self.dec4 = nn.Conv1d(128, num_classes, 1)

        self.dec_bn1 = nn.BatchNorm1d(512)
        self.dec_bn2 = nn.BatchNorm1d(256)
        self.dec_bn3 = nn.BatchNorm1d(128)

        self.dropout = nn.Dropout(0.3)

    def forward(self, x):
        batch_size = x.size(0)
        num_points = x.size(1)
        x = x.transpose(2, 1)  # (B, 6, N)

        # Encode
        x1 = F.relu(self.bn1(self.enc1(x)))
        x2 = F.relu(self.bn2(self.enc2(x1)))
        x3 = F.relu(self.bn3(self.enc3(x2)))
        x4 = F.relu(self.bn4(self.enc4(x3)))
        x5 = F.relu(self.bn5(self.enc5(x4)))

        # Global feature
        global_feat = torch.max(x5, 2, keepdim=True)[0]
        global_feat = global_feat.repeat(1, 1, num_points)

        # Decode
        x = torch.cat([global_feat, x1], dim=1)
        x = F.relu(self.dec_bn1(self.dec1(x)))
        x = F.relu(self.dec_bn2(self.dec2(x)))
        x = F.relu(self.dec_bn3(self.dec3(x)))
        x = self.dropout(x)
        x = self.dec4(x)

        x = x.transpose(2, 1)  # (B, N, C)
        return x


# ============================================================================
# Training
# ============================================================================

def train_epoch(model, loader, optimizer, device):
    """Train for one epoch."""
    model.train()
    total_loss = 0
    correct = 0
    total = 0

    for batch in loader:
        points = batch["points"].to(device)
        labels = batch["labels"].to(device)

        optimizer.zero_grad()
        outputs = model(points)

        loss = F.cross_entropy(outputs.reshape(-1, 4), labels.reshape(-1))
        loss.backward()
        optimizer.step()

        total_loss += loss.item()
        preds = outputs.argmax(dim=-1)
        correct += (preds == labels).sum().item()
        total += labels.numel()

    return total_loss / len(loader), correct / total


def validate(model, loader, device):
    """Validate model."""
    model.eval()
    total_loss = 0
    correct = 0
    total = 0

    # Per-class accuracy
    class_correct = [0] * 4
    class_total = [0] * 4

    with torch.no_grad():
        for batch in loader:
            points = batch["points"].to(device)
            labels = batch["labels"].to(device)

            outputs = model(points)
            loss = F.cross_entropy(outputs.reshape(-1, 4), labels.reshape(-1))

            total_loss += loss.item()
            preds = outputs.argmax(dim=-1)
            correct += (preds == labels).sum().item()
            total += labels.numel()

            # Per-class
            for c in range(4):
                mask = labels == c
                class_correct[c] += (preds[mask] == c).sum().item()
                class_total[c] += mask.sum().item()

    class_acc = [c / t if t > 0 else 0 for c, t in zip(class_correct, class_total)]
    return total_loss / len(loader), correct / total, class_acc


def train(args):
    """Main training function."""
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"Using device: {device}")

    # Dataset
    if args.custom_format:
        train_dataset = CustomDataset(args.data_path, "train", args.num_points)
        val_dataset = CustomDataset(args.data_path, "val", args.num_points, augment=False)
    else:
        train_dataset = ScanNetDataset(args.data_path, "train", args.num_points)
        val_dataset = ScanNetDataset(args.data_path, "val", args.num_points, augment=False)

    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True, num_workers=4)
    val_loader = DataLoader(val_dataset, batch_size=args.batch_size, shuffle=False, num_workers=4)

    # Model
    model = PointNetSegmentation(num_classes=4).to(device)
    optimizer = optim.Adam(model.parameters(), lr=args.lr)
    scheduler = optim.lr_scheduler.StepLR(optimizer, step_size=20, gamma=0.5)

    # Training loop
    best_val_acc = 0
    output_dir = Path(args.output_dir)
    output_dir.mkdir(exist_ok=True)

    for epoch in range(args.epochs):
        train_loss, train_acc = train_epoch(model, train_loader, optimizer, device)
        val_loss, val_acc, class_acc = validate(model, val_loader, device)
        scheduler.step()

        print(f"Epoch {epoch+1}/{args.epochs}")
        print(f"  Train Loss: {train_loss:.4f}, Acc: {train_acc:.4f}")
        print(f"  Val Loss: {val_loss:.4f}, Acc: {val_acc:.4f}")
        print(f"  Class Acc - Floor: {class_acc[0]:.3f}, Ceiling: {class_acc[1]:.3f}, "
              f"Wall: {class_acc[2]:.3f}, Object: {class_acc[3]:.3f}")

        # Save best model
        if val_acc > best_val_acc:
            best_val_acc = val_acc
            torch.save({
                "epoch": epoch,
                "model_state_dict": model.state_dict(),
                "optimizer_state_dict": optimizer.state_dict(),
                "val_acc": val_acc,
            }, output_dir / "best_model.ckpt")
            print(f"  Saved best model (acc: {val_acc:.4f})")

        # Save latest
        torch.save({
            "epoch": epoch,
            "model_state_dict": model.state_dict(),
            "optimizer_state_dict": optimizer.state_dict(),
            "val_acc": val_acc,
        }, output_dir / "latest_model.ckpt")

    print(f"\nTraining complete! Best validation accuracy: {best_val_acc:.4f}")
    print(f"Models saved to: {output_dir}")


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Train PointNet for indoor segmentation")
    parser.add_argument("--data_path", type=str, required=True, help="Path to dataset")
    parser.add_argument("--custom_format", action="store_true", help="Use custom JSON format")
    parser.add_argument("--epochs", type=int, default=100, help="Number of epochs")
    parser.add_argument("--batch_size", type=int, default=16, help="Batch size")
    parser.add_argument("--lr", type=float, default=0.001, help="Learning rate")
    parser.add_argument("--num_points", type=int, default=4096, help="Points per sample")
    parser.add_argument("--output_dir", type=str, default="checkpoints", help="Output directory")
    args = parser.parse_args()

    train(args)


if __name__ == "__main__":
    main()
