import Foundation
import Testing
@testable import VoxtConnectionKit

/// The Connector asks Voxt for its port and Access token over a Unix socket; each side
/// checks the other's code signature first.
@Suite struct ConnectorLinkTests {
    /// A connected socket pair: the Connector side and a fake Voxt side.
    private func pair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    private func fakeVoxt(_ fd: Int32, replies: [String], holdOpenSeconds: UInt32 = 0) -> Task<String, Never> {
        Task.detached {
            // A missing request must end the test, not block it.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var request = Data()
            while !request.contains(UInt8(ascii: "\n")), let byte = try? handle.read(upToCount: 1), !byte.isEmpty { request.append(byte) }
            for reply in replies { handle.write(Data((reply + "\n").utf8)) }
            sleep(holdOpenSeconds)   // like Voxt waiting for the user's click
            return String(decoding: request, as: UTF8.self)
        }
    }

    @Test func approvedConnectionReturnsPortAndToken() async throws {
        let (connector, voxt) = pair()
        let server = fakeVoxt(voxt, replies: [#"{"v":1,"status":"pending"}"#, #"{"v":1,"status":"approved","port":47920,"token":"fixture-token"}"#])
        let link = ConnectorLink(connect: { connector }, verifyPeer: { _ in true })
        let result = try await link.authorize()
        #expect(result.port == 47920)
        #expect(result.token == "fixture-token")
        #expect(await server.value.contains(#""op":"connect""#))
    }

    @Test func approvalSaysWhetherVoxtWillRememberIt() async throws {
        for (remembered, expected) in [("true", true), ("false", false)] {
            let (connector, voxt) = pair()
            _ = fakeVoxt(voxt, replies: [#"{"v":1,"status":"approved","port":47920,"token":"t","alwaysAllowed":\#(remembered)}"#])
            let grant = try await ConnectorLink(connect: { connector }, verifyPeer: { _ in true }).authorize()
            #expect(grant.alwaysAllowed == expected)
            #expect(grant.port == 47920)
        }
        let (connector, voxt) = pair()
        _ = fakeVoxt(voxt, replies: [#"{"v":1,"status":"approved","port":47920,"token":"t"}"#])
        #expect(try await ConnectorLink(connect: { connector }, verifyPeer: { _ in true }).authorize().alwaysAllowed == false,
                "an older Voxt without the field counts as not remembered")
    }

    @Test func cancellingClosesTheSocketPromptly() async throws {
        let (connector, voxt) = pair()
        let server = fakeVoxt(voxt, replies: [#"{"v":1,"status":"pending"}"#], holdOpenSeconds: 4)
        let link = ConnectorLink(connect: { connector }, verifyPeer: { _ in true })
        let started = Date()
        let task = Task { try await link.authorize() }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 2, "Cancel must not wait for Voxt's reply or the 130 s timeout")
        _ = await server.value
    }

    @Test func deniedOrRejectedConnectionThrows() async throws {
        for (reply, expected) in [(#"{"v":1,"status":"denied"}"#, ConnectorLink.Failure.denied),
                                  (#"{"v":1,"status":"rejected","reason":"signature"}"#, .rejectedBySignature)] {
            let (connector, voxt) = pair()
            _ = fakeVoxt(voxt, replies: [reply])
            let link = ConnectorLink(connect: { connector }, verifyPeer: { _ in true })
            await #expect(throws: expected) { try await link.authorize() }
        }
    }

    @Test func untrustedVoxtGetsNothingSent() async throws {
        let (connector, voxt) = pair()
        let server = fakeVoxt(voxt, replies: [])
        let link = ConnectorLink(connect: { connector }, verifyPeer: { _ in false })
        await #expect(throws: ConnectorLink.Failure.untrustedVoxt) { try await link.authorize() }
        #expect(await server.value.isEmpty, "the request is sent only after Voxt's signature checks out")
    }

    @Test func voxtNotRunningIsReported() async throws {
        let link = ConnectorLink(connect: { throw ConnectorLink.Failure.voxtNotRunning }, verifyPeer: { _ in true })
        await #expect(throws: ConnectorLink.Failure.voxtNotRunning) { try await link.authorize() }
    }

    @Test func requirementUsesTheConnectorsOwnTeamAndVoxtBundle() {
        #expect(ConnectorLink.voxtRequirement(team: "ABCDE12345") == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and (identifier "com.voxt.Voxt" or identifier "com.voxt.Voxt.omni.dev")"#)
        #expect(ConnectorLink.socketPath.hasSuffix("Library/Application Support/Voxt/connector.sock"))
    }

    @Test func unsignedConnectorFallsBackToManualEntryWithoutConnecting() async {
        final class Probe: @unchecked Sendable { var connected = false }
        let probe = Probe()
        let link = ConnectorLink(team: nil, connect: { probe.connected = true; return -1 })
        // Same outcome as a Voxt that refused this build: the Connector shows manual entry.
        await #expect(throws: ConnectorLink.Failure.rejectedBySignature) { _ = try await link.authorize() }
        #expect(probe.connected == false)
    }
}
