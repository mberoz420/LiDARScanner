import Foundation
import ARKit
import simd
import CoreVideo
import UIKit

/// Projects camera image colors onto mesh vertices
class TextureProjector {

    /// Sample colors for vertices from camera frame
    static func sampleColors(
        for vertices: [SIMD3<Float>],
        meshTransform: simd_float4x4,
        frame: ARFrame
    ) -> [VertexColor] {

        let camera = frame.camera
        let imageResolution = camera.imageResolution
        let viewMatrix = camera.viewMatrix(for: .landscapeRight)
        let projectionMatrix = camera.projectionMatrix(for: .landscapeRight,
                                                        viewportSize: imageResolution,
                                                        zNear: 0.001,
                                                        zFar: 1000)

        // Get pixel buffer
        guard let pixelBuffer = getPixelBuffer(from: frame) else {
            return vertices.map { _ in VertexColor.white }
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return vertices.map { _ in VertexColor.white }
        }

        var colors: [VertexColor] = []
        colors.reserveCapacity(vertices.count)

        for vertex in vertices {
            // Transform vertex to world space
            let worldPos = meshTransform * SIMD4<Float>(vertex, 1)
            let worldPos3 = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)

            // Project to camera space
            let cameraPos = viewMatrix * SIMD4<Float>(worldPos3, 1)

            // Check if behind camera
            if cameraPos.z > 0 {
                colors.append(VertexColor.white)
                continue
            }

            // Project to screen
            let clipPos = projectionMatrix * cameraPos
            let ndcPos = SIMD2<Float>(clipPos.x / clipPos.w, clipPos.y / clipPos.w)

            // Convert to pixel coordinates
            let pixelX = Int((ndcPos.x + 1) * 0.5 * Float(width))
            let pixelY = Int((1 - ndcPos.y) * 0.5 * Float(height))

            // Sample color if in bounds
            if pixelX >= 0 && pixelX < width && pixelY >= 0 && pixelY < height {
                let color = samplePixel(
                    baseAddress: baseAddress,
                    bytesPerRow: bytesPerRow,
                    x: pixelX,
                    y: pixelY
                )
                colors.append(color)
            } else {
                colors.append(VertexColor.white)
            }
        }

        return colors
    }

    private static func getPixelBuffer(from frame: ARFrame) -> CVPixelBuffer? {
        return frame.capturedImage
    }

    private static func samplePixel(
        baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        x: Int,
        y: Int
    ) -> VertexColor {
        // ARFrame uses YCbCr format (420v or 420f)
        // For simplicity, we'll convert the Y component to grayscale
        // Full color requires YCbCr to RGB conversion

        let yPlane = baseAddress.assumingMemoryBound(to: UInt8.self)
        let yValue = yPlane[y * bytesPerRow + x]

        // Simple grayscale from Y component
        let intensity = Float(yValue) / 255.0

        return VertexColor(r: intensity, g: intensity, b: intensity)
    }

    /// Convert YCbCr to RGB (for full color support)
    static func sampleColorRGB(
        from pixelBuffer: CVPixelBuffer,
        x: Int,
        y: Int
    ) -> VertexColor? {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Handle different pixel formats
        if pixelFormat == kCVPixelFormatType_32BGRA {
            return sampleBGRA(from: pixelBuffer, x: x, y: y)
        } else {
            // YCbCr format - convert to RGB
            return sampleYCbCr(from: pixelBuffer, x: x, y: y)
        }
    }

    private static func sampleBGRA(
        from pixelBuffer: CVPixelBuffer,
        x: Int,
        y: Int
    ) -> VertexColor? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let offset = y * bytesPerRow + x * 4
        let pixel = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)

        let b = Float(pixel[0]) / 255.0
        let g = Float(pixel[1]) / 255.0
        let r = Float(pixel[2]) / 255.0

        return VertexColor(r: r, g: g, b: b)
    }

    private static func sampleYCbCr(
        from pixelBuffer: CVPixelBuffer,
        x: Int,
        y: Int
    ) -> VertexColor? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }

        // Get Y plane
        guard let yPlaneAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Get CbCr plane
        guard let cbcrPlaneAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let yValue = yPlaneAddress.advanced(by: y * yBytesPerRow + x).assumingMemoryBound(to: UInt8.self).pointee

        // CbCr is subsampled 2x2
        let cbcrX = x / 2
        let cbcrY = y / 2
        let cbcrOffset = cbcrY * cbcrBytesPerRow + cbcrX * 2
        let cbcrPixel = cbcrPlaneAddress.advanced(by: cbcrOffset).assumingMemoryBound(to: UInt8.self)
        let cbValue = cbcrPixel[0]
        let crValue = cbcrPixel[1]

        // YCbCr to RGB conversion (BT.601)
        let yF = Float(yValue)
        let cbF = Float(cbValue) - 128
        let crF = Float(crValue) - 128

        let r = yF + 1.402 * crF
        let g = yF - 0.344136 * cbF - 0.714136 * crF
        let b = yF + 1.772 * cbF

        return VertexColor(
            r: max(0, min(1, r / 255.0)),
            g: max(0, min(1, g / 255.0)),
            b: max(0, min(1, b / 255.0))
        )
    }
}
