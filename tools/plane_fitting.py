"""
Room Boundary Detection from LiDAR Point Clouds

This script implements the plane fitting algorithm:
1. Load point cloud data (from PLY export)
2. Find farthest points with highest density = floor/ceiling/walls
3. Fit infinite planes to these clusters
4. Intersect planes to form closed 3D room boundary
5. Scale planes 5x to ensure no holes

Usage:
    python plane_fitting.py <input.ply> [output.obj]
"""

import numpy as np
from dataclasses import dataclass
from typing import List, Tuple, Optional
import sys


@dataclass
class RoomPlane:
    """Represents an infinite plane in the room"""
    surface_type: str  # 'floor', 'ceiling', 'wall'
    normal: np.ndarray  # Unit normal vector
    point: np.ndarray   # A point on the plane
    density: int        # Number of points used to fit this plane
    angle: Optional[float] = None  # For walls: angle in degrees (0-360)

    @property
    def d(self) -> float:
        """Distance from origin (plane equation: n·x + d = 0)"""
        return -np.dot(self.normal, self.point)

    def distance_to_point(self, p: np.ndarray) -> float:
        """Signed distance from point to plane"""
        return np.dot(self.normal, p) + self.d

    def project_point(self, p: np.ndarray) -> np.ndarray:
        """Project a point onto this plane"""
        dist = self.distance_to_point(p)
        return p - dist * self.normal


@dataclass
class RoomBoundary:
    """Closed 3D room boundary from intersecting planes"""
    floor_plane: RoomPlane
    ceiling_plane: RoomPlane
    wall_planes: List[RoomPlane]
    corners: List[np.ndarray]

    @property
    def room_height(self) -> float:
        return abs(self.ceiling_plane.point[1] - self.floor_plane.point[1])


def load_ply(filepath: str) -> Tuple[np.ndarray, np.ndarray]:
    """Load PLY file, return vertices and normals"""
    vertices = []
    normals = []

    with open(filepath, 'r') as f:
        # Parse header
        line = f.readline().strip()
        if line != 'ply':
            raise ValueError("Not a PLY file")

        vertex_count = 0
        header_done = False
        has_normals = False

        while not header_done:
            line = f.readline().strip()
            if line.startswith('element vertex'):
                vertex_count = int(line.split()[-1])
            if 'nx' in line or 'ny' in line or 'nz' in line:
                has_normals = True
            if line == 'end_header':
                header_done = True

        # Read vertices
        for _ in range(vertex_count):
            parts = f.readline().strip().split()
            x, y, z = float(parts[0]), float(parts[1]), float(parts[2])
            vertices.append([x, y, z])

            if has_normals and len(parts) >= 6:
                nx, ny, nz = float(parts[3]), float(parts[4]), float(parts[5])
                normals.append([nx, ny, nz])

    return np.array(vertices), np.array(normals) if normals else None


def classify_points_by_normal(vertices: np.ndarray, normals: np.ndarray) -> dict:
    """
    Classify points into floor, ceiling, walls based on normal direction.
    Returns dict with point indices for each surface type.
    """
    classifications = {
        'floor': [],      # Normal pointing up (Y+)
        'ceiling': [],    # Normal pointing down (Y-)
        'wall': [],       # Normal roughly horizontal
        'object': []      # Everything else
    }

    up = np.array([0, 1, 0])
    down = np.array([0, -1, 0])

    for i, normal in enumerate(normals):
        normal = normal / np.linalg.norm(normal)  # Normalize

        dot_up = np.dot(normal, up)
        dot_down = np.dot(normal, down)

        # Check if horizontal (wall-like)
        horizontal_component = np.sqrt(normal[0]**2 + normal[2]**2)

        if dot_up > 0.7:  # ~45 degrees from up
            classifications['floor'].append(i)
        elif dot_down > 0.7:  # ~45 degrees from down
            classifications['ceiling'].append(i)
        elif horizontal_component > 0.7:  # Mostly horizontal normal = vertical surface
            classifications['wall'].append(i)
        else:
            classifications['object'].append(i)

    return classifications


