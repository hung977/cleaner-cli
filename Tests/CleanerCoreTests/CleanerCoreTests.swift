import Testing
@testable import CleanerPlugins

@Suite("CleanerPlugins scaffold")
struct CleanerCoreTestsScaffold {
    @Test("module version marker is present")
    func versionMarker() {
        #expect(CleanerPlugins.specVersion == "0.1.0")
    }
}
