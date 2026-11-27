import Foundation
import PortlaneCore
@testable import Portlane
import Testing

/// Exercises Agent policy and persisted activity independently of a real SSH server.
@MainActor
struct AgentAccessTests {
    @Test
    func pairingRequiresBothPermissionsAndLeasesArePrivateAndIdempotent() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let first = try rig.pair("Codex")
        let second = try rig.pair("Claude Code")
        let rule = try rig.share()
        let request = AgentToolArguments(kind: .shared, idempotencyKey: "postgres", purpose: "Inspect local test data", ruleID: rule)

        let listed = await rig.call(first, .list)
        #expect(listed.canRequest == false)
        #expect(listed.rules?.map(\.id) == [rule])
        #expect(await rig.call(first, .request, request).error?.code == "read_only")
        try rig.access.setRequestsEnabled(true)
        #expect(await rig.call(first, .request, request).error?.code == "read_only")

        try rig.access.setClientRequests(first.clientID, enabled: true)
        let opened = try #require(await rig.call(first, .request, request).lease)
        #expect(opened.state == .ready)
        #expect(opened.address == "127.0.0.1:3113")
        #expect(rig.manager.runtimes.values.filter(\.isAgentOwned).count == 1)
        #expect(await rig.call(first, .request, request).lease?.id == opened.id)
        let lookup = AgentToolArguments(leaseID: opened.id)
        #expect(await rig.call(second, .status, lookup).error?.code == "not_found")
        #expect(await rig.call(second, .release, lookup).error?.code == "not_found")
        let impostor = AgentCredential(clientID: first.clientID, token: "invalid", socketPath: first.socketPath)
        #expect(await rig.call(impostor, .list).error?.code == "not_paired")

        var different = request
        different.purpose = "A different request"
        #expect(await rig.call(first, .request, different).error?.code == "idempotency_conflict")
        let released = await rig.call(first, .release, lookup).lease
        #expect(released?.state == .released)
        #expect(released?.address == nil)
        #expect(await rig.call(first, .release, lookup).lease?.state == .released)
        #expect(rig.access.history.first?.events.map(\.action) == [.requested, .authorized, .connected, .released])
        #expect(rig.manager.runtimes.values.filter(\.isAgentOwned).isEmpty)

