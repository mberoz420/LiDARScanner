"""
Generate synthetic room point cloud for testing plane fitting algorithm.

Creates a simple rectangular room with:
- Floor
- Ceiling
- 4 walls
- Optional furniture (objects) to test classification

Usage:
    python generate_test_room.py [output.ply]
"""

import numpy as np
import sys


def generate_plane_points(center: np.ndarray, normal: np.ndarray,
                         width: float, height: float,
                         density: int = 1000,
                         noise: float = 0.02) -> tuple:
    """
    Generate points on a plane with normals.

    Returns: (points, normals)
    """
    normal = normal / np.linalg.norm(normal)

    # Find two orthogonal vectors on the plane
    if abs(normal[1]) < 0.9:
        up = np.array([0, 1, 0])
    else:
        up = np.array([1, 0, 0])

    tangent1 = np.cross(normal, up)
    tangent1 = tangent1 / np.linalg.norm(tangent1)
    tangent2 = np.cross(normal, tangent1)
    tangent2 = tangent2 / np.linalg.norm(tangent2)

    # Generate random points on plane
    u = (np.random.random(density) - 0.5) * width
    v = (np.random.random(density) - 0.5) * height

    points = center + np.outer(u, tangent1) + np.outer(v, tangent2)

    # Add noise
    points += np.random.normal(0, noise, points.shape)

    # Normals (with slight variation)
    normals = np.tile(normal, (density, 1))
    normals += np.random.normal(0, 0.05, normals.shape)
    normals = normals / np.linalg.norm(normals, axis=1, keepdims=True)

    return points, normals


def generate_box_points(center: np.ndarray, size: np.ndarray,
                        density: int = 500) -> tuple:
    """Generate points on a box surface (furniture)."""
    all_points = []
    all_normals = []

    # Top face
    pts, nrm = generate_plane_points(
        center + np.array([0, size[1]/2, 0]),
        np.array([0, 1, 0]),
        size[0], size[2],
        density // 6
    )
    all_points.append(pts)
    all_normals.append(nrm)

    # Front face
    pts, nrm = generate_plane_points(
        center + np.array([0, 0, size[2]/2]),
        np.array([0, 0, 1]),
        size[0], size[1],
        density // 6
    )
    all_points.append(pts)
    all_normals.append(nrm)

    # Back face
    pts, nrm = generate_plane_points(
        center + np.array([0, 0, -size[2]/2]),
        np.array([0, 0, -1]),
        size[0], size[1],
        density // 6
    )
    all_points.append(pts)
    all_normals.append(nrm)

    # Left face
    pts, nrm = generate_plane_points(
        center + np.array([-size[0]/2, 0, 0]),
        np.array([-1, 0, 0]),
        size[2], size[1],
        density // 6
    )
    all_points.append(pts)
    all_normals.append(nrm)

    # Right face
    pts, nrm = generate_plane_points(
        center + np.array([size[0]/2, 0, 0]),
        np.array([1, 0, 0]),
        size[2], size[1],
        density // 6
    )
    all_points.append(pts)
    all_normals.append(nrm)

    return np.vstack(all_points), np.vstack(all_normals)


