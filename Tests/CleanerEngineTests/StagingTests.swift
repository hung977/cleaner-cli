import Testing
import Foundation
@testable import CleanerEngine
import CleanerCore
import CleanerPlatform

@Suite("Engine: staging & rollback")
struct StagingTests {
    let fs = SystemFilesystem()

    private func sandbox() throws -> (root: String, staging: StagingManager) {
        let base = NSTemporaryDirectory() + "cleaner-stage-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return (base, StagingManager(stagingRoot: base + "/.cleaner/staging", fs: fs))
    }

    private func makeFile(_ path: String, bytes: Int = 2048) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x42, count: bytes))
    }

    @Test("stage moves the item out and records a manifest entry")
    func stageMoves() throws {
        let (root, staging) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let original = root + "/DerivedData/MyApp"
        try makeFile(original + "/build.o", bytes: 4096)

        let session = SessionID("sess-1")
        let entry = try staging.stage(itemID: ItemID("i1"), originalPath: original,
                                      size: ByteCount(4096), session: session, timestamp: "2026-07-06T00:00:00Z")

        #expect(!fs.exists(original))               // moved out
        #expect(fs.exists(entry.stagedPath))        // now in staging
        #expect(try staging.entries(session: session).count == 1)
    }

    @Test("restore returns the item byte-identical to its original location")
    func restoreRoundTrip() throws {
        let (root, staging) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let original = root + "/cache/blob.bin"
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        try FileManager.default.createDirectory(atPath: (original as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: original, contents: payload)

        let session = SessionID("sess-2")
        let entry = try staging.stage(itemID: ItemID("i1"), originalPath: original,
                                      size: ByteCount(5000), session: session, timestamp: "t")
        #expect(!fs.exists(original))
        try staging.restore(entry)
        #expect(fs.exists(original))
        #expect(try Data(contentsOf: URL(fileURLWithPath: original)) == payload) // byte-identical
    }

    @Test("restore refuses to overwrite an existing original")
    func restoreConflict() throws {
        let (root, staging) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let original = root + "/x/f.txt"
        try makeFile(original)
        let entry = try staging.stage(itemID: ItemID("i1"), originalPath: original,
                                      size: ByteCount(2048), session: SessionID("s"), timestamp: "t")
        try makeFile(original)   // something re-created the original
        #expect(throws: StagingManager.RestoreError.self) { try staging.restore(entry) }
    }

    @Test("purge permanently removes a session's quarantine")
    func purge() throws {
        let (root, staging) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let original = root + "/y/f.txt"
        try makeFile(original)
        let session = SessionID("s3")
        _ = try staging.stage(itemID: ItemID("i1"), originalPath: original,
                              size: ByteCount(2048), session: session, timestamp: "t")
        try staging.purge(session: session)
        #expect(try staging.entries(session: session).isEmpty)
    }

    @Test("audit log appends NDJSON events in order")
    func auditAppends() throws {
        let (root, _) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let log = AuditLog(path: root + "/.cleaner/logs/audit/2026-07-06.ndjson")
        try log.record(AuditEvent(ts: "t1", session: SessionID("s"), action: "stage", path: "/a"))
        try log.record(AuditEvent(ts: "t2", session: SessionID("s"), action: "restore", path: "/a"))
        let events = try log.readAll()
        #expect(events.count == 2)
        #expect(events.first?.action == "stage")
        #expect(events.last?.action == "restore")
    }
}
