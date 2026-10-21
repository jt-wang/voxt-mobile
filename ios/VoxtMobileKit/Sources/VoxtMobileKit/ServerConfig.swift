import Foundation

/// Where the Mac's Voxt Remote Input server is and how to authenticate to it.
public struct ServerConfig: Equatable, Codable, Sendable {
    public enum Error: Swift.Error, Equatable {
        case invalidAddress
        case missingToken
    }

    /// Kept with the HTTP credential in the app-private Keychain envelope.
    public struct Tailcat: Equatable, Codable, Sendable {
        public var address: String
        public var clientKey: String
        public var remotePort: UInt16
        public init(address: String, clientKey: String, remotePort: UInt16) {
            self.address = address
            self.clientKey = clientKey
            self.remotePort = remotePort
        }
    }

    public var tailcat: Tailcat?
    public var baseURL: URL
    public var token: String
    /// The Mac's name when the pairing invitation carried one. Older pairings have none.
    public var name: String?

    public init(baseURL: URL, token: String, tailcat: Tailcat? = nil, name: String? = nil) {
        self.tailcat = tailcat
        self.baseURL = baseURL
        self.token = token
        self.name = name
    }

    /// What to call the Mac on screen. A Tailcat pairing's base URL is a transport
    /// placeholder (`tailcat.invalid`) and never a name; nil means "Your Mac".
    public var displayName: String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard tailcat == nil, let host = baseURL.host(), host.hasSuffix(".ts.net") else { return nil }
        return host.split(separator: ".").first.map(String.init)
    }

    /// Accepts what people type: `mac.tailnet.ts.net:8900`, with or without scheme or trailing slash.
    /// A bare host means HTTPS, since `tailscale serve` provides the certificate.
    public static func normalizeBaseURL(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Error.invalidAddress }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { throw Error.invalidAddress }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw Error.invalidAddress }
        return url
    }
}