def find_farthest_dense_cluster(vertices: np.ndarray, indices: List[int],
                                  axis: str = 'y', direction: str = 'min') -> Tuple[np.ndarray, List[int]]:
    """
    Find the cluster of points that are farthest along an axis AND have high density.

    For floor: lowest Y with high density
    For ceiling: highest Y with high density
    For walls: farthest from center with high density

    Returns: (cluster_center, point_indices_in_cluster)
    """
    if len(indices) == 0:
        return None, []

    points = vertices[indices]

    # Determine which axis to use
    axis_idx = {'x': 0, 'y': 1, 'z': 2}[axis]

    # Sort points by the axis
    if direction == 'min':
        sorted_indices = np.argsort(points[:, axis_idx])
    else:
        sorted_indices = np.argsort(-points[:, axis_idx])

    # Take the farthest 20% of points
    n_farthest = max(int(len(sorted_indices) * 0.2), 10)
    farthest_local = sorted_indices[:n_farthest]
    farthest_global = [indices[i] for i in farthest_local]

    # Find the dense region within these farthest points
    farthest_points = points[farthest_local]

    # Use histogram to find density peak along the axis
    axis_values = farthest_points[:, axis_idx]
    hist, bin_edges = np.histogram(axis_values, bins=20)
    peak_bin = np.argmax(hist)

    # Get points in the peak density bin (with some tolerance)
    bin_min = bin_edges[max(0, peak_bin - 1)]
    bin_max = bin_edges[min(len(bin_edges) - 1, peak_bin + 2)]

    cluster_mask = (axis_values >= bin_min) & (axis_values <= bin_max)
    cluster_local = farthest_local[cluster_mask]
    cluster_global = [indices[i] for i in cluster_local]

    if len(cluster_global) == 0:
        return None, []

    cluster_center = np.mean(vertices[cluster_global], axis=0)

    return cluster_center, cluster_global


def fit_plane_ransac(points: np.ndarray, n_iterations: int = 100,
                     threshold: float = 0.05) -> Tuple[np.ndarray, np.ndarray, int]:
    """
    Fit a plane to points using RANSAC.

    Returns: (normal, point_on_plane, inlier_count)
    """
    if len(points) < 3:
        return None, None, 0

    best_normal = None
    best_point = None
    best_inliers = 0

    for _ in range(n_iterations):
        # Random 3 points
        idx = np.random.choice(len(points), 3, replace=False)
        p1, p2, p3 = points[idx]

        # Compute plane normal
        v1 = p2 - p1
        v2 = p3 - p1
        normal = np.cross(v1, v2)

        if np.linalg.norm(normal) < 1e-6:
            continue

        normal = normal / np.linalg.norm(normal)

        # Count inliers
        distances = np.abs(np.dot(points - p1, normal))
        inliers = np.sum(distances < threshold)

        if inliers > best_inliers:
            best_inliers = inliers
            best_normal = normal
            best_point = p1

    return best_normal, best_point, best_inliers


