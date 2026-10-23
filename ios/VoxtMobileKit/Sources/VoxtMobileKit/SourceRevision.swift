import Foundation

/// The public commit a release was built from: `VoxtSourceRevision` in Info.plist, which the release
/// build fills in. Nil for a development build (empty, or the unexpanded setting).
public struct SourceRevision: Equatable, Sendable {
    public let full: String
    public let repository: URL

    public init?(info: [String: Any]?) {
        guard let value = info?["VoxtSourceRevision"] as? String,
              value.count == 40, value.allSatisfy(\.isHexDigit) else { return nil }
        full = value.lowercased()
        repository = Self.repository(info: info)
    }

    /// The repository the build names in `VoxtSourceURL` (build setting `VOXT_SOURCE_URL`),
    /// upstream when it names none. xcconfig reads `//` as a comment, so the setting has no scheme.
    public static func repository(info: [String: Any]?) -> URL {
        let urlKey = "VoxtSourceURL"
        return configured(info?[urlKey], default: "https://github.com/sgl-project/sglang-omni")
    }

    /// Where the app sends people to get Voxt and Voxt Connector for the Mac: `VoxtSiteURL` (build setting
    /// `VOXT_SITE_URL`), the setup steps upstream when the build names none. Also without a scheme.
    public static func site(info: [String: Any]?) -> URL {
        let siteKey = "VoxtSiteURL"
        return configured(info?[siteKey], default: "https://github.com/sgl-project/sglang-omni/tree/main/Voxt/Mobile#set-it-up")
    }

    private static func configured(_ value: Any?, default fallback: String) -> URL {
        let fallbackURL = URL(string: fallback)!
        guard var text = value as? String, !text.isEmpty, !text.contains("$(") else { return fallbackURL }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? fallbackURL
    }

    public var short: String { String(full.prefix(7)) }
    public var url: URL { repository.appendingPathComponent("commit").appendingPathComponent(full) }
}
