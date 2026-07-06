import Foundation

/// The metadata a plugin gathered to justify a finding (Constitution glossary, specs/14 §Evidence).
/// v0.1 subset — richer signals (Spotlight kind, whereFroms, Launch Services) arrive later.
///
/// `date`s are injected from the filesystem layer; CleanerCore never reads the clock.
public struct Evidence: Sendable, Hashable, Codable {
    /// Logical size (sum of file lengths).
    public var logicalSize: ByteCount
    /// On-disk allocated size — the truthful reclaim figure (CC-10).
    public var allocatedSize: ByteCount
    /// Last modification time, if known.
    public var modified: Date?
    /// Last access time, if known.
    public var accessed: Date?
    /// Number of regular files contained (1 for a single file).
    public var fileCount: Int

    // Filesystem-shape flags that affect safety & reclaim accounting.
    public var isSymlink: Bool
    public var isClone: Bool      // APFS clone — shared blocks; reclaim may be < allocatedSize
    public var isSparse: Bool
    public var isDataless: Bool   // iCloud placeholder — MUST NOT trigger download or delete

    public init(
        logicalSize: ByteCount = .zero,
        allocatedSize: ByteCount = .zero,
        modified: Date? = nil,
        accessed: Date? = nil,
        fileCount: Int = 0,
        isSymlink: Bool = false,
        isClone: Bool = false,
        isSparse: Bool = false,
        isDataless: Bool = false
    ) {
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.accessed = accessed
        self.fileCount = fileCount
        self.isSymlink = isSymlink
        self.isClone = isClone
        self.isSparse = isSparse
        self.isDataless = isDataless
    }
}
