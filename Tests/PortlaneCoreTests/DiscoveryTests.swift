import PortlaneCore
import Testing

/// Protects read-only discovery against invented targets and accidental grouping by host or port.
struct DiscoveryTests {
    @Test func matchesTwoRulesForOnePID() throws {
        let invocation = SSHInvocation(arguments: ["ssh", "-N", "-i", "/tmp/key with spaces", "-L",
            "127.0.0.1:3113:127.0.0.1:3113", "-L127.0.0.1:3111:127.0.0.1:3111", "m4"])
        let snapshot = ListeningEndpoint.parseLsof("p3001\nn127.0.0.1:3113\nn127.0.0.1:3111\np3002\nn127.0.0.1:4444\n")
        let session = try #require(ExternalSession(pid: 3001, invocation: invocation, listeners: snapshot))

        #expect(session.host == "m4")
        #expect(session.rules.map(\.copyAddress) == ["127.0.0.1:3111", "127.0.0.1:3113"])
        #expect(session.rules.map { $0.forward?.targetPort } == [3111, 3113])
        #expect(session.matches(query: "m4 3113"))
        #expect(!session.matches(query: "4444"))
    }

    @Test func keepsIPv6AndUnknownListenersDistinct() throws {
        let invocation = SSHInvocation(arguments: ["ssh", "-NL[::1]:1080:[::1]:80", "-o",
            "DynamicForward=127.0.0.1:8000", "-R", "18080:127.0.0.1:3000", "host"])
        let snapshot = ListeningEndpoint.parseLsof("p100\nn[::1]:1080\nn127.0.0.1:1080\nn127.0.0.1:8000\n")
        let session = try #require(ExternalSession(pid: 100, invocation: invocation, listeners: snapshot))
        #expect(session.rules.count == 4)
        #expect(session.rules.first { $0.listener?.host == "::1" }?.forward?.targetHost == "::1")
        #expect(session.rules.first { $0.listener?.address == "127.0.0.1:1080" }?.forward == nil)
        #expect(session.rules.first { $0.listener?.port == 8000 }?.copyAddress == "socks5://127.0.0.1:8000")
        let remote = try #require(session.rules.first { $0.forward?.kind == .remote })
        #expect(remote.listener == nil)
        #expect(remote.copyAddress == nil)
    }

    @Test func ignoresRemoteCommandAndUnobservedLocalRules() {
        let invocation = SSHInvocation(arguments: ["ssh", "-o", "ProxyJump=jumphost", "server", "echo",
                                                   "-L", "3113:localhost:80"])
        #expect(invocation.host == "server")
        #expect(invocation.forwards.isEmpty)
        #expect(ExternalSession(pid: 3001, invocation: invocation, listeners: []) == nil)
    }

    @Test func masterDoesNotInheritForwardingRules() throws {
        let rule = Forwarding(bindAddress: "127.0.0.1", port: 3113, targetHost: "localhost", targetPort: 80)
        let tunnel = Tunnel(host: "alias", forwardings: [rule])
        let builder = SSHCommandBuilder(context: .init(controlPath: "/tmp/portlane-sample/ssh"))
        let arguments = builder.arguments(for: tunnel)
        #expect(arguments.contains("ClearAllForwardings=yes"))
        #expect(!arguments.contains("ClearAllForwardings=no"))
        #expect(!arguments.contains("ControlPath=none"))
        #expect(!arguments.contains("-L"))
        #expect(builder.displayCommand(for: tunnel).contains(rule.sshSpec))
    }
}
