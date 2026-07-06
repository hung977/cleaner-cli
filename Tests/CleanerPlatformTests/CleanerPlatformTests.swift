import Testing
@testable import CleanerPlatform

@Suite("CleanerPlatform scaffold")
struct CleanerPlatformTestsScaffold {
    @Test("module version marker is present")
    func versionMarker() {
        #expect(CleanerPlatform.specVersion == "0.1.0")
    }
}
