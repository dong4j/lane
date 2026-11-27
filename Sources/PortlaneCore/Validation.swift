import Foundation

public struct ValidationIssue: Hashable, Sendable, Identifiable {
    public enum Severity: Sendable { case error, warning }
    public enum Field: Hashable, Sendable {
        case name, host, port, user, identityFile, proxy, forwardings
        case forwarding(UUID)
    }

    public var severity: Severity
    public var field: Field
    public var message: String
    public var id: String { "\(field)-\(message)" }

    public init(_ severity: Severity, _ field: Field, _ message: String) {
        self.severity = severity
        self.field = field
        self.message = message
    }
}

public enum TunnelValidator {
    static let forbiddenHostCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"`;|&$<>(){}\\"))

    public static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    public static func isValidHostToken(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !v.hasPrefix("-") else { return false }
        return v.rangeOfCharacter(from: forbiddenHostCharacters) == nil
    }

    public static func validate(_ tunnel: Tunnel, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if tunnel.host.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(.error, .host, String(localized: "Enter the SSH server's host name or address.")))
        } else if !isValidHostToken(tunnel.host) {
            issues.append(.init(.error, .host, String(localized: "The host name contains characters that are not allowed.")))
        }

        if !isValidPort(tunnel.port) {
            issues.append(.init(.error, .port, String(localized: "The SSH port must be between 1 and 65535.")))
        }

        let user = tunnel.user.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty && !isValidHostToken(user) {
            issues.append(.init(.error, .user, String(localized: "The user name contains characters that are not allowed.")))
        }

        if tunnel.authMethod == .publicKey {
            let path = tunnel.identityFile.trimmingCharacters(in: .whitespaces)
            if path.isEmpty {
                issues.append(.init(.error, .identityFile, String(localized: "Choose a private key file.")))
            } else if !fileExists(path) {
                issues.append(.init(.warning, .identityFile, String(localized: "The private key file could not be found.")))
            }
        }

        if tunnel.proxy.kind != .none {
            if !isValidHostToken(tunnel.proxy.host) {
                issues.append(.init(.error, .proxy, String(localized: "Enter the proxy or jump host address.")))
            }
            if !isValidPort(tunnel.proxy.port) {
                issues.append(.init(.error, .proxy, String(localized: "The proxy port must be between 1 and 65535.")))
            }
            let pu = tunnel.proxy.username.trimmingCharacters(in: .whitespaces)
            if !pu.isEmpty && !isValidHostToken(pu) {
                issues.append(.init(.error, .proxy, String(localized: "The proxy user name contains characters that are not allowed.")))
            }
        }

        let enabled = tunnel.enabledForwardings
        if enabled.isEmpty {
            issues.append(.init(.error, .forwardings, String(localized: "Add at least one enabled port forwarding rule.")))
        }

        var seenLocal: [String: UUID] = [:]
        var seenRemote: [Int: UUID] = [:]
        for f in tunnel.forwardings {
            issues.append(contentsOf: validate(f))
            guard f.enabled, isValidPort(f.port) else { continue }
            if f.kind.listensLocally {
                let key = "\(normalizedBind(f.bindAddress)):\(f.port)"
                if seenLocal[key] != nil {
                    issues.append(.init(.error, .forwarding(f.id), String(localized: "Port \(String(f.port)) is used by more than one rule.")))
                }
                seenLocal[key] = f.id
            } else {
                if seenRemote[f.port] != nil {
                    issues.append(.init(.error, .forwarding(f.id), String(localized: "Remote port \(String(f.port)) is used by more than one rule.")))
                }
                seenRemote[f.port] = f.id
            }
        }
        return issues
    }

    public static func validate(_ f: Forwarding) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let field = ValidationIssue.Field.forwarding(f.id)
        if !isValidPort(f.port) {
            issues.append(.init(.error, field, String(localized: "Listening port must be between 1 and 65535.")))
        } else if f.kind == .remote && f.port < 1024 {
            issues.append(.init(.warning, field, String(localized: "Remote ports below 1024 can only be opened when logging in as root.")))
        }
        let bind = f.bindAddress.trimmingCharacters(in: .whitespaces)
        if !bind.isEmpty && bind != "*" && !isValidHostToken(bind) {
            issues.append(.init(.error, field, String(localized: "The bind address is not valid.")))
        }
        if f.kind == .remote && !bind.isEmpty && bind != "localhost" && bind != "127.0.0.1" {
            issues.append(.init(.warning, field, String(localized: "A remote bind address only works when the server sets “GatewayPorts clientspecified”.")))
        }
        if f.kind != .dynamic {
            if !isValidHostToken(f.targetHost) {
                issues.append(.init(.error, field, String(localized: "Enter the destination host.")))
            }
            if !isValidPort(f.targetPort) {
                issues.append(.init(.error, field, String(localized: "Destination port must be between 1 and 65535.")))
            }
        }
        return issues
    }

    static func normalizedBind(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "", "localhost", "127.0.0.1": return "loopback"
        case "*", "0.0.0.0": return "any"
        default: return t
        }
    }
}
