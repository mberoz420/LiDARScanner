import SwiftUI

/// Overlay for Test Mode - reticle at top, detected surfaces in middle/bottom
struct TestModeOverlayView: View {
    @ObservedObject var detector: TestModeDetector

    var body: some View {
        VStack(spacing: 0) {
            // TOP: Reticle area (close to top, behind LiDAR aperture)
            VStack {
                Spacer().frame(height: 80)

                // Clean midsize reticle
                ZStack {
                    Circle()
                        .stroke(reticleColor, lineWidth: 2)
                        .frame(width: 100, height: 100)

                    // Crosshairs
                    Rectangle()
                        .fill(reticleColor)
                        .frame(width: 30, height: 2)
                    Rectangle()
                        .fill(reticleColor)
                        .frame(width: 2, height: 30)

                    // Center dot
                    Circle()
                        .fill(reticleColor)
                        .frame(width: 8, height: 8)
                }

                // Instruction under reticle
                Text(instructionText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    .padding(.top, 12)

                Spacer().frame(height: 40)
            }

            // MIDDLE TO BOTTOM: Detected surfaces list
            VStack(spacing: 0) {
                // Last detected surface (flash notification)
                if !detector.lastDetectedSurface.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(detector.lastDetectedSurface)
                            .fontWeight(.bold)
                    }
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.green.opacity(0.3))
                    .cornerRadius(12)
                    .padding(.bottom, 8)
                }

                // Detected surfaces list
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(detector.detectedSurfaces) { surface in
                            HStack {
                                Image(systemName: surface.type == .ceiling ? "square.fill" : "rectangle.portrait.fill")
                                    .foregroundColor(surface.type == .ceiling ? .cyan : .orange)

                                Text(surface.label)
                                    .fontWeight(.semibold)

                                Spacer()

                                Text(String(format: "%.2fm", surface.height))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                        }

                        if detector.detectedSurfaces.isEmpty {
                            Text("Point reticle at ceiling, then each wall")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding()
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 300)
                .background(Color.black.opacity(0.7))
                .cornerRadius(16)
                .padding(.horizontal)

                // Bottom status
                HStack {
                    Text("Surfaces: \(detector.detectedSurfaces.count)")
                        .font(.caption)
                    Spacer()
                    if detector.isPaused {
                        Text("PAUSED")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.red)
                    }
                }
                .foregroundColor(.white)
                .padding()
            }
            .foregroundColor(.white)
        }
    }

    private var reticleColor: Color {
        if detector.ceilingPlane == nil {
            return .orange  // Looking for ceiling
        } else {
            return .cyan    // Looking for walls
        }
    }

    private var instructionText: String {
        if detector.ceilingPlane == nil {
            return "Point at CEILING"
        } else {
            return "Point at each WALL"
        }
    }
}

#Preview {
    ZStack {
        Color.black
        TestModeOverlayView(detector: TestModeDetector())
    }
}
