import Testing
@testable import CleanerEngine

@Suite("CleanerEngine scaffold")
struct CleanerEngineTestsScaffold {
    @Test("module version marker is present")
    func versionMarker() {
        #expect(CleanerEngine.specVersion == "0.1.0")
    }
}
