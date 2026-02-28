import SwiftUI

/// Overlay for Test Mode - reticle, mic indicator, pause/go status
struct TestModeOverlayView: View {
    @ObservedObject var detector: TestModeDetector

    var body: some View {
        ZStack {
            // Reticle in CENTER - aligned with LiDAR
            TestModeReticle(
                hasCeiling: detector.ceilingPlane != nil,
                edgeCount: detector.edgeCount
            )

            VStack {
                // Top status bar
                HStack(spacing: 12) {
                    // Microphone indicator
                    MicrophoneIndicator(
                        isListening: detector.isListening,
                        isReceiving: detector.isReceivingAudio
                    )

                    // Status message
                    Text(detector.statusMessage)
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    // Pause/Go indicator
                    PauseGoIndicator(isPaused: detector.isPaused)
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
                            Text(String(format: "Y: %.2fm", ceiling.y))
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
                        Text("\(detector.wallCount)")
                            .fontWeight(.bold)
                    }

                    // Boundary points count
                    HStack {
                        Image(systemName: "line.diagonal")
                            .foregroundColor(.yellow)
                        Text("Boundary points")
                        Spacer()
                        Text("\(detector.edgeCount)")
                            .fontWeight(.bold)
                    }

                    // Detection method
                    if !detector.detectionMethod.isEmpty && detector.edgeCount > 0 {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundColor(.purple)
                            Text(detector.detectionMethod)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }

                    // Voice command hint
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundColor(.blue)
                        Text("Say \"Pause\" or \"Go\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
            // Outer ring - LARGER
            Circle()
                .stroke(reticleColor, lineWidth: 3)
                .frame(width: 180, height: 180)

            // Cross hairs - LARGER
            Rectangle()
                .fill(reticleColor)
                .frame(width: 60, height: 3)

            Rectangle()
                .fill(reticleColor)
                .frame(width: 3, height: 60)

            // Inner targeting area - LARGER
            RoundedRectangle(cornerRadius: 12)
                .stroke(reticleColor, lineWidth: 2)
                .frame(width: 120, height: 80)

            // Label
            VStack {
                Spacer()
                    .frame(height: 100)
                Text(labelText)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(reticleColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
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

// MARK: - Microphone Indicator

struct MicrophoneIndicator: View {
    let isListening: Bool
    let isReceiving: Bool

    var body: some View {
        ZStack {
            // Glow when receiving
            if isReceiving {
                Circle()
                    .fill(Color.green.opacity(0.4))
                    .frame(width: 44, height: 44)
            }

            Image(systemName: micIcon)
                .font(.title2)
                .foregroundColor(micColor)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .animation(.easeInOut(duration: 0.2), value: isReceiving)
    }

    private var micIcon: String {
        if !isListening {
            return "mic.slash"
        } else if isReceiving {
            return "mic.fill"
        } else {
            return "mic"
        }
    }

    private var micColor: Color {
        if !isListening {
            return .gray
        } else if isReceiving {
            return .green
        } else {
            return .white
        }
    }
}

// MARK: - Pause/Go Indicator

struct PauseGoIndicator: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isPaused ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)

            Text(isPaused ? "PAUSED" : "SCANNING")
                .font(.caption)
                .fontWeight(.bold)
        }
        .foregroundColor(isPaused ? .red : .green)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isPaused ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPaused ? Color.red : Color.green, lineWidth: 1)
        )
    }
}

#Preview {
    ZStack {
        Color.black
        TestModeOverlayView(detector: TestModeDetector())
    }
}
