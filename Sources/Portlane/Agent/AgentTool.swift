import Foundation
import PortlaneCore

/// The four Agent operations are shared by the stdio adapter and the single-instance app.
enum AgentTool: String, Codable, CaseIterable, Sendable {
    case list = "portlane_list"
    case request = "portlane_request"
    case status = "portlane_status"
    case release = "portlane_release"

    var definition: [String: Any] {
        let description: String
        let properties: [String: Any]
        let required: [String]
        func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        func port(_ description: String) -> [String: Any] {
            ["type": "integer", "minimum": 1, "maximum": 65_535, "description": description]
        }
        switch self {
        case .list:
            description = "List local SSH forwarding rules explicitly shared in Portlane and check whether this pairing can request leases."
            properties = [:]
            required = []
        case .request:
            description = """
                Request a time-limited local SSH forwarding lease. Use a shared rule ID from portlane_list, or request approval for a \
                temporary destination through a saved SSH profile or a known external loopback address. Use portlane_status until ready \
                and portlane_release when the work is done.
                """
            properties = [
                "kind": ["type": "string", "enum": ["shared", "temporary", "external"]],
                "idempotency_key": string("Stable unique key for this attempt. Retry with the same key and inputs."),
                "purpose": string("Short reason shown to the user. Keep credentials out of this field."),
                "project": string("Optional project label supplied by the client. Keep credentials out of this field."),
                "ttl_seconds": ["type": "integer", "minimum": 1, "maximum": 3_600, "default": 900,
                                "description": "Lease duration from first readiness."],
                "rule_id": string("Required for shared. Use an ID from portlane_list."),
                "profile_id": string("Required for temporary. Use a saved SSH profile ID copied in Portlane Settings."),
                "listen_host": ["type": "string", "enum": ["127.0.0.1", "::1"], "default": "127.0.0.1"],
                "listen_port": port("Required for temporary. Port to listen on this Mac."),
                "target_host": string("Required for temporary. TCP host as seen by the SSH server."),
                "target_port": port("Required for temporary. TCP port as seen by the SSH server."),
                "external_address": string("Required for external. Exact observed loopback address, e.g. 127.0.0.1:3113."),
            ]
            required = ["kind", "idempotency_key", "purpose"]
        case .status:
            description = """
                Get the current state of a lease owned by this pairing. Use its address only when state is ready. \
                Readiness confirms a local listener; it does not probe the destination application.
                """
            properties = ["lease_id": string("Lease ID returned by portlane_request.")]
            required = ["lease_id"]
        case .release:
            description = "Release a lease owned by this pairing. The release is idempotent."
            properties = ["lease_id": string("Lease ID returned by portlane_request.")]
            required = ["lease_id"]
        }
        let isReadOnly = self == .list || self == .status
        return [
            "name": rawValue,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
            "annotations": ["readOnlyHint": isReadOnly, "destructiveHint": self == .release, "idempotentHint": true,
                            "openWorldHint": !isReadOnly],
        ]
    }

    func decode(_ arguments: [String: Any]) throws -> AgentToolArguments {
        guard let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              arguments.keys.allSatisfy({ properties[$0] != nil }) else {
            throw AgentToolError.invalidArguments
        }
        do {
            return try JSONDecoder().decode(AgentToolArguments.self, from: JSONSerialization.data(withJSONObject: arguments))
        } catch {
            throw AgentToolError.invalidArguments
        }
    }
}

/// Tool arguments contain user intent only. SSH commands and credentials cannot be passed here.
struct AgentToolArguments: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case shared, temporary, external }

    var kind: Kind?
    var idempotencyKey: String?
    var purpose: String?
    var project: String?
    var ttlSeconds: Int?
    var ruleID: UUID?
    var profileID: UUID?
    var listenHost: String?
    var listenPort: Int?
    var targetHost: String?
    var targetPort: Int?
    var externalAddress: String?
    var leaseID: UUID?

    enum CodingKeys: String, CodingKey {
        case kind, purpose, project
        case idempotencyKey = "idempotency_key", ttlSeconds = "ttl_seconds", ruleID = "rule_id", profileID = "profile_id"
        case listenHost = "listen_host", listenPort = "listen_port", targetHost = "target_host", targetPort = "target_port"
        case externalAddress = "external_address", leaseID = "lease_id"
    }

    /// Normalize before the idempotency comparison so retries identify the same intent.
    func leaseInput() throws -> (String, AgentLeaseInput) {
        let key = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let purpose = purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ttl = ttlSeconds ?? 900
        guard !key.isEmpty, key.utf8.count <= 96, !purpose.isEmpty, purpose.utf8.count <= 720,
              (project?.utf8.count ?? 0) <= 360, (1...3_600).contains(ttl), let kind else {
            throw AgentToolError.invalidArguments
        }
        let target: AgentLeaseInput.Target
        let hasTemporaryFields = profileID != nil || listenHost != nil || listenPort != nil || targetHost != nil || targetPort != nil
        switch kind {
        case .shared:
            guard let ruleID, !hasTemporaryFields, externalAddress == nil else { throw AgentToolError.invalidArguments }
            target = .shared(ruleID)
        case .temporary:
            let bind = listenHost ?? "127.0.0.1"
            guard ruleID == nil, externalAddress == nil, let profileID,
                  let host = targetHost.flatMap(AgentPreparedRoute.targetHost), let targetPort, let listenPort,
                  TunnelValidator.isValidPort(targetPort), TunnelValidator.isValidPort(listenPort),
                  ["127.0.0.1", "::1"].contains(bind) else { throw AgentToolError.invalidArguments }
            target = .temporary(profileID: profileID, host: host, port: targetPort, bind: bind, listenPort: listenPort)
        case .external:
            let address = externalAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard ruleID == nil, !hasTemporaryFields, address.utf8.count <= 32,
                  let colon = address.lastIndex(of: ":"), ["127.0.0.1", "[::1]"].contains(String(address[..<colon])),
                  let port = Int(address[address.index(after: colon)...]), TunnelValidator.isValidPort(port) else {
                throw AgentToolError.invalidArguments
            }
            target = .external("\(address[..<colon]):\(port)")
        }
        return (key, AgentLeaseInput(target: target, purpose: purpose, project: project == "" ? nil : project, ttl: ttl))
    }
}

