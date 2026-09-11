// Measurement.swift — what a framework costs, broken down so the number is
// actionable rather than just alarming.
//
// "How much will your SDK add to my app?" is the first question every vendor
// gets and the one nobody answers well. The honest answer has structure, so
// this reports segments rather than a single total:
//
//   __TEXT      executable code and read-only data. The part that actually
//               grows when you add features, and the part that survives into
//               the shipped app essentially unchanged.
//   __DATA      mutable data, including Objective-C metadata. Grows fast with
//               class count and dynamic dispatch.
//   __LINKEDIT  symbol tables, bind opcodes, code signature. Large on a debug
//               build, much smaller after stripping, and NOT a good proxy for
//               what a customer ships.
//
// That last point is why a single file-size number misleads: an unstripped
// debug slice can be several times its release size, almost entirely in
// __LINKEDIT, and reporting that as "your SDK is 8 MB" is wrong in a way that
// erodes trust in the whole measurement.
//
// This reports every segment separately and flags __LINKEDIT as excluded from
// the headline figure.

import Foundation

public struct SegmentSize: Sendable, Codable, Hashable {
    public let name: String
    public let fileSize: UInt64
    public let vmSize: UInt64

    public init(name: String, fileSize: UInt64, vmSize: UInt64) {
        self.name = name
        self.fileSize = fileSize
        self.vmSize = vmSize
    }
}

public struct SliceSize: Sendable, Codable {
    public let architecture: String
    public let segments: [SegmentSize]

    public init(architecture: String, segments: [SegmentSize]) {
        self.architecture = architecture
        self.segments = segments
    }

    public func segment(_ name: String) -> UInt64 {
        segments.first { $0.name == name }?.fileSize ?? 0
    }

    /// Everything except __LINKEDIT. This is the headline number: it is what
    /// survives stripping and is stable enough to budget against.
    public var shippedBytes: UInt64 {
        segments.filter { $0.name != "__LINKEDIT" }.reduce(0) { $0 + $1.fileSize }
    }

    public var totalBytes: UInt64 {
        segments.reduce(0) { $0 + $1.fileSize }
    }
}

public struct SizeReport: Sendable, Codable {
    public let name: String
    /// Total bytes on disk, including resources and every architecture.
    public let onDiskBytes: UInt64
    public let slices: [SliceSize]
    /// Non-binary bundle contents: nibs, asset catalogs, localisations.
    public let resourceBytes: UInt64
    public let generatedAt: String

    public init(name: String, onDiskBytes: UInt64, slices: [SliceSize],
                resourceBytes: UInt64, generatedAt: String = Self.timestamp()) {
        self.name = name
        self.onDiskBytes = onDiskBytes
        self.slices = slices
        self.resourceBytes = resourceBytes
        self.generatedAt = generatedAt
    }

    /// The number to budget against: the largest single architecture's
    /// shipped bytes, plus resources.
    ///
    /// Largest-single-architecture rather than the sum, because App Store
    /// thinning delivers one slice to each device. Summing every slice of a
    /// universal binary would roughly double the figure a customer actually
    /// pays, which is the second-most-common way these numbers mislead.
    public var budgetBytes: UInt64 {
        (slices.map(\.shippedBytes).max() ?? 0) + resourceBytes
    }

    public static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }
}

// MARK: - Formatting

public enum ByteFormat {
    /// Binary units, because that is what Xcode and the App Store report.
    public static func human(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }

    public static func delta(_ bytes: Int64) -> String {
        let sign = bytes > 0 ? "+" : (bytes < 0 ? "−" : "±")
        return "\(sign)\(human(UInt64(abs(bytes))))"
    }

    /// Parse a budget like "500KB", "1.5MB", "250000".
    public static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let multipliers: [(String, UInt64)] = [
            ("GB", 1024 * 1024 * 1024), ("MB", 1024 * 1024), ("KB", 1024), ("B", 1),
        ]
        for (suffix, multiplier) in multipliers where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number) else { return nil }
            return UInt64(value * Double(multiplier))
        }
        return UInt64(trimmed)
    }
}
