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
                    // Main reticle circle
                    Circle()
                        .stroke(reticleColor, lineWidth: 3)
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

                // What's in reticle + CAPTURE button
                VStack(spacing: 8) {
                    Text(detector.currentReticleSurface)
                        .font(.headline)
                        .foregroundColor(detector.currentReticleSurface.contains("detected") ? .green : .gray)

                    // BIG CAPTURE BUTTON
                    Button(action: {
                        detector.captureCurrentSurface()
                    }) {
                        HStack {
                            Image(systemName: "camera.fill")
                            Text("CAPTURE")
                                .fontWeight(.bold)
                        }
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                        .background(detector.currentReticleSurface.contains("detected") ? Color.blue : Color.gray)
                        .cornerRadius(25)
                    }
                    .disabled(!detector.currentReticleSurface.contains("detected"))
                }
                .padding(.top, 12)

                Spacer().frame(height: 20)
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
                            Text("Point reticle at ceiling/wall, tap CAPTURE")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding()
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 250)
                .background(Color.black.opacity(0.7))
                .cornerRadius(16)
                .padding(.horizontal)

                // Bottom status
                HStack {
                    Text("Surfaces: \(detector.detectedSurfaces.count)")
                        .font(.caption)
                    if !detector.planeIntersectionLines.isEmpty {
                        Text("| Lines: \(detector.planeIntersectionLines.count)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
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
        if detector.currentReticleSurface.contains("CEILING") {
            return .cyan
        } else if detector.currentReticleSurface.contains("WALL") {
            return .orange
        } else {
            return .white.opacity(0.5)
        }
    }
}

#Preview {
    ZStack {
        Color.black
        TestModeOverlayView(detector: TestModeDetector())
    }
}
