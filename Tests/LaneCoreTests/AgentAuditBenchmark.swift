import Foundation
import LaneCore
@testable import Lane
import Testing

/// Measures synchronous request handling with a seeded history and no SSH or IPC timing.
@MainActor
struct AgentAuditBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANE_TEST_AUDIT_BENCHMARK"] == "1"))
    func requestLatencyWithFinishedHistory() async throws {
        for count in [0, 5_000] {
            let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(path: "lane-audit-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = AgentFiles(directory: directory, socketPath: directory.appending(path: "mcp.sock").path)
            let profile = Tunnel(name: "Fixture", host: "dev.invalid",
                                 forwardings: [Forwarding(bindAddress: "127.0.0.1", port: 3113)])
            let manager = TunnelManager(store: TunnelStore(fileURL: nil, samples: [profile]), demo: true)
            let credential = AgentCredential(clientID: UUID(), token: try AgentFiles.makeToken(), socketPath: files.socketPath)
            let rule = try #require(profile.forwardings.first)
            let prepared = try #require(AgentPreparedRoute(profile: profile, forwarding: rule))
            let share = AgentShare(id: UUID(), profileID: profile.id, forwardingID: rule.id, fingerprint: prepared.key.fingerprint)
            let client = AgentClient(id: credential.clientID, name: "Fixture", tokenDigest: agentDigest(Data(credential.token.utf8)))
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let input = AgentLeaseInput(target: .shared(share.id), purpose: "Seed history", project: nil, ttl: 60)
            let leases = (0..<count).map { number in
                AgentLease(id: UUID(), clientID: client.id, clientName: client.name, requestKey: "history-\(number)",
                           input: input, route: prepared.route, profileID: profile.id, fingerprint: prepared.key.fingerprint,
                           external: nil, state: .released, waitUntil: date, expiresAt: date,
                           events: [.init(at: date, action: .requested, reason: nil), .init(at: date, action: .released, reason: nil)])
            }
            try files.writeLedger(AgentLedger(requestsEnabled: true, clients: [client], shares: [share], leases: leases))
            let access = AgentAccess(manager: manager, files: files)
            try #require(access.history.count == count)

            var samples: [Double] = []
            for index in 0..<4 {
                let request = AgentToolArguments(kind: .shared, idempotencyKey: "sample-\(index)", purpose: "Measure request",
                                                 ruleID: share.id)
                let clock = ContinuousClock()
                let start = clock.now
                let result = await access.handle(AgentToolCall(credential: credential, tool: .request, arguments: request))
                let elapsed = start.duration(to: clock.now).components
                let lease = try #require(result.lease)
                #expect(lease.state == .ready)
                if index > 0 {
                    samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
                }
                try access.end(lease.id)
            }
            print(String(format: "AUDIT %d records, median %.3f ms", count, samples.sorted()[1]))
        }
    }
}
