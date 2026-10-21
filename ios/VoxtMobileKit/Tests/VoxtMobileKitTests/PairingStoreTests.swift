import Foundation
import Testing
@testable import VoxtMobileKit

private final class MemoryTokenStore: TokenStoring {
    var token: String?
    var failWrites = false
    func read() throws -> String? { token }
    func write(_ value: String) throws {
        if failWrites { throw URLError(.cannotWriteToFile) }
        token = value
    }
    func delete() throws { token = nil }
}

@Suite struct PairingStoreTests {
    @Test func oldPairingIsNotMigratedAndConnectorPairingPersists() throws {
        let name = "pairing.test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = ServerConfig(baseURL: URL(string: "https://fixture.example.test")!, token: "fake-fixture")
        defaults.set(try JSONEncoder().encode(config), forKey: "server.config")
        let secrets = MemoryTokenStore()
        let store = PairingStore(defaults: defaults, tokens: secrets)
        #expect(try store.load() == nil)
        let oldEnvelope = try JSONSerialization.data(withJSONObject: ["version": 1, "server": JSONSerialization.jsonObject(with: JSONEncoder().encode(config))])
        secrets.token = "voxt-pairing-v1:" + String(decoding: oldEnvelope, as: UTF8.self)
        #expect(try store.load() == nil)
        try store.save(config)
        #expect(try store.load() == config)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func keychainRoundTripUpdatesAndDeletesOnlyItsOwnItem() throws {
        let store = KeychainTokenStore(service: "com.voxtmobile.test.\(UUID())")
        defer { try? store.delete() }
        #expect(try store.read() == nil)
        try store.write("fake-one")
        #expect(try store.read() == "fake-one")
        try store.write("fake-two")
        #expect(try store.read() == "fake-two")
        try store.delete()
        #expect(try store.read() == nil)
    }

}
