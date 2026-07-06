import Testing
import Foundation
@testable import CleanerPlugins
import CleanerCore
import CleanerPlatform
import CleanerPluginAPI

@Suite("Detectors: large files & duplicates")
struct DetectorTests {
    let fs = SystemFilesystem()

    private func sandbox() throws -> (base: String, ctx: PluginContext) {
        let base = NSTemporaryDirectory() + "cleaner-detect-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return (base, PluginContext(fs: fs, home: base, now: Date(timeIntervalSince1970: 0)))
    }
    private func write(_ path: String, bytes: Int, fill: UInt8 = 0xAB) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(repeating: fill, count: bytes))
    }

    @Test("large-files: returns files ≥ threshold, top-N, as dangerous/skip")
    func largeFiles() async throws {
        let (base, ctx) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: base) }
        write(base + "/big.bin", bytes: 3_000_000)
        write(base + "/mid.bin", bytes: 1_500_000)
        write(base + "/small.bin", bytes: 100)   // below threshold
        let finder = LargeFileFinder(roots: [base], minBytes: 1_000_000, top: 10)
        let findings = try await finder.scan(ctx)
        #expect(findings.count == 2)                            // small.bin excluded
        #expect(findings.first?.item.title == "big.bin")        // sorted desc
        #expect(findings.allSatisfy { $0.risk == .dangerous && $0.proposedDisposition == .skip })
        #expect(finder.metadata.kind == .detector)
    }

    @Test("large-files: top-N caps the result count")
    func topN() async throws {
        let (base, ctx) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: base) }
        for i in 0..<5 { write(base + "/f\(i).bin", bytes: 1_000_000 + i * 1000) }
        let findings = try await LargeFileFinder(roots: [base], minBytes: 500_000, top: 3).scan(ctx)
        #expect(findings.count == 3)
        #expect(findings.first!.reclaimableSize >= findings.last!.reclaimableSize)
    }

    @Test("duplicates: finds identical files, ignores unique, counts group size")
    func duplicates() async throws {
        let (base, ctx) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let payload = Data((0..<2_000_000).map { UInt8($0 % 251) })
        for p in ["a/dup.bin", "b/dup.bin", "c/dup.bin"] {
            try? FileManager.default.createDirectory(atPath: base + "/" + (p as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: base + "/" + p, contents: payload)
        }
        write(base + "/unique.bin", bytes: 2_000_000, fill: 0x11)   // same size, different content
        let findings = try await DuplicateFinder(roots: [base], minBytes: 1_000_000).scan(ctx)
        #expect(findings.count == 1)                               // one duplicate group
        let g = try #require(findings.first)
        #expect(g.item.allPaths.count == 3)                        // three copies
        #expect(g.reclaimableSize.bytes == 2_000_000 * 2)          // free 2 of 3
        #expect(g.risk == .dangerous && g.proposedDisposition == .skip)
    }

    @Test("duplicates: hardlinks are collapsed, not reported as duplicates")
    func hardlinksIgnored() async throws {
        let (base, ctx) = try sandbox()
        defer { try? FileManager.default.removeItem(atPath: base) }
        write(base + "/orig.bin", bytes: 2_000_000, fill: 0x55)
        try FileManager.default.linkItem(atPath: base + "/orig.bin", toPath: base + "/hard.bin")
        let findings = try await DuplicateFinder(roots: [base], minBytes: 1_000_000).scan(ctx)
        #expect(findings.isEmpty)   // hardlink to the same inode is not a duplicate
    }
}
