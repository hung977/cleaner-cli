import Foundation
import CryptoKit
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Detector: finds groups of byte-identical files under the given roots (specs/19). Multi-stage:
/// bucket by logical size → confirm with SHA-256 (only files whose size collides are hashed) →
/// group by digest. Hardlinks (same inode) are collapsed, not counted as duplicates. Read-only
/// insight — user files, so 🔴 Dangerous, `.skip`, never auto-cleaned. Runs via `cleaner duplicates`.
public struct DuplicateFinder: CleanerPlugin {
    public let roots: [String]
    public let minBytes: Int64

    public init(roots: [String], minBytes: Int64 = 1024 * 1024) {
        self.roots = roots
        self.minBytes = minBytes
    }

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.detect.duplicates"), name: "Duplicate files",
              category: .duplicates, defaultRisk: .dangerous, kind: .detector)
    }

    public func declaredRoots(_ context: PluginContext) -> [String] { roots }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        // Stage 1 — bucket by logical size, skipping hardlinks (same inode counted once).
        var bySize: [Int64: [String]] = [:]
        var seen = Set<FileIdentity>()
        for root in roots {
            if Task.isCancelled { break }
            context.fs.enumerateFiles(under: root) { path, _, logical, id in
                guard logical.bytes >= minBytes else { return }
                if seen.contains(id) { return }
                seen.insert(id)
                bySize[logical.bytes, default: []].append(path)
            }
        }

        // Stage 2 — hash only size-colliding files; group identical digests.
        var findings: [Finding] = []
        for (size, paths) in bySize where paths.count >= 2 {
            if Task.isCancelled { break }
            var byHash: [String: [String]] = [:]
            for p in paths {
                guard let h = Self.sha256(of: p) else { continue }
                byHash[h, default: []].append(p)
            }
            for (_, group) in byHash where group.count >= 2 {
                let sorted = group.sorted()
                let name = (sorted[0] as NSString).lastPathComponent
                let reclaim = ByteCount(size * Int64(group.count - 1))
                let item = Item(id: ItemID("dup:" + sorted[0]),
                                title: "\(name)  ×\(group.count)", path: sorted[0],
                                extraPaths: Array(sorted.dropFirst()),
                                evidence: Evidence(allocatedSize: reclaim))
                findings.append(Finding(item: item, pluginID: metadata.id, category: .duplicates,
                                        safetyScore: SafetyScore(20), recoverability: .manual,
                                        proposedDisposition: .skip,
                                        rationale: "\(group.count) identical copies — keep one"))
            }
        }
        return findings.sorted { $0.reclaimableSize.bytes > $1.reclaimableSize.bytes }
    }

    /// Streaming SHA-256 so large files don't load fully into memory.
    static func sha256(of path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = try? fh.read(upToCount: 1 << 20)   // 1 MiB
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
