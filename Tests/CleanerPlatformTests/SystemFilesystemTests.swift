import Testing
import Foundation
@testable import CleanerPlatform
import CleanerCore

@Suite("CleanerPlatform: SystemFilesystem")
struct SystemFilesystemTests {
    let fs = SystemFilesystem()

    /// Make an isolated temp directory for a test.
    private func tempDir() throws -> String {
        let base = NSTemporaryDirectory() + "cleaner-fs-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    private func write(_ path: String, bytes: Int) throws {
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x41, count: bytes))
    }

    @Test("measures a directory's allocated size and file count")
    func measureDirectory() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(dir + "/a.txt", bytes: 4096)
        try write(dir + "/b.txt", bytes: 8192)
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try write(dir + "/sub/c.txt", bytes: 100)

        let e = try fs.measure(dir)
        #expect(e.fileCount == 3)
        #expect(e.allocatedSize.bytes >= 12288)          // at least the sum of file lengths
        #expect(e.logicalSize.bytes == 4096 + 8192 + 100)
    }

    @Test("does not follow symlinks when measuring")
    func symlinkNotFollowed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(dir + "/real.txt", bytes: 5000)
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.txt",
                                                   withDestinationPath: dir + "/real.txt")
        let linkEvidence = try fs.measure(dir + "/link.txt")
        #expect(linkEvidence.isSymlink)
        #expect(linkEvidence.allocatedSize == .zero)     // measured as the link, not the target
    }

    @Test("children lists immediate entries only, sorted")
    func children() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(dir + "/z.txt", bytes: 1)
        try write(dir + "/a.txt", bytes: 1)
        let kids = try fs.children(of: dir).map { ($0 as NSString).lastPathComponent }
        #expect(kids == ["a.txt", "z.txt"])
    }

    @Test("same-volume move is a rename; source gone, dest present")
    func moveSameVolume() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let src = dir + "/src.txt"
        let dst = dir + "/staged/dst.txt"
        try write(src, bytes: 1234)
        try fs.move(from: src, to: dst)
        #expect(!fs.exists(src))
        #expect(fs.exists(dst))
        #expect(try fs.measure(dst).logicalSize.bytes == 1234)
    }

    @Test("measuring a missing path throws notFound")
    func missing() {
        #expect(throws: FilesystemError.self) {
            _ = try fs.measure("/nonexistent/\(UUID().uuidString)")
        }
    }
}
