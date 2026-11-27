import Foundation

/// The address and owning process observed by `lsof`; it is evidence of a listener only.
public struct ListeningEndpoint: Hashable, Sendable {
    public let pid: Int32
    public let host: String
    public let port: Int

    public var address: String { "\(Forwarding.bracketIfIPv6(host)):\(port)" }

    public var clientAddress: String {
        let clientHost = switch host {
        case "*", "0.0.0.0", "localhost": "127.0.0.1"
        case "::": "::1"
        default: host
        }
        return "\(Forwarding.bracketIfIPv6(clientHost)):\(port)"
    }

    /// Interprets the `p` (process ID) and `n` (socket name) fields from lsof's machine output.
    public static func parseLsof(_ output: String) -> [ListeningEndpoint] {
        var pid: Int32?
        var endpoints: [ListeningEndpoint] = []
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()); continue }
            guard line.first == "n", let pid else { continue }
            let (host, rawPort) = SSHConfigImporter.splitHostPort(String(line.dropFirst()), portOnlyAllowed: false)
            guard !host.isEmpty, let port = Int(rawPort), TunnelValidator.isValidPort(port) else { continue }
            let endpoint = ListeningEndpoint(pid: pid, host: host, port: port)
            if !endpoints.contains(endpoint) { endpoints.append(endpoint) }
        }
        return endpoints
    }

    func matches(_ forward: Forwarding) -> Bool {
        guard forward.kind.listensLocally, port == forward.port else { return false }
        let bind = forward.bindAddress.lowercased()
        let observed = host.lowercased()
        return switch bind {
        case "", "localhost": ["127.0.0.1", "::1", "localhost"].contains(observed)
        case "*": ["*", "0.0.0.0", "::"].contains(observed)
        case "0.0.0.0", "::": observed == bind || observed == "*"
        default: observed == bind
        }
    }
}

/// Observations are grouped by owning PID and never converted into managed tunnels.
public struct ExternalSession: Identifiable, Sendable {
    public struct Rule: Identifiable, Sendable {
        public let listener: ListeningEndpoint?
        public let forward: Forwarding?

        public var id: String { listener?.address ?? "remote:\(forward?.sshSpec ?? "")" }
        public var copyAddress: String? {
            guard let listener else { return nil }
            return (forward?.kind == .dynamic ? "socks5://" : "") + listener.clientAddress
        }
    }

    public let id: Int32
    public let host: String?
    public let rules: [Rule]

    /// Local target metadata is displayed only when the actual listener matches unambiguous argv evidence.
    public init?(pid: Int32, invocation: SSHInvocation?, listeners: [ListeningEndpoint]) {
        let forwards = invocation?.forwards ?? []
        let local = listeners.filter { $0.pid == pid }.map { listener in
            let matches = forwards.filter { listener.matches($0) }
            return Rule(listener: listener, forward: matches.count == 1 ? matches.first : nil)
        }
        let remote = forwards.filter { $0.kind == .remote }.map { Rule(listener: nil, forward: $0) }
        guard !local.isEmpty || !remote.isEmpty else { return nil }
        id = pid
        host = invocation?.host
        rules = local.sorted {
            ($0.listener?.port ?? 0, $0.id) < ($1.listener?.port ?? 0, $1.id)
        } + remote
    }

    public func matches(query: String) -> Bool {
        let values = [host ?? "OpenSSH", String(id)] + rules.flatMap {
            [$0.listener?.address ?? "", $0.forward?.sshSpec ?? ""]
        }
        let searchText = values.joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchText.localizedCaseInsensitiveContains($0)
        }
    }
}
