import CryptoKit
import Darwin
import Foundation
import LaneCore

/// The local identity used to authorize calls and attribute their audit events.
struct AgentClient: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let tokenDigest: String
}

struct AgentShare: Codable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    let forwardingID: UUID
    let fingerprint: String
}

struct AgentRoute: Codable, Equatable, Sendable {
    let name: String
    let sshHost: String?
    let listenAddress: String
    let destination: String?

    enum CodingKeys: String, CodingKey {
        case name, sshHost = "ssh_host", listenAddress = "listen_address", destination
    }
}

/// An isolated launch contains precisely the validated rule, including after a reconnect.
struct AgentPreparedRoute {
    struct Key: Hashable {
        let profileID: UUID
        let fingerprint: String
    }

    let key: Key
    let tunnel: Tunnel
    let rule: Forwarding
    let route: AgentRoute

    init?(profile: Tunnel, forwarding: Forwarding) {
        guard forwarding.enabled, forwarding.kind == .local,
              let bind = Self.loopback(forwarding.bindAddress),
              let target = Self.targetHost(forwarding.targetHost) else { return nil }
        var rule = forwarding
        rule.bindAddress = bind
        rule.targetHost = target
        var isolated = profile
        isolated.forwardings = [rule]
        isolated.autoConnect = false
        guard !TunnelValidator.validate(isolated).contains(where: { $0.severity == .error }),
              let arguments = try? JSONEncoder().encode(SSHCommandBuilder().arguments(for: isolated)) else { return nil }
        self.rule = rule
        tunnel = isolated
        key = Key(profileID: profile.id, fingerprint: agentDigest(arguments))
        route = AgentRoute(name: "\(profile.displayName) · \(rule.displayName)", sshHost: profile.hostNotation,
                           listenAddress: rule.listenDisplayAddress, destination: rule.targetDisplayAddress)
    }

    /// Explicit numeric binds prevent a user's GatewayPorts setting from widening an Agent listener.
    static func loopback(_ host: String) -> String? {
        switch host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "localhost", "127.0.0.1": "127.0.0.1"
        case "::1", "[::1]": "::1"
        default: nil
        }
    }

    /// A forwarding destination is a TCP host, never a socket path or an SSH option.
    static func targetHost(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard host.utf8.count <= 253, TunnelValidator.isValidHostToken(host) else { return nil }
        let dnsCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if host.unicodeScalars.allSatisfy(dnsCharacters.contains) { return host.lowercased() }
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1 ? host.lowercased() : nil
    }
}

/// External evidence is held separately from ownership and rechecked before returning an address.
struct AgentExternalEvidence: Codable, Equatable, Sendable {
    let pid: Int32
    let route: AgentRoute

    init?(session: ExternalSession, rule: ExternalSession.Rule) {
        guard let listener = rule.listener, ["127.0.0.1", "::1"].contains(listener.host),
              let forward = rule.forward, forward.kind == .local else { return nil }
        pid = session.id
        route = AgentRoute(name: session.host ?? "OpenSSH", sshHost: session.host,
                           listenAddress: listener.address, destination: forward.targetDisplayAddress)
    }
}

struct AgentLeaseInput: Codable, Equatable, Sendable {
    enum Target: Codable, Equatable, Sendable {
        case shared(UUID)
        case temporary(profileID: UUID, host: String, port: Int, bind: String, listenPort: Int)
        case external(String)
    }

    let target: Target
    let purpose: String
    let project: String?
    let ttl: Int
}

/// One lease stores route metadata and the audit trail across app restarts.
struct AgentLease: Codable, Identifiable, Sendable {
    // Keep the former approval states, actions, and reasons decodable for existing audit files.
    enum State: String, Codable, Sendable {
        case pendingApproval = "pending_approval"
        case connecting, ready, reconnecting, denied, failed, released, expired, ended

        var isOpen: Bool {
            switch self {
            case .pendingApproval, .connecting, .ready, .reconnecting: true
            default: false
            }
        }
    }

    enum Action: String, Codable, Sendable {
        case requested, authorized, approved, denied, connected, reused, reconnected, released, expired, failed, ended
        case reconnecting
    }

    enum Reason: String, Codable, Sendable {
        case userDenied = "user_denied"
        case userEnded = "user_ended"
        case accessDisabled = "access_disabled"
        case clientRevoked = "client_revoked"
        case routeChanged = "route_changed"
        case externalGone = "external_listener_gone"
        case sshFailed = "ssh_failed"
        case startupTimedOut = "startup_timed_out"
        case approvalTimedOut = "approval_timed_out"
        case appQuit = "app_quit"
        case appRestarted = "app_restarted"
    }

    struct Event: Codable, Identifiable, Sendable {
        let id = UUID()
        let at: Date
        let action: Action
        let reason: Reason?

        private enum CodingKeys: CodingKey { case at, action, reason }
    }

    let id: UUID
    let clientID: UUID
    let clientName: String
    let requestKey: String
    let input: AgentLeaseInput
    let route: AgentRoute
    let profileID: UUID?
    let fingerprint: String?
    let external: AgentExternalEvidence?
    var state: State
    let waitUntil: Date
    var expiresAt: Date?
    var reusesExistingConnection = false
    var events: [Event]

    var connectionKey: AgentPreparedRoute.Key? {
        guard let profileID, let fingerprint else { return nil }
        return AgentPreparedRoute.Key(profileID: profileID, fingerprint: fingerprint)
    }
    var reason: Reason? { events.last?.reason }

    mutating func move(to state: State, action: Action, at date: Date, reason: Reason? = nil) {
        self.state = state
        events.append(Event(at: date, action: action, reason: reason))
    }

    mutating func makeReady(action: Action, at date: Date) {
        if expiresAt == nil { expiresAt = date.addingTimeInterval(TimeInterval(input.ttl)) }
        move(to: .ready, action: action, at: date)
    }
}

/// One atomically persisted snapshot keeps lease state and its audit events in step.
struct AgentLedger: Codable {
    var requestsEnabled = false
    var clients: [AgentClient] = []
    var shares: [AgentShare] = []
    var leases: [AgentLease] = []
}

func agentDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