def cluster_walls_by_angle(vertices: np.ndarray, normals: np.ndarray,
                           wall_indices: List[int],
                           min_angle_separation: float = 15.0,
                           min_cluster_ratio: float = 0.02) -> List[List[int]]:
    """
    Cluster wall points by their normal direction (angle around Y axis).

    Handles arbitrary room shapes:
    - Any number of walls (3, 4, 5, 6+)
    - Non-90° angles between walls
    - Automatically detects number of distinct wall directions

    Args:
        vertices: All vertices
        normals: All normals
        wall_indices: Indices of points classified as walls
        min_angle_separation: Minimum angle between distinct walls (degrees)
        min_cluster_ratio: Minimum fraction of wall points for a valid cluster

    Returns list of clusters, each containing point indices.
    """
    if len(wall_indices) == 0:
        return []

    wall_normals = normals[wall_indices]

    # Calculate angle of each normal (around Y axis)
    angles = np.arctan2(wall_normals[:, 2], wall_normals[:, 0])  # -pi to pi
    angles_deg = np.degrees(angles) % 360  # 0 to 360

    # Use finer histogram to detect any angle walls
    n_bins = 72  # 5-degree bins for better angle resolution
    hist, bin_edges = np.histogram(angles_deg, bins=n_bins)

    # Smooth histogram to reduce noise (moving average)
    smoothed = np.convolve(hist, np.ones(3)/3, mode='same')

    # Find all peaks (local maxima above threshold)
    min_count = len(wall_indices) * min_cluster_ratio
    peaks = []

    for i in range(n_bins):
        prev_i = (i - 1) % n_bins
        next_i = (i + 1) % n_bins
        # Check if local maximum
        if smoothed[i] > smoothed[prev_i] and smoothed[i] > smoothed[next_i]:
            if smoothed[i] > min_count:
                peak_angle = (bin_edges[i] + bin_edges[i + 1]) / 2
                peaks.append((peak_angle, smoothed[i]))

    # Sort peaks by count (strongest first)
    peaks.sort(key=lambda x: -x[1])

    # Greedily select peaks that are far enough apart
    selected_peaks = []
    for peak_angle, peak_count in peaks:
        too_close = False
        for existing_angle in selected_peaks:
            # Angular distance (handle wraparound)
            dist = min(abs(peak_angle - existing_angle),
                      360 - abs(peak_angle - existing_angle))
            if dist < min_angle_separation:
                too_close = True
                break
        if not too_close:
            selected_peaks.append(peak_angle)

    # Sort selected peaks by angle for consistent ordering
    selected_peaks.sort()

    print(f"  Detected {len(selected_peaks)} wall directions: {[f'{a:.1f}°' for a in selected_peaks]}")

    # Assign points to nearest peak
    clusters = [[] for _ in range(len(selected_peaks))]

    for local_idx, global_idx in enumerate(wall_indices):
        angle = angles_deg[local_idx]

        # Find nearest peak
        min_dist = float('inf')
        best_cluster = 0
        for c, peak in enumerate(selected_peaks):
            # Handle wraparound
            dist = min(abs(angle - peak), 360 - abs(angle - peak))
            if dist < min_dist:
                min_dist = dist
                best_cluster = c

        # Only assign if reasonably close to a peak
        if min_dist < min_angle_separation * 2:
            clusters[best_cluster].append(global_idx)

    # Filter out small clusters
    min_cluster_size = max(10, len(wall_indices) * 0.01)
    clusters = [c for c in clusters if len(c) >= min_cluster_size]

    return clusters


def intersect_three_planes(p1: RoomPlane, p2: RoomPlane, p3: RoomPlane) -> Optional[np.ndarray]:
    """
    Find the intersection point of three planes.
    Returns None if planes don't intersect at a single point.
    """
    # Build matrix from normals
    A = np.array([p1.normal, p2.normal, p3.normal])
    b = np.array([-p1.d, -p2.d, -p3.d])

    # Check if solvable
    if abs(np.linalg.det(A)) < 1e-6:
        return None

    return np.linalg.solve(A, b)


