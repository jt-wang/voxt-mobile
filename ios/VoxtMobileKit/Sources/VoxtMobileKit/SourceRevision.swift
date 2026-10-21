import Foundation

/// The public commit a release was built from: `VoxtSourceRevision` in Info.plist, written by
/// tools/release-build.sh. Nil for a development build (empty, or the unexpanded setting).
public struct SourceRevision: Equatable, Sendable {
    public let full: String

    public init?(info: [String: Any]?) {
        guard let value = info?["VoxtSourceRevision"] as? String,
              value.count == 40, value.allSatisfy(\.isHexDigit) else { return nil }
        full = value.lowercased()
    }

    public var short: String { String(full.prefix(7)) }
    public var url: URL { URL(string: "https://github.com/jt-wang/voxt-mobile/commit/\(full)")! }
}
