import Darwin
import Foundation

public struct ValidationIssue: Hashable, Sendable, Identifiable {
    public enum Severity: Sendable { case error, warning }
    public enum ForwardField: Hashable, Sendable { case listenAddress, listenPort, targetHost, targetPort }

    public enum Field: Hashable, Sendable {
        case name, host, port, user, identityFile, proxy, forwardings
        case forwarding(UUID, ForwardField)
    }

    public var severity: Severity
    public var field: Field
    public var message: String
    public var chineseMessage: String?
    public var id: String { "\(field)-\(message)" }

    public init(_ severity: Severity, _ field: Field, _ message: String, chinese: String? = nil) {
        self.severity = severity
        self.field = field
        self.message = message
        chineseMessage = chinese
    }
}

public enum TunnelValidator {
    static let forbiddenHostCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        .union(CharacterSet(charactersIn: "'\"`;|&$<>(){}\\"))

    public static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    public static func isValidHostToken(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !v.hasPrefix("-") else { return false }
        return v.rangeOfCharacter(from: forbiddenHostCharacters) == nil
    }

    private static func isValidListenAddress(_ value: String) -> Bool {
        if value.isEmpty || value == "*" { return true }
        guard isValidHostToken(value) else { return false }
        let bracketed = value.hasPrefix("[") && value.hasSuffix("]")
        if value.contains(":") || bracketed {
            let host = bracketed ? String(value.dropFirst().dropLast()) : value
            let parts = host.split(separator: "%", omittingEmptySubsequences: false)
            var address = in6_addr()
            return parts.count <= 2 && (parts.count == 1 || !parts[1].isEmpty) &&
                inet_pton(AF_INET6, String(parts[0]), &address) == 1
        }
        if value.contains("."), value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
            var address = in_addr()
            return inet_pton(AF_INET, value, &address) == 1
        }
        let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy(nameCharacters.contains)
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
                    issues.append(.init(.error, .forwarding(f.id, .listenPort), "Port \(f.port) is used by more than one rule.",
                                        chinese: "端口 \(f.port) 已被其他规则使用。"))
                }
                seenLocal[key] = f.id
            } else {
                if seenRemote[f.port] != nil {
                    issues.append(.init(.error, .forwarding(f.id, .listenPort), "Remote port \(f.port) is used by more than one rule.",
                                        chinese: "远程端口 \(f.port) 已被其他规则使用。"))
                }
                seenRemote[f.port] = f.id
            }
        }
        return issues
    }

    public static func validate(_ f: Forwarding) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if !isValidPort(f.port) {
            issues.append(.init(.error, .forwarding(f.id, .listenPort), "Listening port must be between 1 and 65535.",
                                chinese: "监听端口必须介于 1 和 65535。"))
        } else if f.kind == .remote && f.port < 1024 {
            issues.append(.init(.warning, .forwarding(f.id, .listenPort), "Remote ports below 1024 require a root login.",
                                chinese: "远程端口低于 1024，需要以 root 登录。"))
        }
        let bind = f.bindAddress.trimmingCharacters(in: .whitespaces)
        if !isValidListenAddress(bind) {
            issues.append(.init(.error, .forwarding(f.id, .listenAddress), "Enter a valid listening address.",
                                chinese: "请输入有效的监听地址。"))
        }
        if f.kind == .remote && !bind.isEmpty && bind != "localhost" && bind != "127.0.0.1" {
            issues.append(.init(.warning, .forwarding(f.id, .listenAddress), "The server must allow the remote listening address (GatewayPorts clientspecified).",
                                chinese: "SSH 服务器须启用 GatewayPorts clientspecified 才能使用此监听地址。"))
        }
        if f.kind != .dynamic {
            if !isValidHostToken(f.targetHost) {
                issues.append(.init(.error, .forwarding(f.id, .targetHost), "Enter a valid destination host.",
                                    chinese: "请输入有效的目标主机。"))
            }
            if !isValidPort(f.targetPort) {
                issues.append(.init(.error, .forwarding(f.id, .targetPort), "Destination port must be between 1 and 65535.",
                                    chinese: "目标端口必须介于 1 和 65535。"))
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
