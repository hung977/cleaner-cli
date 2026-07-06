import Foundation
import CleanerCore
import CleanerPlatform

/// One quarantined item, with everything needed to restore it (specs/15, specs/21).
public struct StagedEntry: Sendable, Codable, Hashable {
    public let itemID: ItemID
    public let sessionID: SessionID
    public let originalPath: String
    public let stagedPath: String
    public let allocatedSize: ByteCount
    public let stagedAt: String        // ISO-8601, injected by the caller

    public init(itemID: ItemID, sessionID: SessionID, originalPath: String,
                stagedPath: String, allocatedSize: ByteCount, stagedAt: String) {
        self.itemID = itemID
        self.sessionID = sessionID
        self.originalPath = originalPath
        self.stagedPath = stagedPath
        self.allocatedSize = allocatedSize
        self.stagedAt = stagedAt
    }
}

/// Moves items into a session-scoped quarantine (`stage`) and restores or purges them
/// (`restore`/`purge`). Enables the reversibility principle (Constitution II). Single-writer:
/// one process owns `~/.cleaner/staging` at a time (v0.1 assumes no concurrent instances).
public struct StagingManager: Sendable {
    public let stagingRoot: String       // e.g. ~/.cleaner/staging
    private let fs: FilesystemProviding

    public init(stagingRoot: String, fs: FilesystemProviding) {
        self.stagingRoot = stagingRoot
        self.fs = fs
    }

    private func sessionDir(_ s: SessionID) -> String { stagingRoot + "/" + s.rawValue }
    private func payloadDir(_ s: SessionID) -> String { sessionDir(s) + "/payload" }
    private func manifestPath(_ s: SessionID) -> String { sessionDir(s) + "/manifest.ndjson" }

    // MARK: Stage

    /// Move `originalPath` into the session's quarantine and append a manifest line.
    /// Returns the recorded entry. The move is atomic on the same volume (specs/21).
    @discardableResult
    public func stage(itemID: ItemID, originalPath: String, size: ByteCount,
                      session: SessionID, timestamp: String) throws -> StagedEntry {
        try fs.createDirectory(payloadDir(session))
        // Keep the basename but namespace by itemID to avoid collisions.
        let base = (originalPath as NSString).lastPathComponent
        let staged = payloadDir(session) + "/" + itemID.rawValue + "__" + base
        try fs.move(from: originalPath, to: staged)

        let entry = StagedEntry(itemID: itemID, sessionID: session, originalPath: originalPath,
                                stagedPath: staged, allocatedSize: size, stagedAt: timestamp)
        try appendManifest(entry)
        return entry
    }

    private func appendManifest(_ entry: StagedEntry) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let line = try enc.encode(entry)
        var data = line
        data.append(0x0A)  // newline
        let path = manifestPath(entry.sessionID)
        if FileManager.default.fileExists(atPath: path) {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } else {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: Inspect

    public func listSessions() throws -> [SessionID] {
        guard fs.exists(stagingRoot) else { return [] }
        return try fs.children(of: stagingRoot)
            .filter { fs.isDirectory($0) }
            .map { SessionID(($0 as NSString).lastPathComponent) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    public func entries(session: SessionID) throws -> [StagedEntry] {
        let path = manifestPath(session)
        guard fs.exists(path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return raw.split(separator: "\n").compactMap { line in
            try? dec.decode(StagedEntry.self, from: Data(line.utf8))
        }
    }

    /// All staged entries across all sessions, newest session first.
    public func allEntries() throws -> [StagedEntry] {
        try listSessions().reversed().flatMap { try entries(session: $0) }
    }

    // MARK: Restore / purge

    public enum RestoreError: Error, CustomStringConvertible {
        case originalExists(String)
        case stagedMissing(String)
        public var description: String {
            switch self {
            case .originalExists(let p): return "cannot restore: original path already exists: \(p)"
            case .stagedMissing(let p): return "cannot restore: staged payload missing: \(p)"
            }
        }
    }

    /// Move a staged item back to its original location. Refuses to overwrite an existing path.
    public func restore(_ entry: StagedEntry) throws {
        guard fs.exists(entry.stagedPath) else { throw RestoreError.stagedMissing(entry.stagedPath) }
        guard !fs.exists(entry.originalPath) else { throw RestoreError.originalExists(entry.originalPath) }
        try fs.move(from: entry.stagedPath, to: entry.originalPath)
    }

    /// Restore every item in a session; returns (entry, error?) per item.
    public func restoreSession(_ session: SessionID) throws -> [(StagedEntry, Error?)] {
        try entries(session: session).map { entry in
            do { try restore(entry); return (entry, nil) }
            catch { return (entry, error) }
        }
    }

    /// Permanently delete a whole session's quarantine (irreversible).
    public func purge(session: SessionID) throws {
        let dir = sessionDir(session)
        if fs.exists(dir) { try fs.removeItem(dir) }
    }
}
