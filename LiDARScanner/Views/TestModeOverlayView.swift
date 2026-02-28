import SwiftUI

/// Overlay for Test Mode - reticle and status
struct TestModeOverlayView: View {
    @ObservedObject var detector: TestModeDetector

    var body: some View {
        ZStack {
            // Reticle in center
            TestModeReticle(
                hasCeiling: detector.ceilingPlane != nil,
                edgeCount: detector.detectedEdges.count
            )

            VStack {
                // Top status bar
                HStack(spacing: 12) {
                    // Status message
                    Text(detector.statusMessage)
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    // Pause/Go button
                    Button(action: { detector.togglePause() }) {
                        HStack(spacing: 6) {
                            Image(systemName: detector.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                .font(.title2)
                            Text(detector.isPaused ? "GO" : "PAUSE")
                                .font(.caption)
                                .fontWeight(.bold)
                        }
                        .foregroundColor(detector.isPaused ? .green : .orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(detector.isPaused ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                        )
                    }
                }
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
                .padding(.horizontal)

                Spacer()

                // Bottom info panel
                VStack(spacing: 8) {
                    // Ceiling status
                    HStack {
                        Image(systemName: detector.ceilingPlane != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(detector.ceilingPlane != nil ? .green : .gray)
                        Text("Ceiling")
                        Spacer()
                        if let ceiling = detector.ceilingPlane {
                            Text(String(format: "Y: %.2fm", ceiling.center.y))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Wall count
                    HStack {
                        Image(systemName: "square.split.diagonal")
                            .foregroundColor(.cyan)
                        Text("Walls detected")
                        Spacer()
                        Text("\(detector.wallPlanes.count)")
                            .fontWeight(.bold)
                    }

                    // Edge count
                    HStack {
                        Image(systemName: "line.diagonal")
                            .foregroundColor(.yellow)
                        Text("Boundary edges")
                        Spacer()
                        Text("\(detector.detectedEdges.count)")
                            .fontWeight(.bold)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding()
            }
        }
    }
}

// MARK: - Reticle View

struct TestModeReticle: View {
    let hasCeiling: Bool
    let edgeCount: Int

    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(reticleColor, lineWidth: 2)
                .frame(width: 120, height: 120)

            // Cross hairs
            Rectangle()
                .fill(reticleColor)
                .frame(width: 40, height: 2)

            Rectangle()
                .fill(reticleColor)
                .frame(width: 2, height: 40)

            // Inner targeting area
            RoundedRectangle(cornerRadius: 8)
                .stroke(reticleColor, lineWidth: 1.5)
                .frame(width: 80, height: 50)

            // Label
            VStack {
                Spacer()
                    .frame(height: 70)
                Text(labelText)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(reticleColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
            }
        }
    }

    private var reticleColor: Color {
        if !hasCeiling {
            return .orange
        } else if edgeCount > 0 {
            return .green
        } else {
            return .cyan
        }
    }

    private var labelText: String {
        if !hasCeiling {
            return "FIND CEILING"
        } else if edgeCount == 0 {
            return "SCAN EDGES"
        } else {
            return "EDGES: \(edgeCount)"
        }
    }
}

#Preview {
    ZStack {
        Color.black
        TestModeOverlayView(detector: TestModeDetector())
    }
}
