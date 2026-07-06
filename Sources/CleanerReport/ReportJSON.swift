import Foundation
import CleanerCore

/// Versioned, machine-readable JSON for `--json` (specs/08). The `schemaVersion` lets consumers
/// evolve safely. All sizes are reported as both raw bytes and a human string (truthful).
public enum ReportJSON {
    public static let schemaVersion = 1

    // MARK: DTOs

    public struct Size: Codable { public let bytes: Int64; public let human: String }
    static func size(_ b: ByteCount) -> Size { .init(bytes: b.bytes, human: b.formatted) }

    public struct FindingDTO: Codable {
        public let id: String
        public let title: String
        public let path: String
        public let plugin: String
        public let category: String
        public let risk: String
        public let recoverability: String
        public let reclaimable: Size
        public let rationale: String
    }

    public struct CategoryDTO: Codable {
        public let id: String
        public let name: String
        public let total: Size
        public let findings: [FindingDTO]
    }

    public struct SkippedDTO: Codable { public let plugin: String; public let reason: String }

    public struct AnalyzeReport: Codable {
        public let schemaVersion: Int
        public let command: String
        public let totalReclaimable: Size
        public let categories: [CategoryDTO]
        public let skipped: [SkippedDTO]
    }

    public struct OutcomeDTO: Codable {
        public let id: String
        public let path: String
        public let status: String
        public let reclaimed: Size
        public let detail: String?
    }

    public struct CleanReportDTO: Codable {
        public let schemaVersion: Int
        public let command: String
        public let dryRun: Bool
        public let session: String
        public let totalReclaimed: Size
        public let partial: Bool
        public let outcomes: [OutcomeDTO]
    }

    // MARK: Builders

    public static func analyze(_ result: ScanResult) -> AnalyzeReport {
        let cats = result.byCategory().map { group in
            CategoryDTO(
                id: group.category.id, name: group.category.displayName, total: size(group.total),
                findings: group.findings.map { f in
                    FindingDTO(id: f.item.id.rawValue, title: f.item.title, path: f.item.path,
                               plugin: f.pluginID.rawValue, category: f.category.id,
                               risk: f.risk.rawValue, recoverability: f.recoverability.rawValue,
                               reclaimable: size(f.reclaimableSize), rationale: f.rationale)
                })
        }
        return AnalyzeReport(schemaVersion: schemaVersion, command: "analyze",
                             totalReclaimable: size(result.totalReclaimable), categories: cats,
                             skipped: result.skipped.map { .init(plugin: $0.pluginID.rawValue, reason: $0.reason) })
    }

    public static func clean(_ report: CleanReport) -> CleanReportDTO {
        CleanReportDTO(
            schemaVersion: schemaVersion, command: "clean", dryRun: report.dryRun,
            session: report.sessionID.rawValue, totalReclaimed: size(report.totalReclaimed),
            partial: report.isPartial,
            outcomes: report.outcomes.map {
                .init(id: $0.itemID.rawValue, path: $0.path, status: $0.status.rawValue,
                      reclaimed: size($0.reclaimed), detail: $0.detail)
            })
    }

    /// Encode any report DTO to pretty, stable JSON.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(value), as: UTF8.self)
    }
}
