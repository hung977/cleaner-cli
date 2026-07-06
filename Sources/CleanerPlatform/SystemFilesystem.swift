import Foundation
import CleanerCore

/// Concrete `FilesystemProviding` backed by Foundation `FileManager` + `URLResourceValues`.
///
/// v0.1 uses `FileManager.enumerator` for directory sizing; `getattrlistbulk` is a documented
/// performance follow-up (research R1). Sizes use *allocated* keys for truthful reclaim (CC-10).
public struct SystemFilesystem: FilesystemProviding {
    private var fm: FileManager { .default }   // computed: keeps the struct Sendable
    public init() {}

    private static let measureKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .contentModificationDateKey, .contentAccessDateKey,
        .isUbiquitousItemKey,
    ]

    public func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func isSymlink(_ path: String) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
    }

    public func measure(_ path: String) throws -> Evidence {
        guard exists(path) else { throw FilesystemError.notFound(path) }
        let url = URL(fileURLWithPath: path)

        // A symlink is measured as itself (never chase the target for sizing/deletion).
        if isSymlink(path) {
            return Evidence(logicalSize: .zero, allocatedSize: .zero,
                            fileCount: 0, isSymlink: true)
        }

        let rv = try url.resourceValues(forKeys: Self.measureKeys)
        let dataless = rv.isUbiquitousItem == true   // conservative: treat iCloud items specially

        if rv.isDirectory == true {
            return try measureDirectory(url, modified: rv.contentModificationDate,
                                        accessed: rv.contentAccessDate, dataless: dataless)
        }

        // Single file.
        let alloc = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
        let logical = Int64(rv.fileSize ?? 0)
        return Evidence(
            logicalSize: ByteCount(logical),
            allocatedSize: ByteCount(alloc),
            modified: rv.contentModificationDate,
            accessed: rv.contentAccessDate,
            fileCount: 1,
            isSparse: alloc < logical,
            isDataless: dataless
        )
    }

    /// Stream a directory subtree summing allocated size with bounded memory (no in-RAM tree).
    private func measureDirectory(_ url: URL, modified: Date?, accessed: Date?,
                                  dataless: Bool) throws -> Evidence {
        var alloc: Int64 = 0
        var logical: Int64 = 0
        var files = 0
        var sawSparse = false

        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(Self.measureKeys),
                                     options: [], errorHandler: { _, _ in true }) else {
            throw FilesystemError.notReadable(url.path)
        }
        for case let child as URL in en {
            guard let crv = try? child.resourceValues(forKeys: Self.measureKeys) else { continue }
            if crv.isSymbolicLink == true { continue }        // don't chase symlinks
            if crv.isRegularFile == true {
                let a = Int64(crv.totalFileAllocatedSize ?? crv.fileAllocatedSize ?? 0)
                let l = Int64(crv.fileSize ?? 0)
                alloc += a
                logical += l
                files += 1
                if a < l { sawSparse = true }
            }
        }
        return Evidence(
            logicalSize: ByteCount(logical),
            allocatedSize: ByteCount(alloc),
            modified: modified,
            accessed: accessed,
            fileCount: files,
            isSparse: sawSparse,
            isDataless: dataless
        )
    }

    public func children(of path: String) throws -> [String] {
        guard exists(path) else { throw FilesystemError.notFound(path) }
        let names = try fm.contentsOfDirectory(atPath: path)
        return names.map { (path as NSString).appendingPathComponent($0) }.sorted()
    }

    public func volumeID(of path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let rv = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
        if let id = rv?.volumeIdentifier { return "\(id)" }
        return nil
    }

    public func createDirectory(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func copyItem(from: String, to: String) throws {
        try fm.copyItem(atPath: from, toPath: to)
    }

    public func removeItem(_ path: String) throws {
        try fm.removeItem(atPath: path)
    }

    public func move(from: String, to: String) throws {
        // Ensure destination parent exists.
        let parent = (to as NSString).deletingLastPathComponent
        try? createDirectory(parent)

        let sameVolume = volumeID(of: (from as NSString).deletingLastPathComponent)
            == volumeID(of: parent)

        do {
            if sameVolume {
                try fm.moveItem(atPath: from, toPath: to)   // atomic rename
            } else {
                // Cross-volume: copy, verify existence, then remove the source.
                try fm.copyItem(atPath: from, toPath: to)
                guard exists(to) else {
                    throw FilesystemError.moveFailed(from: from, to: to,
                                                     underlying: "copy did not materialize")
                }
                try fm.removeItem(atPath: from)
            }
        } catch let e as FilesystemError {
            throw e
        } catch {
            throw FilesystemError.moveFailed(from: from, to: to,
                                             underlying: error.localizedDescription)
        }
    }
}