def fit_room_boundary(vertices: np.ndarray, normals: np.ndarray) -> Optional[RoomBoundary]:
    """
    Main function: fit planes to point cloud and create room boundary.

    Algorithm:
    1. Classify points by normal direction
    2. Find farthest+dense clusters for floor, ceiling, walls
    3. Fit planes using RANSAC
    4. Intersect planes to find corners
    5. Return RoomBoundary
    """
    print(f"Processing {len(vertices)} points...")

    # Step 1: Classify by normal
    classifications = classify_points_by_normal(vertices, normals)
    print(f"  Floor points: {len(classifications['floor'])}")
    print(f"  Ceiling points: {len(classifications['ceiling'])}")
    print(f"  Wall points: {len(classifications['wall'])}")
    print(f"  Object points: {len(classifications['object'])}")

    # Step 2a: Find floor cluster (lowest Y, highest density)
    floor_center, floor_cluster = find_farthest_dense_cluster(
        vertices, classifications['floor'], axis='y', direction='min'
    )
    print(f"  Floor cluster: {len(floor_cluster)} points at Y={floor_center[1]:.3f}" if floor_center is not None else "  No floor cluster found")

    # Step 2b: Find ceiling cluster (highest Y, highest density)
    ceiling_center, ceiling_cluster = find_farthest_dense_cluster(
        vertices, classifications['ceiling'], axis='y', direction='max'
    )
    print(f"  Ceiling cluster: {len(ceiling_cluster)} points at Y={ceiling_center[1]:.3f}" if ceiling_center is not None else "  No ceiling cluster found")

    # Step 2c: Cluster walls by angle and find farthest for each
    wall_clusters = cluster_walls_by_angle(vertices, normals, classifications['wall'])
    print(f"  Found {len(wall_clusters)} wall clusters")

    # Step 3a: Fit floor plane
    if len(floor_cluster) < 10:
        print("ERROR: Not enough floor points")
        return None

    floor_normal, floor_point, floor_inliers = fit_plane_ransac(vertices[floor_cluster])

    # Ensure floor normal points up
    if floor_normal[1] < 0:
        floor_normal = -floor_normal

    floor_plane = RoomPlane(
        surface_type='floor',
        normal=floor_normal,
        point=floor_point,
        density=floor_inliers
    )
    print(f"  Floor plane: normal={floor_normal}, point={floor_point}")

    # Step 3b: Fit ceiling plane
    if len(ceiling_cluster) < 10:
        print("ERROR: Not enough ceiling points")
        return None

    ceiling_normal, ceiling_point, ceiling_inliers = fit_plane_ransac(vertices[ceiling_cluster])

    # Ensure ceiling normal points down
    if ceiling_normal[1] > 0:
        ceiling_normal = -ceiling_normal

    ceiling_plane = RoomPlane(
        surface_type='ceiling',
        normal=ceiling_normal,
        point=ceiling_point,
        density=ceiling_inliers
    )
    print(f"  Ceiling plane: normal={ceiling_normal}, point={ceiling_point}")

    # Step 3c: Fit wall planes
    wall_planes = []
    for i, cluster in enumerate(wall_clusters):
        if len(cluster) < 10:
            continue

        wall_normal, wall_point, wall_inliers = fit_plane_ransac(vertices[cluster])

        if wall_normal is None:
            continue

        # Calculate wall angle (around Y axis)
        angle = np.degrees(np.arctan2(wall_normal[2], wall_normal[0])) % 360

        wall_plane = RoomPlane(
            surface_type='wall',
            normal=wall_normal,
            point=wall_point,
            density=wall_inliers,
            angle=angle
        )
        wall_planes.append(wall_plane)
        print(f"  Wall {i}: angle={angle:.1f}°, {wall_inliers} inliers")

    # Merge nearly identical walls (same direction AND close together)
    merged_walls = []
    for wall in wall_planes:
        merged = False
        for i, existing in enumerate(merged_walls):
            # Check if normals point the SAME direction (not opposite)
            dot = np.dot(wall.normal, existing.normal)
            if dot > 0.966:  # cos(15°) ≈ 0.966 - same direction
                # Also check spatial proximity (project points onto each other's plane)
                dist = abs(existing.distance_to_point(wall.point))
                if dist < 0.5:  # Within 50cm
                    # Keep the one with more inliers
                    if wall.density > existing.density:
                        merged_walls[i] = wall
                    merged = True
                    break
        if not merged:
            merged_walls.append(wall)

    wall_planes = merged_walls
    print(f"  After merging: {len(wall_planes)} unique walls")

    if len(wall_planes) < 3:
        print(f"ERROR: Need at least 3 walls, found {len(wall_planes)}")
        return None

    # Step 4: Find corners (intersections of floor/ceiling with walls)
    # For non-rectangular rooms, we need to find which walls actually connect

    # Sort walls by angle
    wall_planes.sort(key=lambda w: w.angle or 0)

    # Calculate room center (average of all wall points)
    wall_points = np.array([w.point for w in wall_planes])
    room_center = np.mean(wall_points, axis=0)
    room_center[1] = (floor_plane.point[1] + ceiling_plane.point[1]) / 2

    # Estimate room radius (max distance from center to any wall)
    room_radius = max(np.linalg.norm(w.point[:2] - room_center[:2]) for w in wall_planes) * 2

    corners = []
    valid_wall_pairs = []

    # Try all pairs of walls to find valid intersections
    for i in range(len(wall_planes)):
        for j in range(i + 1, len(wall_planes)):
            wall1 = wall_planes[i]
            wall2 = wall_planes[j]

            # Check if walls are not parallel (can intersect)
            dot = abs(np.dot(wall1.normal, wall2.normal))
            if dot > 0.95:  # Nearly parallel, skip
                continue

            # Find floor corner
            floor_corner = intersect_three_planes(floor_plane, wall1, wall2)
            if floor_corner is not None:
                # Validate corner is within reasonable room bounds
                dist_from_center = np.linalg.norm(floor_corner[:2] - room_center[:2])
                if dist_from_center < room_radius:
                    corners.append(floor_corner)
                    valid_wall_pairs.append((i, j))

                    # Also add ceiling corner
                    ceiling_corner = intersect_three_planes(ceiling_plane, wall1, wall2)
                    if ceiling_corner is not None:
                        corners.append(ceiling_corner)

    # Remove duplicate corners (within 10cm)
    unique_corners = []
    for corner in corners:
        is_duplicate = False
        for existing in unique_corners:
            if np.linalg.norm(corner - existing) < 0.1:
                is_duplicate = True
                break
        if not is_duplicate:
            unique_corners.append(corner)

    corners = unique_corners
    print(f"  Found {len(corners)} corners from {len(valid_wall_pairs)} wall intersections")

    return RoomBoundary(
        floor_plane=floor_plane,
        ceiling_plane=ceiling_plane,
        wall_planes=wall_planes,
        corners=corners
    )


