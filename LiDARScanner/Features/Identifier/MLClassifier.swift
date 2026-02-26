import Foundation
import Vision
import CoreML
import UIKit

/// ML-based object classification using Vision and Core ML
class MLClassifier {

    // MARK: - Classification Result

    struct Classification {
        let label: String
        let confidence: Float
        let relatedTerms: [String]
    }

    // MARK: - Configuration

    struct Configuration {
        var minConfidence: Float = 0.3
        var maxResults = 5
    }

    var configuration = Configuration()

    // MARK: - Custom Model (Optional)

    private var customModel: VNCoreMLModel?

    /// Load a custom Core ML model for object classification
    func loadCustomModel(at url: URL) throws {
        let compiledModel = try MLModel(contentsOf: url)
        customModel = try VNCoreMLModel(for: compiledModel)
    }

    // MARK: - Classification

    /// Classify an image and return results
    func classify(imageData: Data) async throws -> [Classification] {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw ClassificationError.invalidImage
        }

        // Use custom model if available, otherwise use built-in classification
        if let customModel = customModel {
            return try await classifyWithCustomModel(cgImage: cgImage, model: customModel)
        } else {
            return try await classifyWithVision(cgImage: cgImage)
        }
    }

    // MARK: - Vision Classification

    private func classifyWithVision(cgImage: CGImage) async throws -> [Classification] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { [weak self] request, error in
                guard let self = self else { return }

                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let classifications = observations
                    .filter { $0.confidence >= self.configuration.minConfidence }
                    .prefix(self.configuration.maxResults)
                    .map { observation in
                        Classification(
                            label: self.formatLabel(observation.identifier),
                            confidence: observation.confidence,
                            relatedTerms: self.generateRelatedTerms(for: observation.identifier)
                        )
                    }

                continuation.resume(returning: Array(classifications))
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Custom Model Classification

    private func classifyWithCustomModel(cgImage: CGImage, model: VNCoreMLModel) async throws -> [Classification] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { [weak self] request, error in
                guard let self = self else { return }

                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let classifications = observations
                    .filter { $0.confidence >= self.configuration.minConfidence }
                    .prefix(self.configuration.maxResults)
                    .map { observation in
                        Classification(
                            label: self.formatLabel(observation.identifier),
                            confidence: observation.confidence,
                            relatedTerms: self.generateRelatedTerms(for: observation.identifier)
                        )
                    }

                continuation.resume(returning: Array(classifications))
            }

            request.imageCropAndScaleOption = .centerCrop

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Object Detection

    /// Detect and classify objects in an image
    func detectObjects(imageData: Data) async throws -> [DetectedObject] {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw ClassificationError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeAnimalsRequest { request, error in
                // This is just an example - you'd use a custom model for general objects
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedObjectObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let detected = observations.compactMap { observation -> DetectedObject? in
                    guard let topLabel = observation.labels.first else { return nil }

                    return DetectedObject(
                        label: topLabel.identifier,
                        confidence: topLabel.confidence,
                        boundingBox: observation.boundingBox
                    )
                }

                continuation.resume(returning: detected)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Text Recognition

    /// Recognize text in image (useful for product labels)
    func recognizeText(imageData: Data) async throws -> [String] {
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw ClassificationError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let texts = observations.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }

                continuation.resume(returning: texts)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Helpers

    private func formatLabel(_ identifier: String) -> String {
        // Convert underscore-separated identifiers to readable format
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func generateRelatedTerms(for identifier: String) -> [String] {
        // Map common Vision identifiers to search terms
        let termMappings: [String: [String]] = [
            "screw": ["screw", "fastener", "hardware", "machine screw"],
            "bolt": ["bolt", "hex bolt", "fastener", "machine bolt"],
            "nail": ["nail", "fastener", "hardware"],
            "tool": ["tool", "hand tool", "equipment"],
            "gear": ["gear", "cog", "mechanical", "transmission"],
            "wheel": ["wheel", "pulley", "caster"],
            "pipe": ["pipe", "tube", "fitting", "plumbing"],
            "wire": ["wire", "cable", "electrical"],
            "connector": ["connector", "plug", "socket", "electrical"],
            "switch": ["switch", "electrical", "toggle"],
            "button": ["button", "switch", "control"],
            "knob": ["knob", "dial", "control"],
            "handle": ["handle", "grip", "lever"],
            "bracket": ["bracket", "mount", "support", "hardware"],
            "hinge": ["hinge", "pivot", "hardware"],
            "spring": ["spring", "coil", "mechanical"],
            "bearing": ["bearing", "bushing", "mechanical"],
            "motor": ["motor", "engine", "actuator", "electrical"],
            "pump": ["pump", "hydraulic", "mechanical"],
            "valve": ["valve", "fitting", "plumbing"]
        ]

        let lowercased = identifier.lowercased()

        for (key, terms) in termMappings {
            if lowercased.contains(key) {
                return terms
            }
        }

        // Default: use the identifier itself
        return [identifier.lowercased()]
    }
}

// MARK: - Supporting Types

struct DetectedObject {
    let label: String
    let confidence: Float
    let boundingBox: CGRect
}

enum ClassificationError: LocalizedError {
    case invalidImage
    case modelNotLoaded
    case classificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid image data provided."
        case .modelNotLoaded:
            return "ML model is not loaded."
        case .classificationFailed:
            return "Classification failed."
        }
    }
}
