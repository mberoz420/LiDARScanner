import SwiftUI

/// Overlay view showing Trial 1 ceiling detection results
struct Trial1OverlayView: View {
    @ObservedObject var detector: Trial1Detector
    let floorHeight: Float?

    var body: some View {
        VStack {
            // Top: Ceiling height display
            VStack(spacing: 8) {
                // Real-time distance when pointing up
                if detector.isPointingAtCeiling {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.green)
                        if let distance = detector.distanceToTarget {
                            Text(String(format: "Distance: %.2f m", distance))
                                .font(.title2)
                                .fontWeight(.bold)
                        } else {
                            Text("Measuring...")
                                .font(.title2)
                        }
                    }
                    .padding()
                    .background(Color.green.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }

                // Calculated ceiling height
                if let ceilingH = detector.ceilingHeight {
                    CeilingHeightDisplay(
                        ceilingHeight: ceilingH,
                        floorHeight: floorHeight
                    )
                }

                // Instruction when not pointing up
                if !detector.isPointingAtCeiling && detector.ceilingHeight == nil {
                    HStack {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                        Text("Point device UP to measure ceiling")
                    }
                    .padding()
                    .background(Color.blue.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }

            Spacer()

            // Bottom: Wall count from ceiling edges
            if !detector.wallCeilingEdges.isEmpty {
                HStack {
                    Image(systemName: "square.split.diagonal")
                    Text("\(detector.wallCeilingEdges.count) wall-ceiling edges detected")
                }
                .padding()
                .background(Color.black.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding()
    }
}

/// Helper view for displaying ceiling height
private struct CeilingHeightDisplay: View {
    let ceilingHeight: Float
    let floorHeight: Float?

    private var roomHeight: Float {
        if let floor = floorHeight {
            return ceilingHeight - floor
        }
        return ceilingHeight
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack {
                Text(String(format: "%.2f m", roomHeight))
                    .font(.title)
                    .fontWeight(.bold)
                Text("Room Height")
                    .font(.caption)
            }

            if floorHeight != nil {
                Divider().frame(height: 30)
                VStack {
                    Text(String(format: "%.2f m", ceilingHeight))
                        .font(.headline)
                    Text("Ceiling Y")
                        .font(.caption2)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .foregroundColor(.white)
        .cornerRadius(12)
    }
}