def export_room_boundary_obj(boundary: RoomBoundary, filepath: str, scale: float = 5.0,
                              room_size: float = None):
    """
    Export room boundary as OBJ with infinite planes (scaled 5x).
    Creates large quads for floor, ceiling, and walls.

    Args:
        boundary: RoomBoundary with planes
        filepath: Output OBJ file path
        scale: Scale factor for plane size (default 5x)
        room_size: Approximate room size in meters (auto-detected if None)
    """
    with open(filepath, 'w') as f:
        f.write("# Room Boundary Export (Infinite Planes)\n")
        f.write(f"# Scale factor: {scale}x\n")
        f.write(f"# Room height: {boundary.room_height:.3f}m\n")
        f.write(f"# Walls: {len(boundary.wall_planes)}\n\n")

        vertex_index = 1  # OBJ is 1-indexed

        # Calculate room bounds from valid corners only
        if len(boundary.corners) > 0:
            corners_array = np.array(boundary.corners)
            # Filter out invalid corners (very far from origin)
            valid_corners = corners_array[np.all(np.abs(corners_array) < 100, axis=1)]
            if len(valid_corners) >= 4:
                min_bound = np.min(valid_corners, axis=0)
                max_bound = np.max(valid_corners, axis=0)
                center = (min_bound + max_bound) / 2
                actual_size = max_bound - min_bound
                # Use the actual room size scaled up
                half_size = actual_size / 2 * scale
            else:
                # Use wall points to estimate center
                wall_points = np.array([w.point for w in boundary.wall_planes])
                center = np.mean(wall_points, axis=0)
                center[1] = (boundary.floor_plane.point[1] + boundary.ceiling_plane.point[1]) / 2
                estimated_size = room_size if room_size else 5.0
                half_size = np.array([estimated_size, 0, estimated_size]) * scale
        else:
            # Fallback: estimate from floor/ceiling
            center = boundary.floor_plane.point
            estimated_size = room_size if room_size else 5.0
            half_size = np.array([estimated_size, 0, estimated_size]) * scale

        floor_y = boundary.floor_plane.point[1]
        ceiling_y = boundary.ceiling_plane.point[1]

        # FLOOR
        f.write("# Floor Plane\n")
        f.write("g Floor\n")
        f.write("o Floor_Plane\n")

        floor_verts = [
            [center[0] - half_size[0], floor_y, center[2] - half_size[2]],
            [center[0] + half_size[0], floor_y, center[2] - half_size[2]],
            [center[0] + half_size[0], floor_y, center[2] + half_size[2]],
            [center[0] - half_size[0], floor_y, center[2] + half_size[2]],
        ]
        for v in floor_verts:
            f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
        f.write("vn 0 1 0\n")
        f.write(f"f {vertex_index}//1 {vertex_index+1}//1 {vertex_index+2}//1 {vertex_index+3}//1\n\n")
        vertex_index += 4

        # CEILING
        f.write("# Ceiling Plane\n")
        f.write("g Ceiling\n")
        f.write("o Ceiling_Plane\n")

        ceiling_verts = [
            [center[0] - half_size[0], ceiling_y, center[2] - half_size[2]],
            [center[0] + half_size[0], ceiling_y, center[2] - half_size[2]],
            [center[0] + half_size[0], ceiling_y, center[2] + half_size[2]],
            [center[0] - half_size[0], ceiling_y, center[2] + half_size[2]],
        ]
        for v in ceiling_verts:
            f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
        f.write("vn 0 -1 0\n")
        # Reverse winding for ceiling
        f.write(f"f {vertex_index+3}//2 {vertex_index+2}//2 {vertex_index+1}//2 {vertex_index}//2\n\n")
        vertex_index += 4

        # WALLS
        f.write("# Wall Planes\n")
        f.write("g Walls\n")

        normal_index = 3
        for i, wall in enumerate(boundary.wall_planes):
            f.write(f"o Wall_{i}\n")

            # Wall tangent (horizontal direction)
            up = np.array([0, 1, 0])
            tangent = np.cross(up, wall.normal)
            tangent = tangent / np.linalg.norm(tangent)

            wall_half_width = half_size[0]
            wall_point = wall.point

            wall_verts = [
                wall_point + tangent * wall_half_width + np.array([0, floor_y - wall_point[1], 0]),
                wall_point - tangent * wall_half_width + np.array([0, floor_y - wall_point[1], 0]),
                wall_point - tangent * wall_half_width + np.array([0, ceiling_y - wall_point[1], 0]),
                wall_point + tangent * wall_half_width + np.array([0, ceiling_y - wall_point[1], 0]),
            ]

            for v in wall_verts:
                f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
            f.write(f"vn {wall.normal[0]:.6f} {wall.normal[1]:.6f} {wall.normal[2]:.6f}\n")
            f.write(f"f {vertex_index}//{normal_index} {vertex_index+1}//{normal_index} {vertex_index+2}//{normal_index} {vertex_index+3}//{normal_index}\n")

            vertex_index += 4
            normal_index += 1

        print(f"Exported room boundary to {filepath}")
        print(f"  Floor at Y={floor_y:.3f}")
        print(f"  Ceiling at Y={ceiling_y:.3f}")
        print(f"  {len(boundary.wall_planes)} walls")


def main():
    if len(sys.argv) < 2:
        print("Usage: python plane_fitting.py <input.ply> [output.obj]")
        print("\nThis script reads a PLY point cloud and fits room boundary planes.")
        return

    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else input_file.replace('.ply', '_boundary.obj')

    print(f"Loading {input_file}...")
    vertices, normals = load_ply(input_file)

    if normals is None or len(normals) == 0:
        print("ERROR: PLY file must include vertex normals (nx, ny, nz)")
        return

    print(f"Loaded {len(vertices)} vertices with normals")

    boundary = fit_room_boundary(vertices, normals)

    if boundary is None:
        print("Failed to fit room boundary")
        return

    print(f"\nRoom Boundary:")
    print(f"  Height: {boundary.room_height:.3f}m")
    print(f"  Walls: {len(boundary.wall_planes)}")
    print(f"  Corners: {len(boundary.corners)}")

    export_room_boundary_obj(boundary, output_file)


if __name__ == '__main__':
    main()