struct AgentToolError: Codable, LocalizedError, Sendable {
    let code: String
    let message: String

    var errorDescription: String? {
        let chinese = switch code {
        case Self.invalidArguments.code: "请检查输入字段。"
        case Self.notPaired.code: "请在「设置 → Agent 接入」重新配对该客户端。"
        case Self.readOnly.code: "请在「设置 → Agent 接入」开启该客户端的申请权限。"
        case Self.notFound.code: "此客户端没有对应编号的申请。"
        case Self.routeChanged.code: "请在 Portlane 中检查共享规则或已保存的 SSH 配置。"
        case Self.externalGone.code: "无法核实该地址存在外部 SSH 本地转发。"
        case Self.conflict.code: "该幂等键已用于参数不同的申请。"
        case Self.unavailable.code: "请在这台 Mac 上打开 Portlane 后重试。"
        case Self.storage.code: "无法访问 Agent 审计记录，请检查「设置 → Agent 接入」。"
        default: message
        }
        return L10n.text(message, chinese)
    }

    static let invalidArguments = Self(code: "invalid_arguments", message: "Check the fields described by this tool.")
    static let notPaired = Self(code: "not_paired", message: "Pair this client again in Portlane Settings → Agent Access.")
    static let readOnly = Self(code: "read_only", message: "Allow requests for this pairing in Portlane Settings → Agent Access.")
    static let notFound = Self(code: "not_found", message: "This pairing has no lease with that ID.")
    static let routeChanged = Self(code: "route_unavailable", message: "Check the shared rule or saved SSH profile in Portlane.")
    static let externalGone = Self(code: "external_unverified", message: "Portlane could not verify a live external loopback -L listener at that address.")
    static let conflict = Self(code: "idempotency_conflict", message: "This key belongs to a request with different inputs.")
    static let unavailable = Self(code: "portlane_unavailable", message: "Open Portlane on this Mac to use the Agent integration.")
    static let storage = Self(code: "audit_unavailable", message: "Portlane could not access the local Agent audit. Check Agent Access settings.")
}

struct AgentCredential: Codable, Sendable {
    let clientID: UUID
    let token: String
    let socketPath: String
}

struct AgentToolCall: Codable, Sendable {
    let credential: AgentCredential
    let tool: AgentTool
    let arguments: AgentToolArguments
}

/// Clients receive only their lease, with an address available in the ready state.
struct AgentToolResult: Codable, Sendable {
    struct Rule: Codable, Sendable {
        let id: UUID
        let profileID: UUID
        let name: String
        let sshHost: String?
        let destination: String?

        init(share: AgentShare, route: AgentRoute) {
            id = share.id
            profileID = share.profileID
            name = route.name
            sshHost = route.sshHost
            destination = route.destination
        }

        enum CodingKeys: String, CodingKey { case id, profileID = "profile_id", name, sshHost = "ssh_host", destination }
    }

    struct Lease: Codable, Sendable {
        let id: UUID
        let state: AgentLease.State
        let address: String?
        let expiresAt: Date?
        let reason: AgentLease.Reason?
        let external: Bool

        init(_ lease: AgentLease) {
            id = lease.id
            state = lease.state
            address = state == .ready ? lease.route.listenAddress : nil
            expiresAt = lease.expiresAt
            reason = lease.reason
            external = lease.external != nil
        }

        enum CodingKeys: String, CodingKey { case id, state, address, expiresAt = "expires_at", reason, external }
    }

    var rules: [Rule]?
    var canRequest: Bool?
    var lease: Lease?
    var error: AgentToolError?

    enum CodingKeys: String, CodingKey { case rules, canRequest = "can_request", lease, error }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
