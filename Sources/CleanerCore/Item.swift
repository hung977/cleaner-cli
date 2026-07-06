import Foundation

/// The atomic unit a plugin reports and the engine acts on: a file, directory, or logical
/// group (Constitution glossary). Carries its path(s), size, and gathered evidence.
public struct Item: Sendable, Hashable, Codable, Identifiable {
    public let id: ItemID
    /// Human title, e.g. "DerivedData for MyApp".
    public let title: String
    /// The canonical filesystem path this item occupies (absolute).
    public let path: String
    /// Extra paths, if the item is a group spanning several locations.
    public let extraPaths: [String]
    public let evidence: Evidence

    public init(
        id: ItemID,
        title: String,
        path: String,
        extraPaths: [String] = [],
        evidence: Evidence
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.extraPaths = extraPaths
        self.evidence = evidence
    }

    /// All filesystem paths this item covers.
    public var allPaths: [String] { [path] + extraPaths }

    /// The truthful on-disk figure used for reclaim estimates (CC-10).
    public var reclaimableSize: ByteCount { evidence.allocatedSize }
}
