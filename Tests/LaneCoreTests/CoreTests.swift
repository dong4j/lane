import Foundation
import Testing
@testable import LaneCore

@Suite struct ForwardingTests {
    @Test func localSpecWithAndWithoutBind() {
        var f = Forwarding(kind: .local, bindAddress: "", port: 8080, targetHost: "db.internal", targetPort: 5432)
        #expect(f.sshSpec == "8080:db.internal:5432")
        #expect(f.commandString == "-L 8080:db.internal:5432")
        f.bindAddress = "*"
        #expect(f.sshSpec == "*:8080:db.internal:5432")
        #expect(f.listenDisplayAddress == "0.0.0.0:8080")
    }

    @Test func ipv6IsBracketed() {
        let f = Forwarding(kind: .remote, bindAddress: "::1", port: 9000, targetHost: "fe80::1", targetPort: 22)
        #expect(f.sshSpec == "[::1]:9000:[fe80::1]:22")
    }

    @Test func dynamicHasNoTarget() {
        let f = Forwarding(kind: .dynamic, bindAddress: "127.0.0.1", port: 1080, targetHost: "ignored", targetPort: 1)
        #expect(f.commandString == "-D 127.0.0.1:1080")
    }
}

@Suite struct CommandBuilderTests {
    func sample() -> Tunnel {
        Tunnel(
            name: "Prod DB",
            host: "bastion.example.com",
            port: 2222,
            user: "deploy",
            forwardings: [
                Forwarding(kind: .local, port: 15432, targetHost: "db", targetPort: 5432),
                Forwarding(kind: .dynamic, port: 1080, enabled: true),
                Forwarding(kind: .remote, port: 9000, targetHost: "localhost", targetPort: 3000, enabled: false),
            ]
        )
    }

    @Test func buildsCoreArguments() {
        let args = SSHCommandBuilder().arguments(for: sample())
        #expect(args.first == "-N")
        #expect(args.contains("-v"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("StrictHostKeyChecking=ask"))
        #expect(args.suffix(6) == ["-p", "2222", "-l", "deploy", "--", "bastion.example.com"])
        // Enabled forwards only.
        #expect(args.contains("15432:db:5432"))
        #expect(args.contains("1080"))
        #expect(!args.contains("9000:localhost:3000"))
    }

    @Test func publicKeyAuthAddsIdentity() {
        var t = sample()
        t.authMethod = .publicKey
        t.identityFile = "/tmp/id_test"
        let args = SSHCommandBuilder().arguments(for: t)
        let i = args.firstIndex(of: "-i")
        #expect(i != nil)
        #expect(args[i! + 1] == "/tmp/id_test")
        #expect(args.contains("IdentitiesOnly=yes"))
        // A one-time code after the key (sshd `AuthenticationMethods publickey,keyboard-interactive`)
        // only works if ssh may go on to keyboard-interactive after the key's partial success.
        #expect(args.contains("PreferredAuthentications=publickey,keyboard-interactive,password"))
    }

    @Test func interactiveAuthCanSendAKeyFirst() {
        var t = sample()
        t.authMethod = .keyboardInteractive
        let args = SSHCommandBuilder().arguments(for: t)
        #expect(args.contains("PreferredAuthentications=keyboard-interactive,password,publickey"))
    }

    @Test func proxyUsesHelperWhenAvailable() {
        var t = sample()
        t.proxy = ProxySettings(kind: .socks5, host: "proxy.lan", port: 1080, username: "bob", requiresPassword: true)
        let builder = SSHCommandBuilder(context: .init(helperExecutable: "/Applications/Porthole.app/Contents/MacOS/Porthole"))
        let cmd = builder.proxyCommand(for: t)
        #expect(cmd == "/Applications/Porthole.app/Contents/MacOS/Porthole --proxy-connect socks5 proxy.lan 1080 %h %p bob ask-password")
        let args = builder.arguments(for: t)
        #expect(args.contains { $0.hasPrefix("ProxyCommand=") })
    }

