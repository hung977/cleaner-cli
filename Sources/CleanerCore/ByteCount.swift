import Foundation

/// A count of bytes with truthful human formatting.
///
/// The domain distinguishes *logical* size from *allocated* (on-disk) size; reclaim
/// figures always use allocated size (Constitution III / CC-10). This type is just the
/// scalar; which figure it holds is decided by the field name at the call site.
public struct ByteCount: Sendable, Hashable, Comparable, Codable,
    ExpressibleByIntegerLiteral, AdditiveArithmetic {

    public var bytes: Int64

    public init(_ bytes: Int64) { self.bytes = max(0, bytes) }
    public init(integerLiteral value: Int64) { self.init(value) }

    public static let zero = ByteCount(0)

    public static func < (a: ByteCount, b: ByteCount) -> Bool { a.bytes < b.bytes }
    public static func + (a: ByteCount, b: ByteCount) -> ByteCount { ByteCount(a.bytes + b.bytes) }
    public static func - (a: ByteCount, b: ByteCount) -> ByteCount { ByteCount(a.bytes - b.bytes) }

    /// Base-2 (KiB/MiB/…) human string, e.g. "23.4 GB". Deterministic, locale-independent.
    public var formatted: String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[idx])
    }
}

public extension Sequence where Element == ByteCount {
    /// Total of a sequence of byte counts.
    func total() -> ByteCount { reduce(.zero, +) }
}
