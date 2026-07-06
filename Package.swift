// swift-tools-version: 6.0
import PackageDescription

// cleaner-cli — free, open-source macOS disk-cleaner CLI (open-core).
// Module graph follows specs/12-module-decomposition.md. Dependencies point INWARD.
// The absence of a CleanerPlugins -> CleanerEngine edge is deliberate: "plugins propose,
// the engine disposes" is a compile-time guarantee (Constitution IV / spec 13).

let package = Package(
    name: "cleaner-cli",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cleaner", targets: ["cleaner"]),
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .library(name: "CleanerPluginAPI", targets: ["CleanerPluginAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // ── Domain (no internal deps) ──────────────────────────────────────────
        .target(name: "CleanerCore"),

        // ── Cross-cutting ──────────────────────────────────────────────────────
        .target(name: "CleanerLogging", dependencies: [
            "CleanerCore",
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "CleanerConfig", dependencies: [
            "CleanerCore",
            .product(name: "Yams", package: "Yams"),
        ]),
        .target(name: "CleanerReport", dependencies: ["CleanerCore"]),
        .target(name: "CleanerLicenseStub", dependencies: ["CleanerCore"]),

        // ── Platform adapters (native macOS) ───────────────────────────────────
        .target(name: "CleanerPlatform", dependencies: [
            "CleanerCore",
            .product(name: "Collections", package: "swift-collections"),
        ]),

        // ── Plugin SDK (what plugins link against — NOT the engine) ─────────────
        .target(name: "CleanerPluginAPI", dependencies: [
            "CleanerCore", "CleanerPlatform", "CleanerLogging",
        ]),

        // ── Engine (orchestration; disposes) ───────────────────────────────────
        .target(name: "CleanerEngine", dependencies: [
            "CleanerCore", "CleanerPlatform", "CleanerPluginAPI",
            "CleanerLogging", "CleanerConfig",
        ]),

        // ── Bundled plugins (propose only; MUST NOT depend on CleanerEngine) ────
        .target(name: "CleanerPlugins", dependencies: [
            "CleanerCore", "CleanerPluginAPI", "CleanerPlatform",
        ]),

        // ── Executable / CLI ───────────────────────────────────────────────────
        .executableTarget(name: "cleaner", dependencies: [
            "CleanerCore", "CleanerEngine", "CleanerPlugins", "CleanerConfig",
            "CleanerReport", "CleanerLogging", "CleanerLicenseStub",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),

        // ── Tests ──────────────────────────────────────────────────────────────
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"]),
        .testTarget(name: "CleanerPlatformTests", dependencies: ["CleanerPlatform"]),
        .testTarget(name: "CleanerEngineTests", dependencies: [
            "CleanerEngine", "CleanerPlugins", "CleanerPluginAPI", "CleanerPlatform",
        ]),
        .testTarget(name: "CleanerPluginsTests", dependencies: [
            "CleanerPlugins", "CleanerPluginAPI",
        ]),
        .testTarget(name: "CleanerConfigTests", dependencies: ["CleanerConfig"]),
        .testTarget(name: "CleanerReportTests", dependencies: ["CleanerReport"]),
    ]
)
