import Foundation
import Testing
@testable import VoxtMobileKit

/// App Group IDs are unique across Apple teams, so a build signed by anyone else uses its
/// own group (VOXT_MOBILE_ID_PREFIX). The app and the keyboard read it from Info.plist.
@Suite struct AppGroupTests {
    @Test func readsTheGroupTheBuildWroteIntoInfoPlist() {
        #expect(DictationChannel.appGroup(from: ["VoxtAppGroup": "group.com.example.voxt.shared"]) == "group.com.example.voxt.shared")
    }

    @Test func fallsBackToAltStoresRenamedGroupThenOurs() {
        #expect(DictationChannel.appGroup(from: ["ALTAppGroups": ["group.io.jingtao.voxtmobile.shared.ABCDE12345"]])
                == "group.io.jingtao.voxtmobile.shared.ABCDE12345")
        #expect(DictationChannel.appGroup(from: nil) == "group.io.jingtao.voxtmobile.shared")
        #expect(DictationChannel.appGroup(from: ["VoxtAppGroup": ""]) == "group.io.jingtao.voxtmobile.shared")
        #expect(DictationChannel.appGroup(from: ["VoxtAppGroup": "$(VOXT_APP_GROUP)"]) == "group.io.jingtao.voxtmobile.shared",
                "an unexpanded build setting is not a group")
    }
}
