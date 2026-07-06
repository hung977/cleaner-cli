import Foundation
import CleanerCore

/// One append-only record of a filesystem mutation (Constitution principle V, specs/28).
public struct AuditEvent: Sendable, Codable, Hashable {
    public let ts: String            // ISO-8601, injected
    public let session: SessionID
    public let action: String        // "stage" | "restore" | "purge" | "skip" | "block"
    public let path: String
    public let detail: String?

    public init(ts: String, session: SessionID, action: String,
                path: String, detail: String? = nil) {
        self.ts = ts
        self.session = session
        self.action = action
        self.path = path
        self.detail = detail
    }
}

/// Append-only NDJSON audit trail. Every mutation the engine performs is recorded so a run is
/// explainable after the fact ("why did you delete this?" always has an answer).
public struct AuditLog: Sendable {
    public let path: String          // e.g. ~/.cleaner/logs/audit/<date>.ndjson

    public init(path: String) { self.path = path }

    public func record(_ event: AuditEvent) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var data = try enc.encode(event)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: path) {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } else {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Read back all recorded events (for tooling/tests).
    public func readAll() throws -> [AuditEvent] {
        guard FileManager.default.fileExists(atPath: path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return raw.split(separator: "\n").compactMap { try? dec.decode(AuditEvent.self, from: Data($0.utf8)) }
    }
}
