import Testing
import Foundation
@testable import CleanerConfig

@Suite("Config: load, glob, ignore")
struct ConfigTests {
    private func writeConfig(_ yaml: String) throws -> String {
        let dir = NSTemporaryDirectory() + "cleaner-cfg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/config.yml"
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("missing config yields empty (config is optional)")
    func missing() throws {
        let cfg = try ConfigLoader().load(path: "/nonexistent-\(UUID().uuidString).yml")
        #expect(cfg == .empty)
    }

    @Test("loads ignore & whitelist globs")
    func loads() throws {
        let path = try writeConfig("""
        version: 1
        ignore:
          - "*Keep*"
          - "*/node_modules/*"
        whitelist:
          - "/Users/me/critical"
        """)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let cfg = try ConfigLoader().load(path: path)
        #expect(cfg.ignore.count == 2)
        #expect(cfg.whitelist == ["/Users/me/critical"])
    }

    @Test("loads named profiles with include/exclude/risky")
    func profiles() throws {
        let path = try writeConfig("""
        version: 1
        profiles:
          xcode-only:
            include: [dev.cleaner.xcode.deriveddata]
          no-browser:
            exclude: [dev.cleaner.browser.cache]
        """)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let cfg = try ConfigLoader().load(path: path)
        #expect(cfg.profiles.count == 2)
        #expect(cfg.profiles["xcode-only"]?.include == ["dev.cleaner.xcode.deriveddata"])
        #expect(cfg.profiles["no-browser"]?.exclude == ["dev.cleaner.browser.cache"])
    }

    @Test("unsupported version throws (exit 6 territory)")
    func badVersion() throws {
        let path = try writeConfig("version: 99\nignore: []\n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        #expect(throws: ConfigError.self) { _ = try ConfigLoader().load(path: path) }
    }

    @Test("glob matching: * crosses path separators")
    func globs() {
        #expect(Glob.matches(pattern: "*Keep*", path: "/a/b/DerivedData-Keep-me/x"))
        #expect(Glob.matches(pattern: "*/pip/*", path: "/home/Library/Caches/pip/wheels"))
        #expect(!Glob.matches(pattern: "*Keep*", path: "/a/b/DerivedData/x"))
    }

    @Test("excludes() honors both ignore and whitelist")
    func excludes() {
        let cfg = CleanerConfiguration(ignore: ["*Keep*"], whitelist: ["*critical*"])
        #expect(cfg.excludes("/x/Keep-this"))
        #expect(cfg.excludes("/x/critical/data"))
        #expect(!cfg.excludes("/x/DerivedData/app"))
    }
}