    @Test func proxyOnlyAsksForPasswordWhenRequired() {
        var t = sample()
        let builder = SSHCommandBuilder(context: .init(helperExecutable: "/P"))
        t.proxy = ProxySettings(kind: .http, host: "proxy.lan", port: 3128, username: "bob", requiresPassword: false)
        #expect(builder.proxyCommand(for: t) == "/P --proxy-connect http proxy.lan 3128 %h %p bob no-password")
        t.proxy = ProxySettings(kind: .socks4, host: "proxy.lan", port: 1080, username: "bob", requiresPassword: true)
        #expect(builder.proxyCommand(for: t) == "/P --proxy-connect socks4 proxy.lan 1080 %h %p bob no-password")
        t.proxy = ProxySettings(kind: .socks5, host: "proxy.lan", port: 1080)
        #expect(builder.proxyCommand(for: t) == "/P --proxy-connect socks5 proxy.lan 1080 %h %p")
        // ssh expands %-tokens in ProxyCommand, so a literal % must be doubled.
        t.proxy = ProxySettings(kind: .socks5, host: "proxy.lan", port: 1080, username: "100%user")
        #expect(builder.proxyCommand(for: t) == "/P --proxy-connect socks5 proxy.lan 1080 %h %p 100%%user no-password")
    }

    @Test func extraOptionsOverrideButCantBreakSupervision() {
        var t = sample()
        t.extraOptions = "ServerAliveInterval 7\nExitOnForwardFailure no\nPort 2200"
        let args = SSHCommandBuilder().arguments(for: t)
        // ssh keeps the first value it sees, so the user's value must come first.
        let user = args.firstIndex(of: "ServerAliveInterval=7")!
        let ours = args.firstIndex(of: "ServerAliveInterval=30")!
        #expect(user < ours)
        #expect(args.firstIndex(of: "Port=2200")! < args.firstIndex(of: "-p")!)
        #expect(!args.contains("ExitOnForwardFailure=no"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
    }

    @Test func defaultPortLeavesRoomForSSHConfig() {
        var t = sample()
        t.port = 22
        #expect(!SSHCommandBuilder().arguments(for: t).contains("-p"))
        t.useSSHConfig = false
        let args = SSHCommandBuilder().arguments(for: t)
        #expect(args[args.firstIndex(of: "-p")! + 1] == "22")
    }

    @Test func helperPathWithSpacesIsQuoted() {
        var t = sample()
        t.proxy = ProxySettings(kind: .http, host: "p", port: 3128)
        let builder = SSHCommandBuilder(context: .init(helperExecutable: "/Users/x/My Apps/Porthole"))
        #expect(builder.proxyCommand(for: t)?.hasPrefix("'/Users/x/My Apps/Porthole' --proxy-connect http") == true)
    }

    @Test func jumpHost() {
        var t = sample()
        t.proxy = ProxySettings(kind: .jumpHost, host: "jump.example.com", port: 2200, username: "ops")
        let args = SSHCommandBuilder().arguments(for: t)
        let j = args.firstIndex(of: "-J")!
        #expect(args[j + 1] == "ops@jump.example.com:2200")
    }

    @Test func extraOptionsParsing() {
        let parsed = SSHCommandBuilder.parseExtraOptions("""
        # comment
        ServerAliveInterval 10
        -o TCPKeepAlive=no
        IPQoS = throughput
        bad;key value
        """)
        #expect(parsed == ["ServerAliveInterval=10", "TCPKeepAlive=no", "IPQoS=throughput"])
    }

    @Test func displayCommandIsShellSafe() {
        var t = sample()
        t.note = "x"
        t.forwardings = [Forwarding(kind: .local, bindAddress: "*", port: 80, targetHost: "web", targetPort: 80)]
        let cmd = SSHCommandBuilder().displayCommand(for: t)
        #expect(cmd.hasPrefix("/usr/bin/ssh -N "))
        #expect(cmd.contains("-L '*:80:web:80'"))
        #expect(!cmd.contains("-v "))
        #expect(!cmd.contains("BatchMode"))
    }

