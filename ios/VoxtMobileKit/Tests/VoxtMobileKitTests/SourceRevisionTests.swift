import Foundation
import Testing
@testable import VoxtMobileKit

/// Settings › About › Source code: the commit a release was built from (tools/release-build.sh
/// writes VoxtSourceRevision), linked on GitHub; anything else is a development build.
@Suite struct SourceRevisionTests {
    private let full = "cdfb0e8a1b2c3d4e5f60718293a4b5c6d7e8f901"

    @Test func aReleaseShowsTheShortHashAndLinksTheCommit() throws {
        let revision = try #require(SourceRevision(info: ["VoxtSourceRevision": full]))
        #expect(revision.short == "cdfb0e8")
        #expect(revision.url == URL(string: "https://github.com/jt-wang/voxt-mobile/commit/\(full)"))
    }

    @Test func anythingElseIsADevelopmentBuild() {
        #expect(SourceRevision(info: nil) == nil)
        #expect(SourceRevision(info: [:]) == nil)
        #expect(SourceRevision(info: ["VoxtSourceRevision": ""]) == nil)
        #expect(SourceRevision(info: ["VoxtSourceRevision": "$(VOXT_SOURCE_REVISION)"]) == nil, "the setting was never filled in")
        #expect(SourceRevision(info: ["VoxtSourceRevision": "main"]) == nil, "not a commit hash")
        #expect(SourceRevision(info: ["VoxtSourceRevision": String(full.prefix(12))]) == nil, "the link needs the full hash")
    }
}