def generate_room(room_width: float = 5.0,
                  room_depth: float = 4.0,
                  room_height: float = 2.7,
                  floor_density: int = 2000,
                  ceiling_density: int = 2000,
                  wall_density: int = 1500,
                  add_furniture: bool = True) -> tuple:
    """
    Generate a complete room with floor, ceiling, walls, and optional furniture.

    Returns: (points, normals)
    """
    all_points = []
    all_normals = []

    # Floor (Y = 0)
    pts, nrm = generate_plane_points(
        np.array([0, 0, 0]),
        np.array([0, 1, 0]),  # Normal pointing up
        room_width, room_depth,
        floor_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Floor: {len(pts)} points")

    # Ceiling
    pts, nrm = generate_plane_points(
        np.array([0, room_height, 0]),
        np.array([0, -1, 0]),  # Normal pointing down
        room_width, room_depth,
        ceiling_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Ceiling: {len(pts)} points")

    # Wall 1: Front (Z+)
    pts, nrm = generate_plane_points(
        np.array([0, room_height/2, room_depth/2]),
        np.array([0, 0, -1]),  # Normal pointing into room
        room_width, room_height,
        wall_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (front): {len(pts)} points")

    # Wall 2: Back (Z-)
    pts, nrm = generate_plane_points(
        np.array([0, room_height/2, -room_depth/2]),
        np.array([0, 0, 1]),
        room_width, room_height,
        wall_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (back): {len(pts)} points")

    # Wall 3: Left (X-)
    pts, nrm = generate_plane_points(
        np.array([-room_width/2, room_height/2, 0]),
        np.array([1, 0, 0]),
        room_depth, room_height,
        wall_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (left): {len(pts)} points")

    # Wall 4: Right (X+)
    pts, nrm = generate_plane_points(
        np.array([room_width/2, room_height/2, 0]),
        np.array([-1, 0, 0]),
        room_depth, room_height,
        wall_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (right): {len(pts)} points")

    # Add furniture
    if add_furniture:
        # Table in center
        table_center = np.array([0, 0.4, 0])  # 0.8m tall table
        table_size = np.array([1.2, 0.8, 0.8])
        pts, nrm = generate_box_points(table_center, table_size, 500)
        all_points.append(pts)
        all_normals.append(nrm)
        print(f"Table: {len(pts)} points")

        # Cabinet against wall
        cabinet_center = np.array([room_width/2 - 0.4, 0.6, 0])  # Against right wall
        cabinet_size = np.array([0.6, 1.2, 1.5])
        pts, nrm = generate_box_points(cabinet_center, cabinet_size, 600)
        all_points.append(pts)
        all_normals.append(nrm)
        print(f"Cabinet: {len(pts)} points")

        # Sofa
        sofa_center = np.array([0, 0.4, -room_depth/2 + 0.5])  # Against back wall
        sofa_size = np.array([2.0, 0.8, 0.8])
        pts, nrm = generate_box_points(sofa_center, sofa_size, 700)
        all_points.append(pts)
        all_normals.append(nrm)
        print(f"Sofa: {len(pts)} points")

    # Add some noise / back reflections (random scattered points)
    n_noise = 200
    noise_pts = np.random.uniform(
        low=[-room_width/2, 0, -room_depth/2],
        high=[room_width/2, room_height, room_depth/2],
        size=(n_noise, 3)
    )
    noise_nrm = np.random.randn(n_noise, 3)
    noise_nrm = noise_nrm / np.linalg.norm(noise_nrm, axis=1, keepdims=True)
    all_points.append(noise_pts)
    all_normals.append(noise_nrm)
    print(f"Noise: {n_noise} points")

    return np.vstack(all_points), np.vstack(all_normals)


def save_ply(filepath: str, points: np.ndarray, normals: np.ndarray):
    """Save point cloud as PLY file."""
    with open(filepath, 'w') as f:
        f.write("ply\n")
        f.write("format ascii 1.0\n")
        f.write(f"element vertex {len(points)}\n")
        f.write("property float x\n")
        f.write("property float y\n")
        f.write("property float z\n")
        f.write("property float nx\n")
        f.write("property float ny\n")
        f.write("property float nz\n")
        f.write("end_header\n")

        for i in range(len(points)):
            p = points[i]
            n = normals[i]
            f.write(f"{p[0]:.6f} {p[1]:.6f} {p[2]:.6f} {n[0]:.6f} {n[1]:.6f} {n[2]:.6f}\n")

    print(f"\nSaved {len(points)} points to {filepath}")


def generate_l_shaped_room(room_height: float = 2.7,
                           wall_density: int = 1500) -> tuple:
    """
    Generate an L-shaped room (6 walls instead of 4).

    Layout (top view):
    +--------+
    |        |
    |   +----+
    |   |
    +---+
    """
    all_points = []
    all_normals = []

    # L-shape dimensions
    main_width = 6.0
    main_depth = 5.0
    cutout_width = 3.0
    cutout_depth = 2.5

    # Floor
    # Main rectangle
    pts1, nrm1 = generate_plane_points(
        np.array([0, 0, 0]),
        np.array([0, 1, 0]),
        main_width, main_depth,
        2000
    )
    # Remove cutout region (approximate by keeping points outside cutout)
    mask = ~((pts1[:, 0] > main_width/2 - cutout_width) &
             (pts1[:, 2] > main_depth/2 - cutout_depth))
    all_points.append(pts1[mask])
    all_normals.append(nrm1[mask])
    print(f"Floor: {np.sum(mask)} points")

    # Ceiling
    pts1, nrm1 = generate_plane_points(
        np.array([0, room_height, 0]),
        np.array([0, -1, 0]),
        main_width, main_depth,
        2000
    )
    mask = ~((pts1[:, 0] > main_width/2 - cutout_width) &
             (pts1[:, 2] > main_depth/2 - cutout_depth))
    all_points.append(pts1[mask])
    all_normals.append(nrm1[mask])
    print(f"Ceiling: {np.sum(mask)} points")

    # Wall 1: Left (X-)
    pts, nrm = generate_plane_points(
        np.array([-main_width/2, room_height/2, 0]),
        np.array([1, 0, 0]),
        main_depth, room_height,
        wall_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (left): {len(pts)} points")

    # Wall 2: Bottom (Z-)
    pts, nrm = generate_plane_points(
        np.array([0, room_height/2, -main_depth/2]),
        np.array([0, 0, 1]),
        main_width, room_height,
        wall_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (bottom): {len(pts)} points")

    # Wall 3: Right-bottom (partial, X+)
    partial_depth = main_depth - cutout_depth
    pts, nrm = generate_plane_points(
        np.array([main_width/2, room_height/2, -main_depth/2 + partial_depth/2]),
        np.array([-1, 0, 0]),
        partial_depth, room_height,
        wall_density // 2
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (right-bottom): {len(pts)} points")

    # Wall 4: Inner horizontal (Z+, the step in the L)
    pts, nrm = generate_plane_points(
        np.array([main_width/2 - cutout_width/2, room_height/2, main_depth/2 - cutout_depth]),
        np.array([0, 0, -1]),
        cutout_width, room_height,
        wall_density // 2
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (inner horizontal): {len(pts)} points")

    # Wall 5: Inner vertical (X-, the step in the L)
    pts, nrm = generate_plane_points(
        np.array([main_width/2 - cutout_width, room_height/2, main_depth/2 - cutout_depth/2]),
        np.array([1, 0, 0]),
        cutout_depth, room_height,
        wall_density // 2
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (inner vertical): {len(pts)} points")

    # Wall 6: Top (Z+)
    pts, nrm = generate_plane_points(
        np.array([-main_width/2 + (main_width - cutout_width)/2, room_height/2, main_depth/2]),
        np.array([0, 0, -1]),
        main_width - cutout_width, room_height,
        wall_density
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Wall (top): {len(pts)} points")

    return np.vstack(all_points), np.vstack(all_normals)


def generate_angled_room(room_height: float = 2.7,
                         wall_density: int = 1500) -> tuple:
    """
    Generate a room with angled walls (pentagon shape).

    Not all walls at 90 degrees.
    """
    all_points = []
    all_normals = []

    # Pentagon-ish room corners (top view)
    # Angles: roughly 108° between walls (pentagon)
    corners = [
        np.array([-2.5, 0]),
        np.array([-3.0, 2.0]),
        np.array([0, 3.5]),
        np.array([3.0, 2.0]),
        np.array([2.5, 0]),
    ]

    # Floor
    center = np.mean(corners, axis=0)
    pts, nrm = generate_plane_points(
        np.array([center[0], 0, center[1]]),
        np.array([0, 1, 0]),
        7.0, 7.0,
        2500
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Floor: {len(pts)} points")

    # Ceiling
    pts, nrm = generate_plane_points(
        np.array([center[0], room_height, center[1]]),
        np.array([0, -1, 0]),
        7.0, 7.0,
        2500
    )
    all_points.append(pts)
    all_normals.append(nrm)
    print(f"Ceiling: {len(pts)} points")

    # Walls - connect consecutive corners
    for i in range(len(corners)):
        c1 = corners[i]
        c2 = corners[(i + 1) % len(corners)]

        # Wall center
        wall_center = (c1 + c2) / 2
        wall_length = np.linalg.norm(c2 - c1)

        # Wall direction and normal
        wall_dir = (c2 - c1) / wall_length
        # Normal points inward (perpendicular to wall, toward center)
        normal_2d = np.array([-wall_dir[1], wall_dir[0]])
        # Check if pointing toward center
        to_center = center - wall_center
        if np.dot(normal_2d, to_center) < 0:
            normal_2d = -normal_2d

        wall_normal = np.array([normal_2d[0], 0, normal_2d[1]])

        pts, nrm = generate_plane_points(
            np.array([wall_center[0], room_height/2, wall_center[1]]),
            wall_normal,
            wall_length, room_height,
            wall_density
        )
        all_points.append(pts)
        all_normals.append(nrm)

        angle = np.degrees(np.arctan2(wall_normal[2], wall_normal[0])) % 360
        print(f"Wall {i+1}: angle={angle:.1f}°, {len(pts)} points")

    return np.vstack(all_points), np.vstack(all_normals)


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Generate test room point clouds')
    parser.add_argument('output', nargs='?', default='test_room.ply', help='Output PLY file')
    parser.add_argument('--shape', choices=['rectangular', 'l-shaped', 'angled'],
                        default='rectangular', help='Room shape')
    parser.add_argument('--no-furniture', action='store_true', help='Skip furniture')

    args = parser.parse_args()

    print(f"Generating {args.shape} room point cloud...")
    print("=" * 40)

    if args.shape == 'rectangular':
        points, normals = generate_room(
            room_width=5.0,
            room_depth=4.0,
            room_height=2.7,
            add_furniture=not args.no_furniture
        )
    elif args.shape == 'l-shaped':
        points, normals = generate_l_shaped_room()
    elif args.shape == 'angled':
        points, normals = generate_angled_room()

    print("=" * 40)
    print(f"Total points: {len(points)}")

    save_ply(args.output, points, normals)

    print(f"\nTo test plane fitting:")
    print(f"  python plane_fitting.py {args.output}")
    print(f"  python plane_fitting_open3d.py {args.output} --visualize")


if __name__ == '__main__':
    main()
