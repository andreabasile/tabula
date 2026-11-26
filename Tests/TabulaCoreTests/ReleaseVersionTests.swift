import Testing
@testable import TabulaCore

struct ReleaseVersionTests {
    @Test func comparesComponentsAsNumbers() {
        #expect(ReleaseVersion.isNewer("1.2.0", than: "1.1.0"))
        #expect(!ReleaseVersion.isNewer("1.1.0", than: "1.2.0"))
        #expect(ReleaseVersion.isNewer("1.10.0", than: "1.9.3"))
        #expect(ReleaseVersion.isNewer("v2", than: "1.99.99"))
    }

    @Test func leadingVAndMissingComponentsDoNotMatter() {
        #expect(!ReleaseVersion.isNewer("v1.2", than: "1.2.0"))
        #expect(!ReleaseVersion.isNewer("1.2.0", than: "v1.2"))
        #expect(ReleaseVersion.isNewer("v1.2.1", than: "1.2"))
    }

    @Test func garbageIsNeverNewer() {
        for garbage in ["", "v", "latest", "1..2", "1.2.0-beta", "-1", "1.x"] {
            #expect(!ReleaseVersion.isNewer(garbage, than: "1.0.0"))
            #expect(!ReleaseVersion.isNewer("9.9.9", than: garbage))
        }
    }
}
