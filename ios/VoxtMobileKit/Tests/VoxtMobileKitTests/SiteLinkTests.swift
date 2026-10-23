import Foundation
import Testing
@testable import VoxtMobileKit

/// "Get the Mac apps" on the first page and the pairing page: the page the build names in
/// VoxtSiteURL (build setting VOXT_SITE_URL), the setup steps upstream when it names none.
@Suite struct SiteLinkTests {
    private let upstream = URL(string: "https://github.com/sgl-project/sglang-omni/tree/main/Voxt/Mobile#set-it-up")

    /// xcconfig reads `//` as a comment, so the build setting has no scheme.
    @Test func theConfiguredSiteGetsHTTPS() {
        #expect(SourceRevision.site(info: ["VoxtSiteURL": "example.com/voxt-mobile"]) == URL(string: "https://example.com/voxt-mobile"))
        #expect(SourceRevision.site(info: ["VoxtSiteURL": "example.com"]) == URL(string: "https://example.com"))
    }

    @Test func trailingSlashesAreDropped() {
        #expect(SourceRevision.site(info: ["VoxtSiteURL": "example.com/voxt-mobile/"]) == URL(string: "https://example.com/voxt-mobile"))
        #expect(SourceRevision.site(info: ["VoxtSiteURL": "https://example.com//"]) == URL(string: "https://example.com"))
    }

    @Test func withoutASiteTheBuildPointsAtTheUpstreamSetupSteps() {
        #expect(SourceRevision.site(info: nil) == upstream)
        #expect(SourceRevision.site(info: [:]) == upstream)
        #expect(SourceRevision.site(info: ["VoxtSiteURL": ""]) == upstream)
        #expect(SourceRevision.site(info: ["VoxtSiteURL": "$(VOXT_SITE_URL)"]) == upstream, "the setting was never filled in")
    }

    @Test func theSiteIsNotTheSourceLink() {
        let info = ["VoxtSiteURL": "example.com/voxt-mobile", "VoxtSourceURL": "github.com/example/voxt"]
        #expect(SourceRevision.site(info: info) == URL(string: "https://example.com/voxt-mobile"))
        #expect(SourceRevision.repository(info: info) == URL(string: "https://github.com/example/voxt"))
    }
}
