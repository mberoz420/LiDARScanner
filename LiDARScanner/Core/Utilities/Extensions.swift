import Foundation
import SwiftUI
import simd

// MARK: - SIMD3 Extensions

extension SIMD3 where Scalar == Float {
    /// Human-readable string representation
    var description: String {
        String(format: "(%.2f, %.2f, %.2f)", x, y, z)
    }

    /// Convert to array
    var array: [Float] {
        [x, y, z]
    }
}

// MARK: - Color Extensions

extension Color {
    /// Create color from hex string
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - URL Extensions

extension URL {
    /// Safe file size
    var fileSize: Int64? {
        try? resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }
    }

    /// Check if URL points to a directory
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

// MARK: - Data Extensions

extension Data {
    /// Hex string representation
    var hexString: String {
        map { String(format: "%02hhx", $0) }.joined()
    }

    /// Create Data from hex string
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

// MARK: - Float Extensions

extension Float {
    /// Round to specified decimal places
    func rounded(to places: Int) -> Float {
        let divisor = pow(10.0, Float(places))
        return (self * divisor).rounded() / divisor
    }

    /// Convert radians to degrees
    var degrees: Float {
        self * 180 / .pi
    }

    /// Convert degrees to radians
    var radians: Float {
        self * .pi / 180
    }
}

// MARK: - Array Extensions

extension Array where Element == Float {
    /// Calculate mean
    var mean: Float {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Float(count)
    }

    /// Calculate standard deviation
    var standardDeviation: Float {
        guard count > 1 else { return 0 }
        let avg = mean
        let variance = reduce(0) { $0 + pow($1 - avg, 2) } / Float(count - 1)
        return sqrt(variance)
    }

    /// Normalize to 0-1 range
    var normalized: [Float] {
        guard let min = self.min(), let max = self.max(), max > min else {
            return self
        }
        let range = max - min
        return map { ($0 - min) / range }
    }
}

// MARK: - View Extensions

extension View {
    /// Apply conditional modifier
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Hide keyboard
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Date Extensions

extension Date {
    /// Relative time string (e.g., "2 hours ago")
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    /// ISO 8601 string
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }
}

// MARK: - String Extensions

extension String {
    /// Truncate string to max length
    func truncated(to maxLength: Int, trailing: String = "...") -> String {
        if count <= maxLength {
            return self
        }
        return String(prefix(maxLength - trailing.count)) + trailing
    }

    /// Check if string is valid email
    var isValidEmail: Bool {
        let regex = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return range(of: regex, options: .regularExpression) != nil
    }
}

// MARK: - Task Extensions

extension Task where Success == Never, Failure == Never {
    /// Sleep for specified seconds
    static func sleep(seconds: Double) async throws {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
