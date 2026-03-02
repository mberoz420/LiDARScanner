"""Analyze floor point classification in labeling JSON"""
import json
import sys
from collections import Counter

def analyze_floor_classification(json_path):
    print(f"Loading {json_path}...")
    with open(json_path, 'r') as f:
        data = json.load(f)

    points = data['points']
    total_points = len(points)
    print(f"Total points: {total_points}")

    # Count labels
    label_counts = Counter(p['label'] for p in points)
    print(f"\nLabel distribution:")
    for label, count in sorted(label_counts.items(), key=lambda x: -x[1]):
        print(f"  {label}: {count} ({100*count/total_points:.1f}%)")

    # Get all Y values
    all_y = [p['y'] for p in points]
    min_y = min(all_y)
    max_y = max(all_y)
    print(f"\nY range: {min_y:.3f} to {max_y:.3f} (height: {max_y - min_y:.3f}m)")

    # Analyze floor points
    floor_points = [p for p in points if p['label'] == 'Floor']
    if not floor_points:
        print("\n*** BUG: No points labeled as 'Floor' ***")

        # Analyze lowest region anyway
        lowest_threshold = min_y + 0.15  # Bottom 15cm
        points_at_lowest = [p for p in points if p['y'] <= lowest_threshold]

        print(f"\n=== LOWEST REGION (Y <= {lowest_threshold:.2f}) - SHOULD BE FLOOR ===")
        print(f"Points at lowest: {len(points_at_lowest)}")

        if points_at_lowest:
            lowest_labels = Counter(p['label'] for p in points_at_lowest)
            print(f"Labels at lowest (WRONG - should be Floor):")
            for label, count in sorted(lowest_labels.items(), key=lambda x: -x[1]):
                print(f"  {label}: {count}")

            # Check normals
            upward = [p for p in points_at_lowest if p['ny'] > 0.5]
            print(f"\nUpward-facing points at lowest (definitely floor): {len(upward)}")
            if upward:
                upward_labels = Counter(p['label'] for p in upward)
                print(f"  Current labels of these points:")
                for label, count in sorted(upward_labels.items(), key=lambda x: -x[1]):
                    print(f"    {label}: {count}")

        # Find densest Y region
        print(f"\n=== Y-DENSITY ANALYSIS ===")
        num_bins = 30
        bin_size = (max_y - min_y) / num_bins
        bins = {}
        for p in points:
            bin_idx = int((p['y'] - min_y) / bin_size)
            bin_idx = min(bin_idx, num_bins - 1)
            if bin_idx not in bins:
                bins[bin_idx] = []
            bins[bin_idx].append(p)

        # Find densest bin
        densest_bin = max(bins.keys(), key=lambda k: len(bins[k]))
        densest_y = min_y + densest_bin * bin_size

        print(f"Densest region: Y = {densest_y:.2f} to {densest_y + bin_size:.2f}")
        print(f"Points in densest region: {len(bins[densest_bin])}")

        # Show histogram
        print(f"\nY distribution (full scan):")
        for i in sorted(bins.keys()):
            y_start = min_y + i * bin_size
            count = len(bins[i])
            bar = '#' * min(count // 50, 50)
            marker = " <-- FLOOR?" if i == 0 or i == 1 else ""
            marker = " <-- DENSEST" if i == densest_bin else marker
            print(f"  {y_start:+.2f}: {count:5d} {bar}{marker}")

        return

    floor_y = [p['y'] for p in floor_points]
    floor_min_y = min(floor_y)
    floor_max_y = max(floor_y)

    print(f"\n=== FLOOR CLASSIFICATION ANALYSIS ===")
    print(f"Floor points: {len(floor_points)}")
    print(f"Floor Y range: {floor_min_y:.3f} to {floor_max_y:.3f}")
    print(f"Floor Y spread: {floor_max_y - floor_min_y:.3f}m")

    # Check if floor points are scattered
    expected_floor_thickness = 0.05  # 5cm tolerance for actual floor
    actual_spread = floor_max_y - floor_min_y

    if actual_spread > expected_floor_thickness:
        print(f"\n*** BUG DETECTED ***")
        print(f"Floor points spread across {actual_spread:.3f}m vertically!")
        print(f"Expected: ~{expected_floor_thickness:.2f}m (flat floor)")

    # Y histogram for floor points
    print(f"\nFloor points Y distribution (histogram):")
    num_bins = 20
    bin_size = (max_y - min_y) / num_bins
    bins = [0] * num_bins
    for y in floor_y:
        bin_idx = min(int((y - min_y) / bin_size), num_bins - 1)
        bins[bin_idx] += 1

    for i, count in enumerate(bins):
        y_start = min_y + i * bin_size
        y_end = y_start + bin_size
        bar = '#' * min(count // 10, 50)
        if count > 0:
            print(f"  {y_start:+.2f} to {y_end:+.2f}: {count:5d} {bar}")

    # Find actual lowest region (where floor SHOULD be)
    lowest_threshold = min_y + 0.1  # Bottom 10cm
    points_at_lowest = [p for p in points if p['y'] <= lowest_threshold]
    floor_at_lowest = [p for p in floor_points if p['y'] <= lowest_threshold]

    print(f"\n=== LOWEST REGION ANALYSIS (Y <= {lowest_threshold:.2f}) ===")
    print(f"Total points at lowest: {len(points_at_lowest)}")
    print(f"Floor points at lowest: {len(floor_at_lowest)}")

    # What labels are at the lowest level?
    if points_at_lowest:
        lowest_labels = Counter(p['label'] for p in points_at_lowest)
        print(f"Labels at lowest level:")
        for label, count in sorted(lowest_labels.items(), key=lambda x: -x[1]):
            print(f"  {label}: {count}")

        # Check normals of lowest points
        print(f"\nNormals of lowest points (should be upward for floor):")
        upward_count = sum(1 for p in points_at_lowest if p['ny'] > 0.5)
        downward_count = sum(1 for p in points_at_lowest if p['ny'] < -0.5)
        horizontal_count = len(points_at_lowest) - upward_count - downward_count
        print(f"  Upward (ny > 0.5): {upward_count}")
        print(f"  Downward (ny < -0.5): {downward_count}")
        print(f"  Horizontal: {horizontal_count}")

    # Points above lowest that are wrongly classified as floor
    wrong_floor = [p for p in floor_points if p['y'] > lowest_threshold]
    print(f"\n=== MISCLASSIFIED FLOOR POINTS ===")
    print(f"Points labeled 'Floor' but NOT at lowest level: {len(wrong_floor)}")
    if wrong_floor:
        wrong_y = [p['y'] for p in wrong_floor]
        print(f"  Y range of misclassified: {min(wrong_y):.3f} to {max(wrong_y):.3f}")

        # Show some examples
        print(f"\n  Sample misclassified points:")
        for p in wrong_floor[:10]:
            print(f"    Y={p['y']:+.3f}, normal=({p['nx']:.2f}, {p['ny']:.2f}, {p['nz']:.2f})")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        json_path = r"G:\My Drive\LidarScans\labeling_74543234.json"
    else:
        json_path = sys.argv[1]

    analyze_floor_classification(json_path)
