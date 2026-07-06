import Testing
@testable import CleanerPlatform

@Suite("Safety: ProtectedPathGuard (Constitution Art. 5)")
struct ProtectedPathGuardTests {
    let home = "/Users/tester"
    var guard_: ProtectedPathGuard { ProtectedPathGuard(home: home) }
    var allowed: [String] { ["/Users/tester/Library/Developer/Xcode/DerivedData"] }

    @Test("blocks system, root, and volume roots", arguments: [
        "/", "/System", "/System/Library", "/usr/lib", "/bin/sh",
        "/Library/Frameworks", "/Applications/Safari.app", "/Volumes/Backup",
    ])
    func blocksSystem(_ path: String) {
        #expect(guard_.isProtected(path))
        #expect(!guard_.validateForDeletion(path, allowedRoots: allowed).isAllowed)
    }

    @Test("blocks user content & credential roots", arguments: [
        "/Users/tester/Documents", "/Users/tester/Desktop/x", "/Users/tester/Pictures",
        "/Users/tester/.ssh", "/Users/tester/.ssh/id_rsa", "/Users/tester/Library/Keychains",
        "/Users/tester/secret.pem", "/Users/tester/foo.key",
    ])
    func blocksUserContent(_ path: String) {
        #expect(!guard_.validateForDeletion(path, allowedRoots: allowed + ["/Users/tester"]).isAllowed)
    }

    @Test("blocks the tool's own home")
    func blocksToolHome() {
        #expect(guard_.isProtected("/Users/tester/.cleaner/staging"))
    }

    @Test("blocks paths outside every allowed root")
    func blocksOutsideRoots() {
        let d = guard_.validateForDeletion("/Users/tester/random/dir", allowedRoots: allowed)
        #expect(!d.isAllowed)
    }

    @Test("allows a real path inside an allowed root")
    func allowsInsideRoot() {
        let p = "/Users/tester/Library/Developer/Xcode/DerivedData/MyApp-abc123"
        #expect(guard_.validateForDeletion(p, allowedRoots: allowed).isAllowed)
        #expect(!guard_.isProtected(p))
    }

    @Test("component-boundary: sibling with shared prefix is NOT inside the root")
    func componentBoundary() {
        // allowed root is .../DerivedData; this sibling shares a textual prefix but is outside.
        let sneaky = "/Users/tester/Library/Developer/Xcode/DerivedDataEVIL/x"
        #expect(!guard_.validateForDeletion(sneaky, allowedRoots: allowed).isAllowed)
    }

    @Test("`..` traversal out of an allowed root is rejected")
    func dotDotEscape() {
        let escape = "/Users/tester/Library/Developer/Xcode/DerivedData/../../../../Documents"
        #expect(!guard_.validateForDeletion(escape, allowedRoots: allowed).isAllowed)
    }
}
