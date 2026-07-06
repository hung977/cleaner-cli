/// The outcome of a read-only scan: all findings plus per-plugin status (specs/17).
public struct ScanResult: Sendable, Codable {
    public var findings: [Finding]
    /// Plugins that failed or were skipped, with a reason (drives exit code 3/7).
    public var skipped: [SkippedPlugin]

    public init(findings: [Finding] = [], skipped: [SkippedPlugin] = []) {
        self.findings = findings
        self.skipped = skipped
    }

    public struct SkippedPlugin: Sendable, Codable, Hashable {
        public let pluginID: PluginID
        public let reason: String
        public init(pluginID: PluginID, reason: String) {
            self.pluginID = pluginID
            self.reason = reason
        }
    }

    /// Total truthful reclaimable size across all findings.
    public var totalReclaimable: ByteCount { findings.map(\.reclaimableSize).total() }

    /// Findings grouped by category, each subtotal descending by size.
    public func byCategory() -> [(category: FindingCategory, findings: [Finding], total: ByteCount)] {
        var buckets: [String: (FindingCategory, [Finding])] = [:]
        for f in findings {
            buckets[f.category.id, default: (f.category, [])].1.append(f)
        }
        return buckets.values
            .map { (cat, fs) in (cat, fs, fs.map(\.reclaimableSize).total()) }
            .sorted { $0.2 > $1.2 }
    }
}