    @Test func noSSHConfig() {
        var t = sample()
        t.useSSHConfig = false
        let args = SSHCommandBuilder().arguments(for: t)
        #expect(Array(args[2...3]) == ["-F", "/dev/null"])
    }
}

@Suite struct ValidationTests {
    @Test func requiresHostAndForwarding() {
        let issues = TunnelValidator.validate(Tunnel())
        #expect(issues.contains { $0.field == .host && $0.severity == .error })
        #expect(issues.contains { $0.field == .forwardings })
    }

    @Test func rejectsInjection() {
        var t = Tunnel(host: "-oProxyCommand=evil", forwardings: [Forwarding()])
        #expect(TunnelValidator.validate(t).contains { $0.field == .host })
        t.host = "good.example; rm -rf /"
        #expect(TunnelValidator.validate(t).contains { $0.field == .host })
        t.host = "good.example"
        #expect(!TunnelValidator.validate(t).contains { $0.severity == .error })
    }

    @Test func detectsDuplicatePorts() {
        let a = Forwarding(kind: .local, port: 8080, targetHost: "a", targetPort: 1)
        let b = Forwarding(kind: .dynamic, bindAddress: "localhost", port: 8080)
        let t = Tunnel(host: "h", forwardings: [a, b])
        #expect(TunnelValidator.validate(t).contains { $0.field == .forwarding(b.id, .listenPort) && $0.severity == .error })
    }

    @Test func portNumbersHaveNoDigitGrouping() {
        let a = Forwarding(kind: .local, port: 18080, targetHost: "a", targetPort: 1)
        let b = Forwarding(kind: .local, port: 18080, targetHost: "b", targetPort: 2)
        let messages = TunnelValidator.validate(Tunnel(host: "h", forwardings: [a, b])).map(\.message)
        #expect(messages.contains { $0.contains("18080") })
        #expect(!messages.contains { $0.contains("18,080") || $0.contains("18.080") })
        let remote = Forwarding(kind: .remote, port: 18080, targetHost: "localhost", targetPort: 3000)
        #expect(remote.explanation(serverName: "srv").contains("port 18080"))
    }

    @Test func remotePrivilegedPortWarns() {
        let f = Forwarding(kind: .remote, port: 80, targetHost: "localhost", targetPort: 8080)
        let issues = TunnelValidator.validate(f)
        #expect(issues.count == 1)
        #expect(issues[0].severity == .warning)
    }
}

