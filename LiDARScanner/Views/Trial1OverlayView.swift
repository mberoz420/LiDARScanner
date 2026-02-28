import SwiftUI

/// Overlay view for Trial 1 ceiling boundary scanning
struct Trial1OverlayView: View {
    @ObservedObject var detector: Trial1Detector

    var body: some View {
        VStack {
            // Top: Phase indicator and instructions
            VStack(spacing: 8) {
                // Phase badge
                HStack {
                    Image(systemName: detector.phase.icon)
                    Text(detector.phase.rawValue)
                        .fontWeight(.bold)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(phaseColor.opacity(0.9))
                .foregroundColor(.white)
                .cornerRadius(20)

                // Instruction
                Text(detector.phase.instruction)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)

                // Progress info based on phase
                phaseProgressView
            }
            .padding(.top, 60)

            Spacer()

            // Bottom: Measurements and controls
            VStack(spacing: 12) {
                // Measurements display
                if detector.ceilingHeight != nil || detector.floorHeight != nil || detector.roomHeight != nil {
                    measurementsView
                }

                // Next button when ready to advance
                if canAdvancePhase {
                    Button(action: { detector.nextPhase() }) {
                        HStack {
                            Text(nextButtonText)
                                .fontWeight(.semibold)
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
            }
            .padding(.bottom, 120)
        }
        .padding()
    }

    // MARK: - Phase Progress View

    @ViewBuilder
    private var phaseProgressView: some View {
        switch detector.phase {
        case .ready:
            EmptyView()

        case .scanningCeilingBoundary:
            VStack(spacing: 4) {
                Text("\(detector.ceilingBoundaryPoints.count) boundary points")
                    .font(.title2)
                    .fontWeight(.bold)

                if detector.ceilingBoundaryPoints.count < 3 {
                    Text("Need at least 3 points")
                        .font(.caption)
                        .foregroundColor(.yellow)
                } else {
                    Text("Tap Next when boundary complete")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding()
            .background(Color.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(8)

        case .measuringFloor:
            VStack(spacing: 4) {
                if detector.isPointingAtFloor {
                    if let distance = detector.distanceToFloor {
                        Text(String(format: "Floor: %.2f m away", distance))
                            .font(.title2)
                            .fontWeight(.bold)
                    }
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title)
                } else {
                    Text("Point device DOWN")
                        .font(.title2)
                    Image(systemName: "arrow.down")
                        .font(.largeTitle)
                }
            }
            .padding()
            .background(detector.isPointingAtFloor ? Color.green.opacity(0.8) : Color.blue.opacity(0.8))
            .foregroundColor(.white)
            .cornerRadius(12)

        case .complete:
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.green)
                Text("Walls Generated!")
                    .font(.headline)

                if let mesh = detector.generatedWallMesh {
                    Text("\(mesh.vertices.count) vertices, \(mesh.faces.count) faces")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .padding()
            .background(Color.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(12)
        }
    }

    // MARK: - Measurements View

    private var measurementsView: some View {
        HStack(spacing: 20) {
            if let ceiling = detector.ceilingHeight {
                VStack {
                    Text(String(format: "%.2f m", ceiling))
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("Ceiling")
                        .font(.caption2)
                }
            }

            if let floor = detector.floorHeight {
                VStack {
                    Text(String(format: "%.2f m", floor))
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("Floor")
                        .font(.caption2)
                }
            }

            if let height = detector.roomHeight {
                VStack {
                    Text(String(format: "%.2f m", height))
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Room Height")
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.3))
                .cornerRadius(6)
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .foregroundColor(.white)
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private var phaseColor: Color {
        switch detector.phase {
        case .ready: return .gray
        case .scanningCeilingBoundary: return .cyan
        case .measuringFloor: return .blue
        case .complete: return .green
        }
    }

    private var canAdvancePhase: Bool {
        switch detector.phase {
        case .ready:
            return false
        case .scanningCeilingBoundary:
            return detector.ceilingBoundaryPoints.count >= 3
        case .measuringFloor:
            return detector.floorHeight != nil && detector.ceilingHeight != nil
        case .complete:
            return false
        }
    }

    private var nextButtonText: String {
        switch detector.phase {
        case .scanningCeilingBoundary:
            return "Next: Measure Floor"
        case .measuringFloor:
            return "Generate Walls"
        default:
            return "Next"
        }
    }
}
