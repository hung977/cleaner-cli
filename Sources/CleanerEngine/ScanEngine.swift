import Foundation
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

/// Orchestrates plugins' read-only scans into a single `ScanResult` (specs/17).
///
/// v0.1: runs plugins concurrently with a `TaskGroup`, isolates failures (a throwing plugin
/// becomes a `skipped` entry, not a crash), and pre-filters any finding whose path the
/// ProtectedPathGuard would refuse — so a protected item is never even shown. Cooperative
/// cancellation is honored between plugins.
public struct ScanEngine: Sendable {
    private let guard_: ProtectedPathGuard
    public init(guard_: ProtectedPathGuard) { self.guard_ = guard_ }

    /// - Parameters:
    ///   - progress: called after each plugin finishes with (done, total, bytesFoundSoFar).
    ///   - onUpdate: called after each plugin finishes with the accumulated, sorted partial
    ///     result and (done, total) — lets the CLI redraw a live, growing chart.
    public func scan(plugins: [any CleanerPlugin], context: PluginContext,
                     progress: (@Sendable (Int, Int, ByteCount) -> Void)? = nil,
                     onUpdate: (@Sendable (ScanResult, Int, Int) -> Void)? = nil) async -> ScanResult {
        let total = plugins.count
        return await withTaskGroup(of: PluginScan.self) { group in
            for plugin in plugins {
                group.addTask {
                    if Task.isCancelled { return .cancelled(plugin.metadata.id) }
                    do {
                        let roots = plugin.declaredRoots(context)
                        let raw = try await plugin.scan(context)
                        // Defense in depth: drop anything the guard would block at cleanup time.
                        let safe = raw.filter { finding in
                            finding.item.allPaths.allSatisfy {
                                guard_.validateForDeletion($0, allowedRoots: roots).isAllowed
                            }
                        }
                        return .ok(safe)
                    } catch {
                        return .failed(plugin.metadata.id, "\(error)")
                    }
                }
            }

            var result = ScanResult()
            var done = 0
            for await scan in group {
                switch scan {
                case .ok(let findings):
                    result.findings.append(contentsOf: findings)
                case .failed(let id, let reason):
                    result.skipped.append(.init(pluginID: id, reason: reason))
                case .cancelled(let id):
                    result.skipped.append(.init(pluginID: id, reason: "cancelled"))
                }
                done += 1
                Self.sortFindings(&result.findings)
                progress?(done, total, result.findings.map(\.reclaimableSize).total())
                onUpdate?(result, done, total)
            }
            return result
        }
    }

    /// Deterministic ordering: largest reclaim first, then by id for ties.
    static func sortFindings(_ findings: inout [Finding]) {
        findings.sort {
            if $0.reclaimableSize != $1.reclaimableSize {
                return $0.reclaimableSize > $1.reclaimableSize
            }
            return $0.item.id.rawValue < $1.item.id.rawValue
        }
    }

    private enum PluginScan: Sendable {
        case ok([Finding])
        case failed(PluginID, String)
        case cancelled(PluginID)
    }
}