@Suite struct LogParserTests {
    @Test func progressEvents() {
        #expect(SSHLogParser.parse("debug1: Connecting to example.com [93.184.216.34] port 22.").event
                == .connecting(host: "example.com", address: "93.184.216.34", port: 22))
        #expect(SSHLogParser.parse("debug1: Server host key: ssh-ed25519 SHA256:AbC123+/=").event
                == .serverHostKey(type: "ssh-ed25519", fingerprint: "SHA256:AbC123+/="))
        #expect(SSHLogParser.parse("Authenticated to example.com ([93.184.216.34]:22) using \"publickey\".").event
                == .authenticated(method: "publickey"))
        #expect(SSHLogParser.parse("debug1: Local forwarding listening on 127.0.0.1 port 8080.").event
                == .localForwardListening(port: 8080))
        #expect(SSHLogParser.parse("debug1: remote forward success for: listen 9000, connect localhost:3000").event
                == .remoteForwardSuccess(port: 9000))
        #expect(SSHLogParser.parse("debug1: Entering interactive session.").event == .sessionReady)
    }

    @Test func failures() {
        if case .authFailed = SSHLogParser.parse("deploy@example.com: Permission denied (publickey,password).").event {} else {
            Issue.record("expected authFailed")
        }
        if case .hostKeyProblem = SSHLogParser.parse("Host key verification failed.").event {} else {
            Issue.record("expected hostKeyProblem")
        }
        if case .connectionFailed = SSHLogParser.parse("ssh: connect to host 10.0.0.1 port 22: Connection refused").event {} else {
            Issue.record("expected connectionFailed")
        }
        if case .forwardFailed(let port, let remote, _) = SSHLogParser.parse("Error: remote port forwarding failed for listen port 9000").event {
            #expect(port == 9000)
            #expect(remote)
        } else {
            Issue.record("expected forwardFailed")
        }
        if case .forwardFailed(let port, false, _) = SSHLogParser.parse("channel_setup_fwd_listener_tcpip: cannot listen to port: 8080").event {
            #expect(port == 8080)
        } else {
            Issue.record("expected local forwardFailed")
        }
        if case .disconnected = SSHLogParser.parse("Connection to example.com closed by remote host.").event {} else {
            Issue.record("expected disconnected")
        }
    }

    @Test func configurationErrors() {
        for line in ["command-line: line 0: Bad configuration option: foo",
                     "command-line line 0: invalid time value.",
                     "/Users/me/.ssh/config line 3: Bad configuration option: usekeychainx",
                     "Bad local forwarding specification 'abc:x:1'",
                     "jumphost loop via 127.0.0.1",
                     "Can't open user config file /nonexistent: No such file or directory"] {
            if case .configError = SSHLogParser.parse(line).event {} else { Issue.record("expected configError for \(line)") }
        }
        // Debug chatter about config files is not an error.
        #expect(SSHLogParser.parse("debug1: /etc/ssh/ssh_config line 21: include /etc/ssh/ssh_config.d/* matched no files").event == nil)
        #expect(SSHLogParser.friendlyMessage(for: .configError("jumphost loop via 127.0.0.1")).contains("jump host"))
    }

    @Test func sentenceEnding() {
        #expect(SSHLogParser.sentence("Connection refused") == "Connection refused.")
        #expect(SSHLogParser.sentence("Is SSH running on that port?") == "Is SSH running on that port?")
        #expect(SSHLogParser.sentence("服务器关闭了连接。") == "服务器关闭了连接。")
        #expect(SSHLogParser.sentence("该端口上运行着 SSH 吗？ ") == "该端口上运行着 SSH 吗？")
    }

    @Test func debugNoiseIsNotAFailure() {
        let parsed = SSHLogParser.parse("debug1: Authentications that can continue: publickey,password")
        #expect(parsed.level == .debug)
        #expect(parsed.event == nil)
    }
}

