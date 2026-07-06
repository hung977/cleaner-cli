import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Detector: reports the largest files under the given roots (specs/19). Read-only insight —
/// these are the user's own files, so they're 🔴 Dangerous, disposition `.skip`, and never
/// auto-cleaned. Runs via the `cleaner large-files` command, not the default scan.
public struct LargeFileFinder: CleanerPlugin {
    public let roots: [String]
    public let minBytes: Int64
    public let top: Int

    public init(roots: [String], minBytes: Int64 = 100 * 1024 * 1024, top: Int = 20) {
        self.roots = roots
        self.minBytes = minBytes
        self.top = top
    }

    public var metadata: PluginMetadata {
        .init(id: PluginID("dev.cleaner.detect.large-files"), name: "Large files",
              category: .largeFiles, defaultRisk: .dangerous, kind: .detector)
    }

    public func declaredRoots(_ context: PluginContext) -> [String] { roots }

    public func scan(_ context: PluginContext) async throws -> [Finding] {
        // Keep the top-N by allocated size with a bounded array (no whole-tree in memory).
        var kept: [(path: String, size: ByteCount)] = []
        var smallestKept: Int64 = 0
        for root in roots {
            if Task.isCancelled { break }
            context.fs.enumerateFiles(under: root) { path, allocated, _, _ in
                guard allocated.bytes >= minBytes else { return }
                if kept.count < top {
                    kept.append((path, allocated))
                    kept.sort { $0.size.bytes > $1.size.bytes }
                    smallestKept = kept.last?.size.bytes ?? 0
                } else if allocated.bytes > smallestKept {
                    kept[kept.count - 1] = (path, allocated)
                    kept.sort { $0.size.bytes > $1.size.bytes }
                    smallestKept = kept.last?.size.bytes ?? 0
                }
            }
        }
        return kept.map { entry in
            let name = (entry.path as NSString).lastPathComponent
            let item = Item(id: ItemID("large:" + entry.path), title: name, path: entry.path,
                            evidence: Evidence(allocatedSize: entry.size))
            return Finding(item: item, pluginID: metadata.id, category: .largeFiles,
                           safetyScore: SafetyScore(20), recoverability: .manual,
                           proposedDisposition: .skip,
                           rationale: "your file — review before removing")
        }
    }
}
