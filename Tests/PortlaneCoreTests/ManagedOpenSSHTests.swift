import AppKit
import Darwin
import Foundation
import PortlaneCore
@testable import Portlane
import Testing

/// Runs against an opt-in loopback fixture. Normal unit tests never open SSH connections.
@Suite(.serialized)
struct ManagedOpenSSHTests {
    private struct Fixture: Decodable {
        let sshPort: Int
        let webPort: Int
        let localPort: Int
        let remotePort: Int
        let socksPort: Int
        let externalPID: Int32
        let externalPorts: [Int]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORTLANE_SSH_FIXTURE"] != nil))
    func relaysTheActualHostKeyPromptAndRejectsAChangedKey() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["PORTLANE_SSH_FIXTURE"])
        let helper = try #require(environment["PORTLANE_TEST_HELPER"])
        let directory = URL(fileURLWithPath: path)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
        let trustFile = directory.appending(path: "host-key-test")
        let observations = TrustObservations()
        let server = AskpassServer { request in await observations.reply(to: request) }
        try server.start()
        defer { server.stop() }

        func authenticate() throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-F", "/dev/null", "-p", String(fixture.sshPort), "-o", "StrictHostKeyChecking=ask",
                                 "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UserKnownHostsFile=\(trustFile.path)",
                                 "-o", "IdentitiesOnly=yes", "-i", directory.appending(path: "client_ed25519").path,
                                 "--", "\(NSUserName())@127.0.0.1", "/usr/bin/true"]
            process.environment = [
                "SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0",
                AskpassEnvironment.socketPath: server.socketPath, AskpassEnvironment.token: server.token,
                AskpassEnvironment.tunnelID: "loopback-host-key-test",
            ]
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        #expect(try authenticate().0 != 0)
        #expect(!FileManager.default.fileExists(atPath: trustFile.path))
        #expect(try authenticate().0 == 0)
        let prompts = await observations.prompts
        #expect(prompts.count == 2)
        let observed = try #require(prompts.first)
        if case .hostKey(_, _, let fingerprint) = observed {
            #expect(fingerprint?.hasPrefix("SHA256:") == true)
            #expect(fingerprint?.count == 50)
        } else {
            Issue.record("OpenSSH did not send a recognizable host key prompt")
        }
        let wrongKey = try String(contentsOf: directory.appending(path: "client_ed25519.pub"), encoding: .utf8)
        try "[127.0.0.1]:\(fixture.sshPort) \(wrongKey)".write(to: trustFile, atomically: true, encoding: .utf8)
        let (status, output) = try authenticate()
        #expect(status != 0)
        #expect(output.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
        #expect(await observations.prompts.count == 2)
    }

    private actor TrustObservations {
        private(set) var prompts: [PromptKind] = []

        /// First cancel and then explicitly trust the disposable host.
        func reply(to request: AskpassRequest) -> AskpassReply {
            let kind = PromptClassifier.classify(request.prompt)
            prompts.append(kind)
            guard case .hostKey = kind, prompts.count == 2 else { return .cancelled }
            return AskpassReply(ok: true, answer: "yes")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORTLANE_SSH_FIXTURE"] != nil))
    @MainActor
    func opensAllModesAndLeavesExternalOwnerAlone() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PORTLANE_SSH_FIXTURE"])
        let directory = URL(fileURLWithPath: path)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
        let rules = [
            Forwarding(bindAddress: "127.0.0.1", port: fixture.localPort, targetHost: "127.0.0.1", targetPort: fixture.webPort),
            Forwarding(kind: .remote, bindAddress: "127.0.0.1", port: fixture.remotePort,
                       targetHost: "127.0.0.1", targetPort: fixture.webPort),
            Forwarding(kind: .dynamic, bindAddress: "127.0.0.1", port: fixture.socksPort)
        ]
        var tunnel = Tunnel(name: "Loopback fixture", host: "127.0.0.1", port: fixture.sshPort,
                            user: NSUserName(), authMethod: .publicKey, identityFile: directory.appending(path: "client_ed25519").path,
                            forwardings: rules, autoConnect: true, autoReconnect: true, hostKeyPolicy: .strict, useSSHConfig: false,
                            extraOptions: "UserKnownHostsFile=\(directory.appending(path: "known_hosts").path)\nGlobalKnownHostsFile=/dev/null")
        let database = directory.appending(path: "tunnels.json")
        let store = TunnelStore(fileURL: database)
        try store.save(tunnel)
        let preferences = PortlanePreferences()
        let alternateClient = directory.appending(path: "alternate ssh")
        try FileManager.default.createSymbolicLink(at: alternateClient, withDestinationURL: URL(fileURLWithPath: "/usr/bin/ssh"))
        preferences.customSSHPath = alternateClient.path
        let manager = TunnelManager(store: store, preferences: preferences)
        defer { manager.shutdown() }
        manager.connectOnLaunch()
        let runtime = manager.runtime(tunnel.id)
        try await waitFor { runtime.state.isConnected || runtime.state.isFailure }
        try #require(runtime.state.isConnected, "SSH output: \(runtime.logs.map(\.message).joined(separator: "\n"))")
        let pid = try #require(runtime.pid)
        #expect(runtime.forwardStatus.values.allSatisfy { $0 == .active })
        #expect(runtime.logs.contains { $0.message.contains(alternateClient.path) })
        #expect(try request(["http://127.0.0.1:\(fixture.localPort)/direct"]) == "portlane-fixture")
        #expect(try request(["http://127.0.0.1:\(fixture.remotePort)/remote"]) == "portlane-fixture")
        #expect(try request(["--socks5-hostname", "127.0.0.1:\(fixture.socksPort)", "http://127.0.0.1:\(fixture.webPort)/socks"]) == "portlane-fixture")

        preferences.customSSHPath = ""
        tunnel.name = "Metadata only"
        tunnel.forwardings[0].note = "A note"
        let previous = try store.save(tunnel)
        manager.tunnelDidChange(tunnel, previous: previous)
        #expect(runtime.pid == pid)
        #expect(TunnelStore(fileURL: database).tunnel(tunnel.id)?.forwardings[0].note == "A note")

        // Exercise the wake preference without putting the test Mac to sleep.
        let workspaceEvents = NSWorkspace.shared.notificationCenter
        preferences.reconnectOnWake = false
        workspaceEvents.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(runtime.pid == pid)
        preferences.reconnectOnWake = true
        workspaceEvents.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitFor { runtime.state.isConnected && runtime.pid != pid }
        let awakePID = try #require(runtime.pid)
        #expect(runtime.logs.last(where: { $0.message.hasPrefix("$ ") })?.message.hasPrefix("$ /usr/bin/ssh ") == true)

        let snapshot = try ExternalScanner.scan(excluding: manager.runningPIDs)
        #expect(!snapshot.contains(where: { $0.id == awakePID }))
        let external = try #require(snapshot.first { $0.id == fixture.externalPID })
        #expect(external.rules.compactMap { $0.listener?.port }.sorted() == fixture.externalPorts.sorted())
        #expect(external.rules.allSatisfy { $0.forward?.kind == .local && $0.forward?.targetPort == fixture.webPort })

        let conflict = Forwarding(bindAddress: "127.0.0.1", port: fixture.externalPorts[0],
                                  targetHost: "127.0.0.1", targetPort: fixture.webPort)
        let second = Tunnel(host: "127.0.0.1", port: fixture.sshPort, forwardings: [conflict], autoReconnect: false, useSSHConfig: false)
        try store.save(second)
        manager.connect(second.id)
        let blocked = manager.runtime(second.id)
        try await waitFor { blocked.state.isFailure }
        if case .failed = blocked.forwardStatus[conflict.id] {} else { Issue.record("Conflict must identify the blocked rule") }
        #expect(runtime.pid == awakePID)

        // Dropping our fixture master exercises the real process exit and retry path.
        try #require(kill(awakePID, SIGTERM) == 0)
        try await waitFor { if case .reconnecting = runtime.state { return true }; return false }
        try await waitFor { runtime.state == .connected && runtime.pid != awakePID }
        let replacement = try #require(runtime.pid)
        try #require(kill(replacement, SIGTERM) == 0)
        try await waitFor { if case .reconnecting = runtime.state { return true }; return false }
        manager.disconnect(tunnel.id)
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(runtime.state == .off)
        #expect(runtime.pid == nil)
        #expect(try request(["http://127.0.0.1:\(fixture.externalPorts[0])/external"]) == "portlane-fixture")
    }

    /// Real listeners exercise the isolation boundary on launch, reconnect, release, and expiration.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PORTLANE_SSH_FIXTURE"] != nil))
    @MainActor
    func mcpLeasesShareOnlyTheAuthorizedListenerAndReapItAfterLastUse() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["PORTLANE_SSH_FIXTURE"]))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
        let rule = Forwarding(bindAddress: "127.0.0.1", port: fixture.localPort, targetHost: "127.0.0.1", targetPort: fixture.webPort)
        let sibling = Forwarding(bindAddress: "127.0.0.1", port: fixture.socksPort, targetHost: "127.0.0.1", targetPort: fixture.webPort)
        let profile = Tunnel(name: "MCP fixture", host: "127.0.0.1", port: fixture.sshPort, user: NSUserName(),
                             authMethod: .publicKey, identityFile: directory.appending(path: "client_ed25519").path,
                             forwardings: [rule, sibling], autoReconnect: true, hostKeyPolicy: .strict, useSSHConfig: false,
                             extraOptions: "UserKnownHostsFile=\(directory.appending(path: "known_hosts").path)\nGlobalKnownHostsFile=/dev/null\nGatewayPorts=yes")
        let manager = TunnelManager(store: TunnelStore(fileURL: nil, samples: [profile]))
        let files = AgentFiles(directory: directory.appending(path: "agent"), socketPath: directory.appending(path: "mcp.sock").path)
        let access = AgentAccess(manager: manager, files: files)
        access.start()
        defer {
            access.shutdown()
            manager.shutdown()
        }
        let first = try access.pair("Codex fixture")
        let second = try access.pair("Claude fixture")
        let helper = try #require(environment["PORTLANE_TEST_MCP_HELPER"] ?? environment["PORTLANE_TEST_HELPER"])
        let config = try #require(access.configuration(for: first.id, executable: helper))
        #expect(try await config.check() == false)
        try access.setRequestsEnabled(true)
        try access.setClientRequests(first.id, enabled: true)
        try access.setClientRequests(second.id, enabled: true)
        try access.setShared(rule, from: profile, enabled: true)
        let ruleID = try #require(access.ledger.shares.first?.id)
        #expect(try await config.check() == true)
        if let client = environment["PORTLANE_TEST_MCP_CLIENT"] {
            try await runExternalMCPClient(client, configuration: config, directory: directory)
            try await waitFor { manager.runningPIDs.isEmpty }
        }

        func call(_ client: AgentClient, _ tool: AgentTool, _ arguments: AgentToolArguments) async throws -> AgentToolResult {
            let credential = try JSONDecoder().decode(AgentCredential.self, from: Data(contentsOf: files.credentialURL(client.id)))
            return await access.handle(AgentToolCall(credential: credential, tool: tool, arguments: arguments))
        }
        let arguments = AgentToolArguments(kind: .shared, idempotencyKey: "shared-route", purpose: "Verify local forwarding", ruleID: ruleID)
        let original = try #require(try await call(first, .request, arguments).lease)
        let reused = try #require(try await call(second, .request, arguments).lease)
        #expect(original.state == .connecting)
        #expect(original.address == nil)
        #expect(original.id != reused.id)
        #expect(manager.runtimes.values.count == 1)
        let runtime = try #require(manager.runtimes.values.first)

        try await waitFor { runtime.state.isConnected || runtime.state.isFailure }
        try #require(runtime.state.isConnected, "SSH output: \(runtime.logs.map(\.message).joined(separator: "\n"))")
        let pid = try #require(runtime.pid)
        #expect(try ExternalScanner.listeners(pids: [pid]).map(\.address) == ["127.0.0.1:\(fixture.localPort)"])
        #expect(try request(["http://127.0.0.1:\(fixture.localPort)/agent"]) == "portlane-fixture")
        let firstLookup = AgentToolArguments(leaseID: original.id)
        let secondLookup = AgentToolArguments(leaseID: reused.id)
        #expect(try await call(first, .status, firstLookup).lease?.address == "127.0.0.1:\(fixture.localPort)")
        #expect(try await call(second, .status, secondLookup).lease?.state == .ready)
        #expect(try await call(second, .status, firstLookup).error?.code == "not_found")

        try #require(kill(pid, SIGTERM) == 0)
        try await waitFor { if case .reconnecting = runtime.state { return true }; return false }
        let reconnecting = try await call(first, .status, firstLookup).lease
        #expect(reconnecting?.state == .reconnecting)
        #expect(reconnecting?.address == nil)
        try await waitFor { runtime.state.isConnected && runtime.pid != pid }
        let reconnectedPID = try #require(runtime.pid)
        #expect(try ExternalScanner.listeners(pids: [reconnectedPID]).map(\.port) == [fixture.localPort])
        #expect(try await call(first, .release, firstLookup).lease?.state == .released)
        #expect(try await call(second, .status, secondLookup).lease?.state == .ready)
        #expect(runtime.pid == reconnectedPID)

        var expiringArguments = arguments
        expiringArguments.idempotencyKey = "expire-route"
        expiringArguments.ttlSeconds = 1
        let expiring = try #require(try await call(first, .request, expiringArguments).lease)
        #expect(expiring.state == .ready)
        try access.end(reused.id)
        #expect(runtime.pid == reconnectedPID)
        try await waitFor { runtime.state == .off }
        #expect(try ExternalScanner.listeners(pids: [reconnectedPID]).isEmpty)
        #expect(access.history.first?.id == expiring.id)
        #expect(access.history.first?.state == .expired)

        let temporaryArgs = AgentToolArguments(kind: .temporary, idempotencyKey: "conflict", purpose: "Verify port conflict audit",
                                               profileID: profile.id, listenPort: fixture.externalPorts[0],
                                               targetHost: "127.0.0.1", targetPort: fixture.webPort)
        let blocked = try #require(try await call(first, .request, temporaryArgs).lease)
        #expect(blocked.state == .pendingApproval)
        #expect(manager.runningPIDs.isEmpty)
        try await access.approve(blocked.id)
        try await waitFor { access.history.first?.id == blocked.id }
        #expect(access.history.first?.state == .failed)
        #expect(access.history.first?.events.map(\.action) == [.requested, .approved, .failed])

        var externalArgs = AgentToolArguments(kind: .external, idempotencyKey: "external", purpose: "Reuse external loopback")
        externalArgs.externalAddress = "127.0.0.1:\(fixture.externalPorts[0])"
        let external = try #require(try await call(first, .request, externalArgs).lease)
        #expect(external.state == .pendingApproval)
        #expect(external.address == nil)
        try await access.approve(external.id)
        let externalLookup = AgentToolArguments(leaseID: external.id)
        #expect(try await call(first, .status, externalLookup).lease?.state == .ready)
        #expect(try await call(first, .release, externalLookup).lease?.state == .released)
        #expect(try request(["http://127.0.0.1:\(fixture.externalPorts[0])/agent-external"]) == "portlane-fixture")
        #expect(access.history.first?.events.map(\.action) == [.requested, .approved, .reused, .released])
    }

    /// An opt-in client can exercise the exact JSON users get from Settings against this fixture.
    private func runExternalMCPClient(_ client: String, configuration: AgentMCPConfiguration, directory: URL) async throws {
        let recipe = directory.appending(path: "mcp.json")
        try configuration.json.write(to: recipe, atomically: true, encoding: .utf8)
        let status = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: client)
            process.arguments = [recipe.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        try #require(status == 0)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition(), "Timed out waiting for SSH state")
    }

    private func request(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--fail", "--max-time", "4", "--noproxy", ""] + arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let body = String(decoding: data, as: UTF8.self)
        try #require(process.terminationStatus == 0, Comment(rawValue: body))
        return body
    }
}