@Suite struct PromptTests {
    @Test func classifiesPrompts() {
        #expect(PromptClassifier.classify("deploy@example.com's password: ") == .password)
        #expect(PromptClassifier.classify("(deploy@example.com) Password: ") == .password)
        #expect(PromptClassifier.classify("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ")
                == .passphrase(keyPath: "/Users/me/.ssh/id_ed25519"))
        #expect(PromptClassifier.classify("Verification code: ") == .other)
        let hostPrompt = """
        The authenticity of host '[localhost]:2222 ([127.0.0.1]:2222)' can't be established.
        ED25519 key fingerprint is SHA256:9pM1f3Rk/abc+def.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        #expect(PromptClassifier.classify(hostPrompt)
                == .hostKey(host: "[localhost]:2222 ([127.0.0.1]:2222)", keyType: "ED25519", fingerprint: "SHA256:9pM1f3Rk/abc+def"))
    }
}

@Suite struct JumpHostPromptTests {
    func tunnel(jumpHost: String = "jump.example.com", jumpUser: String = "ops", host: String = "db.internal", user: String = "deploy") -> Tunnel {
        Tunnel(host: host, user: user, proxy: ProxySettings(kind: .jumpHost, host: jumpHost, port: 22, username: jumpUser))
    }

    @Test func parsesPromptAccount() {
        #expect(PromptClassifier.passwordAccount(in: "ops@jump.example.com's password: ")! == ("ops", "jump.example.com"))
        #expect(PromptClassifier.passwordAccount(in: "(deploy@10.0.0.5) Password: ")! == ("deploy", "10.0.0.5"))
        #expect(PromptClassifier.passwordAccount(in: "Verification code: ") == nil)
    }

    @Test func tellsJumpHostFromServer() {
        let t = tunnel()
        #expect(PromptClassifier.isJumpHostPrompt("ops@jump.example.com's password: ", tunnel: t))
        #expect(PromptClassifier.isJumpHostPrompt("(ops@JUMP.example.com) Password: ", tunnel: t))
        #expect(!PromptClassifier.isJumpHostPrompt("deploy@db.internal's password: ", tunnel: t))
        // No jump host configured: always the server.
        #expect(!PromptClassifier.isJumpHostPrompt("ops@jump.example.com's password: ", tunnel: Tunnel(host: "jump.example.com")))
        // Same machine for both hops: only a different user name marks the jump host.
        let same = tunnel(jumpHost: "bastion", jumpUser: "ops", host: "bastion", user: "deploy")
        #expect(PromptClassifier.isJumpHostPrompt("ops@bastion's password: ", tunnel: same))
        #expect(!PromptClassifier.isJumpHostPrompt("deploy@bastion's password: ", tunnel: same))
    }
}

@Suite struct KeyPathTests {
    @Test func truncatedPromptPathFallsBackToIdentity() {
        let full = "/Users/someone/" + String(repeating: "x", count: 120) + "/id_ed25519"
        let truncated = String(full.prefix(100))
        #expect(PromptClassifier.resolveKeyPath(fromPrompt: truncated, identityFile: full, fileExists: { $0 == full }) == full)
        #expect(PromptClassifier.resolveKeyPath(fromPrompt: "/k/id_rsa", identityFile: "~/.ssh/other", fileExists: { _ in true }) == "/k/id_rsa")
        #expect(PromptClassifier.resolveKeyPath(fromPrompt: nil, identityFile: "/a/b", fileExists: { _ in false }) == "/a/b")
    }
}

@Suite struct ProxyHandshakeTests {
    @Test func socks5ConnectDomain() throws {
        let bytes = try ProxyHandshake.socks5Connect(host: "example.com", port: 22)
        #expect(bytes == [0x05, 0x01, 0x00, 0x03, 11] + Array("example.com".utf8) + [0x00, 0x16])
    }

    @Test func socks5ConnectIPv4() throws {
        let bytes = try ProxyHandshake.socks5Connect(host: "10.1.2.3", port: 443)
        #expect(bytes == [0x05, 0x01, 0x00, 0x01, 10, 1, 2, 3, 0x01, 0xBB])
    }

    @Test func socks5Replies() throws {
        #expect(try ProxyHandshake.parseSocks5MethodSelection([0x05, 0x02]) == 0x02)
        #expect(throws: ProxyHandshake.HandshakeError.authenticationRequired) {
            try ProxyHandshake.parseSocks5MethodSelection([0x05, 0xFF])
        }
        #expect(try ProxyHandshake.parseSocks5ConnectReplyHeader([0x05, 0x00, 0x00, 0x01]) == 6)
        #expect(throws: ProxyHandshake.HandshakeError.rejected("connection refused")) {
            try ProxyHandshake.parseSocks5ConnectReplyHeader([0x05, 0x05, 0x00, 0x01])
        }
    }

    @Test func socks4a() throws {
        let bytes = ProxyHandshake.socks4Request(host: "host", port: 80)
        #expect(bytes == [0x04, 0x01, 0x00, 0x50, 0, 0, 0, 1, 0] + Array("host".utf8) + [0])
        try ProxyHandshake.parseSocks4Reply([0x00, 0x5A, 0, 0, 0, 0, 0, 0])
    }

    @Test func httpConnect() throws {
        let req = ProxyHandshake.httpConnectRequest(host: "example.com", port: 22, username: "u", password: "p")
        #expect(req.hasPrefix("CONNECT example.com:22 HTTP/1.1\r\n"))
        #expect(req.contains("Proxy-Authorization: Basic dTpw\r\n"))
        #expect(req.hasSuffix("\r\n\r\n"))
        try ProxyHandshake.parseHTTPConnectResponse("HTTP/1.1 200 Connection established\r\n\r\n")
        #expect(throws: ProxyHandshake.HandshakeError.authenticationFailed) {
            try ProxyHandshake.parseHTTPConnectResponse("HTTP/1.1 407 Proxy Authentication Required\r\n")
        }
    }
}

@Suite struct ImporterTests {
    @Test func sshConfig() {
        let config = """
        Host *
          ServerAliveInterval 30

