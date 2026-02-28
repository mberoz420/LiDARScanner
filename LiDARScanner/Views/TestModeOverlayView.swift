import SwiftUI

/// Overlay for Test Mode - reticle, mic indicator, pause/go status
struct TestModeOverlayView: View {
    @ObservedObject var detector: TestModeDetector
    @State private var micBlink = false

    var body: some View {
        ZStack {
            // Reticle in center for targeting wall-ceiling intersection
            TestModeReticle(
                hasCeiling: detector.ceilingPlane != nil,
                edgeCount: detector.detectedEdges.count
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

                    // Voice command hints
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

            // Corner brackets
            ReticleCorners(color: reticleColor)

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
            return "EDGE \(edgeCount)"
        }
    }
}

struct ReticleCorners: View {
    let color: Color
    let size: CGFloat = 15
    let thickness: CGFloat = 2

    var body: some View {
        ZStack {
            // Top-left
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: size, height: thickness)
                    Spacer()
                }
                Rectangle().fill(color).frame(width: thickness, height: size - thickness)
                Spacer()
            }
            .frame(width: 60, height: 35)
            .offset(x: -30, y: -17)

            // Top-right
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(color).frame(width: size, height: thickness)
                }
                HStack {
                    Spacer()
                    Rectangle().fill(color).frame(width: thickness, height: size - thickness)
                }
                Spacer()
            }
            .frame(width: 60, height: 35)
            .offset(x: 30, y: -17)

            // Bottom-left
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(color).frame(width: thickness, height: size - thickness)
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: size, height: thickness)
                    Spacer()
                }
            }
            .frame(width: 60, height: 35)
            .offset(x: -30, y: 17)

            // Bottom-right
            VStack(spacing: 0) {
                Spacer()
                HStack {
                    Spacer()
                    Rectangle().fill(color).frame(width: thickness, height: size - thickness)
                }
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(color).frame(width: size, height: thickness)
                }
            }
            .frame(width: 60, height: 35)
            .offset(x: 30, y: 17)
        }
    }
}

// MARK: - Microphone Indicator

struct MicrophoneIndicator: View {
    let isListening: Bool
    let isReceiving: Bool

    var body: some View {
        ZStack {
            // Glow effect when receiving
            if isReceiving {
                Circle()
                    .fill(Color.green.opacity(0.4))
                    .frame(width: 44, height: 44)
            }

            Image(systemName: isListening ? "mic.fill" : "mic.slash")
                .font(.title2)
                .foregroundColor(micColor)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .animation(.easeInOut(duration: 0.2), value: isReceiving)
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
