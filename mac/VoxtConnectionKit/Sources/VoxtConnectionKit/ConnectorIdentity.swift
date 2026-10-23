import Foundation

/// The Connector's bundle ID and the Voxt builds it trusts. project.yml sets the Connector's ID;
/// a fork that renames Voxt lists its bundle IDs, separated by spaces, under VoxtBundleIdentifiers
/// in the Connector's Info.plist. Voxt reads the Connector's ID the same way, from
/// VoxtConnectorBundleIdentifier in its own Info.plist.
public enum ConnectorIdentity {
    public static let defaultBundleIdentifier = "com.voxt.VoxtConnector"
    public static let defaultVoxtBundleIdentifiers = ["com.voxt.Voxt", "com.voxt.Voxt.omni.dev"]
    public static let voxtBundleIdentifiersKey = "VoxtBundleIdentifiers"

    /// Subsystem for this app's logs.
    public static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? defaultBundleIdentifier }

    /// The Info.plist override when every entry is a bundle ID, otherwise the defaults: the list
    /// goes into a code requirement, where a quote would end the identifier string.
    public static func voxtBundleIdentifiers(info: [String: Any]? = Bundle.main.infoDictionary) -> [String] {
        let value = info?[voxtBundleIdentifiersKey]
        let listed = (value as? [String]) ?? (value as? String).map { $0.split(separator: " ").map(String.init) } ?? []
        return !listed.isEmpty && listed.allSatisfy(isBundleIdentifier) ? listed : defaultVoxtBundleIdentifiers
    }

    static func isBundleIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

/// Where the setup guide sends people for the iPhone app: `VoxtIPhoneAppURL` in Info.plist (build
/// setting `VOXT_IPHONE_APP_URL`), else the upstream setup steps, which say how to build it.
/// xcconfig reads `//` as a comment, so the setting has no scheme; https is added.
public struct ConnectorIPhoneApp: Equatable, Sendable {
    public static let infoKey = "VoxtIPhoneAppURL"
    public static let setupSteps = URL(string: "https://github.com/sgl-project/sglang-omni/tree/main/Voxt/Mobile#set-it-up")!

    public let url: URL
    public var isSetupSteps: Bool { url == Self.setupSteps }
    /// The address without its scheme, as the guide prints it.
    public var shownAddress: String {
        let text = url.absoluteString
        return text.range(of: "://").map { String(text[$0.upperBound...]) } ?? text
    }

    public init(info: [String: Any]? = Bundle.main.infoDictionary) {
        guard var text = info?[Self.infoKey] as? String, !text.isEmpty, !text.contains("$(") else {
            url = Self.setupSteps; return
        }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        url = URL(string: text) ?? Self.setupSteps
    }
}
