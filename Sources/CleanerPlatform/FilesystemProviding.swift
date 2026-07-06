import Foundation
import CleanerCore

/// The filesystem operations the engine and plugins depend on, behind a protocol so they can
/// be injected and tested against synthesized trees (specs/16, specs/31). Plugins receive this
/// through their context and never touch `FileManager` directly.
public protocol FilesystemProviding: Sendable {
    func exists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    func isSymlink(_ path: String) -> Bool

    /// Truthful measurement of a file or directory: on-disk allocated size, logical size,
    /// timestamps, file count, and filesystem-shape flags (specs/16). Never follows symlinks
    /// out of the item to measure their targets.
    func measure(_ path: String) throws -> Evidence

    /// Immediate children (absolute paths). Non-recursive. Does not descend symlinks.
    func children(of path: String) throws -> [String]

    /// Opaque per-volume identifier, used to decide rename-vs-copy for moves.
    func volumeID(of path: String) -> String?

    func createDirectory(_ path: String) throws
    func copyItem(from: String, to: String) throws
    func removeItem(_ path: String) throws

    /// Move `from` → `to`: an atomic rename on the same volume, else copy-verify-remove.
    func move(from: String, to: String) throws
}

/// Errors surfaced by the filesystem layer.
public enum FilesystemError: Error, CustomStringConvertible {
    case notFound(String)
    case notReadable(String)
    case moveFailed(from: String, to: String, underlying: String)

    public var description: String {
        switch self {
        case .notFound(let p): return "path not found: \(p)"
        case .notReadable(let p): return "path not readable: \(p)"
        case .moveFailed(let f, let t, let u): return "move \(f) → \(t) failed: \(u)"
        }
    }
}
