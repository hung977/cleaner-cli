import Foundation

/// A stable identifier for one plugin.
public struct PluginID: Sendable, Hashable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ s: String) { self.rawValue = s }
    public var description: String { rawValue }
}

/// A run of the tool from start to exit.
public struct SessionID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Deterministic-friendly: callers pass a UUID string (injected, not generated here,
    /// so CleanerCore stays free of clock/entropy for testability).
    public init(_ s: String) { self.rawValue = s }
    public var description: String { rawValue }
}

/// A single item's identity within a session (short, human-typable for `staging restore`).
public struct ItemID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ s: String) { self.rawValue = s }
    public var description: String { rawValue }
}