        let stored = try String(contentsOf: rig.files.ledger, encoding: .utf8)
        #expect(!stored.contains(first.token))
        #expect(!stored.contains(second.token))
    }

    @Test
    func temporaryRoutesRequireApprovalAndOnlyValidLoopbackTCPRoutesAreAccepted() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let credential = try rig.pair("Test client", canRequest: true)
        var request = AgentToolArguments(kind: .temporary, idempotencyKey: "temp", purpose: "Preview",
                                        project: "Example", ttlSeconds: 2, profileID: rig.profile.id,
                                        listenHost: "0.0.0.0", listenPort: 4001, targetHost: "localhost", targetPort: 8080)
        #expect(await rig.call(credential, .request, request).error?.code == "invalid_arguments")
        request.listenHost = "127.0.0.1"
        request.targetHost = "/var/run/service.sock"
        #expect(await rig.call(credential, .request, request).error?.code == "invalid_arguments")
        request.targetHost = "::1"

        let approval = try #require(await rig.call(credential, .request, request).lease)
        #expect(approval.state == .pendingApproval)
        #expect(approval.address == nil)
        #expect(rig.manager.runtimes.isEmpty)
        #expect(rig.access.pending.first?.route.destination == "[::1]:8080")
        try await rig.access.approve(approval.id)
        let ready = try #require(await rig.call(credential, .status, AgentToolArguments(leaseID: approval.id)).lease)
        #expect(ready.state == .ready)
        #expect(ready.address == "127.0.0.1:4001")

        let expiresAt = try #require(ready.expiresAt)
        try rig.access.reconcile(at: expiresAt.addingTimeInterval(0.01))
        #expect(rig.access.history.first?.events.map(\.action) == [.requested, .approved, .connected, .expired])
        #expect(rig.manager.runtimes.isEmpty)

        request.idempotencyKey = "denied"
        let denied = try #require(await rig.call(credential, .request, request).lease)
        try rig.access.deny(denied.id)
        #expect(await rig.call(credential, .status, AgentToolArguments(leaseID: denied.id)).lease?.state == .denied)
        #expect(rig.manager.runtimes.isEmpty)
    }

    @Test
    func ruleEditsInvalidateSharingAndReopenedAuditEndsOutstandingLeases() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let client = try rig.pair("Test client", canRequest: true)
        var rule = try rig.share()
        var request = AgentToolArguments(kind: .shared, idempotencyKey: "before-edit", purpose: "Test", ruleID: rule)
        let first = try #require(await rig.call(client, .request, request).lease)
        var changed = rig.profile
        changed.forwardings[0].targetPort = 5432
        try rig.manager.store.save(changed)
        rig.access.libraryChanged()
        #expect(rig.access.history.first?.id == first.id)
        #expect(rig.access.history.first?.reason == .routeChanged)
        #expect(rig.manager.runtimes.isEmpty)
        try rig.manager.store.save(rig.profile)
        #expect(await rig.call(client, .list).rules?.isEmpty == true)

        rule = try rig.share()
        request.ruleID = rule
        request.idempotencyKey = "after-edit"
        let second = try #require(await rig.call(client, .request, request).lease)
        #expect(second.state == .ready)
        let reopened = AgentAccess(manager: TunnelManager(store: rig.manager.store, demo: true), files: rig.files)
        #expect(reopened.history.count == 2)
        #expect(reopened.history.first?.id == second.id)
        #expect(reopened.history.first?.reason == .appRestarted)
        #expect(reopened.active.isEmpty)
        let prior = await reopened.handle(AgentToolCall(credential: client, tool: .status, arguments: AgentToolArguments(leaseID: second.id)))
        #expect(prior.lease?.state == .ended)
        #expect(prior.lease?.address == nil)
    }

    @Test
    func revokingOneClientKeepsTheOtherLeaseAndTheManualOwner() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let first = try rig.pair("Codex", canRequest: true)
        let second = try rig.pair("Claude Code", canRequest: true)
        rig.manager.connect(rig.profile.id)
        let rule = try rig.share()
        let request = AgentToolArguments(kind: .shared, idempotencyKey: "common", purpose: "Test", ruleID: rule)
        let firstLease = try #require(await rig.call(first, .request, request).lease)
        let secondLease = try #require(await rig.call(second, .request, request).lease)
        #expect(firstLease.id != secondLease.id)
        #expect(rig.manager.runtimes.values.allSatisfy { !$0.isAgentOwned })
        #expect(rig.access.active.allSatisfy { rig.access.borrowed($0) })
        try rig.access.revokeClient(first.clientID)
        #expect(await rig.call(first, .list).error?.code == "not_paired")
        #expect(!FileManager.default.fileExists(atPath: rig.files.credentialURL(first.clientID).path))
        #expect(rig.access.history.first?.reason == .clientRevoked)
        #expect(await rig.call(second, .status, AgentToolArguments(leaseID: secondLease.id)).lease?.state == .ready)
        try rig.access.end(secondLease.id)
        #expect(rig.manager.state(rig.profile.id) == .connected)
        #expect(rig.access.active.isEmpty)
    }

    @Test
    func generatedRecipesPreserveTheExecutableAndArguments() throws {
        let config = AgentMCPConfiguration(executable: "/Applications/Portlane Beta.app/Contents/MacOS/Portlane",
                                          credentialFile: "/tmp/Dong's Pairing/one.pairing")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(config.json.utf8)) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: [String: Any]])
        let entry = try #require(servers["portlane"])
        #expect(entry["command"] as? String == config.executable)
        #expect(entry["args"] as? [String] == config.args)
        #expect(entry["env"] == nil)
        #expect(config.codexCommand == "codex mcp add portlane -- '/Applications/Portlane Beta.app/Contents/MacOS/Portlane' --mcp-stdio --credential-file '/tmp/Dong'\\''s Pairing/one.pairing'")
        #expect(config.claudeCommand.hasPrefix("claude mcp add --transport stdio --scope user portlane -- "))
        #expect(config.cursorJSON.contains(#""stdio""#))
    }

    @MainActor
    private struct Rig {
        let files: AgentFiles
        let profile: Tunnel
        let manager: TunnelManager
        let access: AgentAccess

        init() throws {
            let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(path: "pl-test-\(UUID())")
            files = AgentFiles(directory: root, socketPath: root.appending(path: "mcp.sock").path)
            profile = Tunnel(name: "Development", host: "dev", forwardings: [
                Forwarding(bindAddress: "127.0.0.1", port: 3113, targetHost: "localhost", targetPort: 3113),
                Forwarding(kind: .remote, bindAddress: "127.0.0.1", port: 3111, targetHost: "localhost", targetPort: 3111),
            ])
            manager = TunnelManager(store: TunnelStore(fileURL: nil, samples: [profile]), demo: true)
            access = AgentAccess(manager: manager, files: files)
        }

        func pair(_ name: String, canRequest: Bool = false) throws -> AgentCredential {
            let client = try access.pair(name)
            if canRequest {
                try access.setRequestsEnabled(true)
                try access.setClientRequests(client.id, enabled: true)
            }
            return try JSONDecoder().decode(AgentCredential.self, from: Data(contentsOf: files.credentialURL(client.id)))
        }

        func share() throws -> UUID {
            try access.setShared(profile.forwardings[0], from: profile, enabled: true)
            return try #require(access.ledger.shares.first?.id)
        }

        func call(_ credential: AgentCredential, _ tool: AgentTool, _ arguments: AgentToolArguments = .init()) async -> AgentToolResult {
            await access.handle(AgentToolCall(credential: credential, tool: tool, arguments: arguments))
        }

        func clean() {
            try? FileManager.default.removeItem(at: files.directory)
        }
    }
}