        Host prod-db prod
          HostName 10.0.0.5
          User deploy
          Port 2200
          IdentityFile ~/.ssh/prod
          LocalForward 15432 db.internal:5432
          LocalForward 127.0.0.1:16379 [::1]:6379
          DynamicForward 1080

        Host nofwd
          HostName example.com
        """
        let tunnels = SSHConfigImporter.tunnels(fromConfig: config)
        #expect(tunnels.map(\.host) == ["prod-db", "prod"])
        let t = tunnels[0]
        #expect(t.name == "prod-db")
        #expect(t.host == "prod-db")
        #expect(t.port == 2200)
        #expect(t.user == "deploy")
        #expect(t.authMethod == .publicKey)
        #expect(t.forwardings.count == 3)
        #expect(t.forwardings[1].bindAddress == "127.0.0.1")
        #expect(t.forwardings[1].targetHost == "::1")
        #expect(t.forwardings[1].targetPort == 6379)
        #expect(t.forwardings[2].kind == .dynamic)
        #expect(t.forwardings[2].port == 1080)
    }

    @Test func legacyExport() throws {
        let json = """
        [{"uid":"A1","name":"Office","comment":"work","ssh_host":"office.example.com","ssh_port":"2222",
          "ssh_user":"me","auto_connect":true,"auth_methods":["password","publickey"],
          "proxy_command":false,
          "forwardings":[{"type":0,"bind_address":"","port":8080,"host":"intranet","hostport":80,"enabled":true,"note":"wiki"},
                         {"type":2,"bind_address":"127.0.0.1","port":"1080","enabled":true},
                         {"type":1,"port":9000,"host":"localhost","hostport":3000,"enabled":false}]}]
        """
        let tunnels = try LegacySSHTunnelImporter.tunnels(from: Data(json.utf8))
        #expect(tunnels.count == 1)
        let t = tunnels[0]
        #expect(t.name == "Office")
        #expect(t.port == 2222)
        #expect(t.autoConnect)
        #expect(t.authMethod == .publicKey)
        #expect(t.forwardings.map(\.kind) == [.local, .dynamic, .remote])
        #expect(t.forwardings[1].port == 1080)
        #expect(t.forwardings[2].enabled == false)
        #expect(t.forwardings[0].note == "wiki")
    }
}

@Suite struct DocumentTests {
    @Test func roundTripAndTolerantDecoding() throws {
        let doc = PortholeDocument(tunnels: [Tunnel(name: "A", host: "h", forwardings: [Forwarding()])],
                                   smartGroups: [SmartGroup(name: "Work", keywords: "office")])
        let data = try PortholeDocument.encoder().encode(doc)
        let back = try PortholeDocument.decoder().decode(PortholeDocument.self, from: data)
        #expect(back.tunnels == doc.tunnels)
        #expect(back.smartGroups == doc.smartGroups)

        let minimal = #"{"tunnels":[{"host":"only-host"}]}"#
        let decoded = try PortholeDocument.decoder().decode(PortholeDocument.self, from: Data(minimal.utf8))
        #expect(decoded.tunnels.first?.port == 22)
        #expect(decoded.tunnels.first?.autoReconnect == true)
    }

    @Test func keywordMatching() {
        let t = Tunnel(name: "Office VPN", note: "workplace", host: "gw.corp", forwardings: [Forwarding(port: 5432, targetHost: "pg")])
        #expect(t.matches(query: "office"))
        #expect(t.matches(query: "WORKPLACE 5432"))
        #expect(!t.matches(query: "office mysql"))
    }

    @Test func backoff() {
        #expect(ReconnectPolicy.delay(forAttempt: 1) == 2)
        #expect(ReconnectPolicy.delay(forAttempt: 3) == 8)
        #expect(ReconnectPolicy.delay(forAttempt: 9) == 30)
    }
}
