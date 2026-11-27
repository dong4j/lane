import Foundation

/// What ssh (or the proxy helper) is asking for.
public enum PromptKind: Equatable, Sendable {
    case password
    case passphrase(keyPath: String?)
    case hostKey(host: String?, keyType: String?, fingerprint: String?)
    case confirmation
    case proxyPassword
    case other
}

public enum PromptClassifier {
    public static func classify(_ prompt: String) -> PromptKind {
        let lower = prompt.lowercased()
        if lower.contains("are you sure you want to continue connecting") || lower.contains("authenticity of host") {
            let host = SSHLogParser.firstMatch(#"authenticity of host '([^']+)'"#, in: prompt)?[1]
            // Contemporary OpenSSH adds a colon before the hash; older builds leave it out.
            let fp = SSHLogParser.firstMatch(#"key fingerprint is:?\s+(\S+?)\.?(?:\s|$)"#, in: prompt)
            let type = SSHLogParser.firstMatch(#"(\S+) key fingerprint is"#, in: prompt)?[1]
            return .hostKey(host: host, keyType: type, fingerprint: fp?[1])
        }
        if lower.contains("passphrase for key") || lower.contains("enter passphrase") {
            let path = SSHLogParser.firstMatch(#"passphrase for key '([^']+)'"#, in: prompt)?[1]
            return .passphrase(keyPath: path)
        }
        if lower.contains("(yes/no") || lower.hasSuffix("?") && lower.contains("allow") {
            return .confirmation
        }
        // OpenSSH: "user@host's password:" or keyboard-interactive "(user@host) Password:".
        if let r = lower.range(of: "password") {
            let after = lower[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if after.hasPrefix(":") || after.isEmpty { return .password }
        }
        return .other
    }
}

extension PromptClassifier {
    /// The account a password prompt is for: OpenSSH asks "user@host's password: " or, for
    /// keyboard-interactive, "(user@host) Password: ".
    public static func passwordAccount(in prompt: String) -> (user: String, host: String)? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let g = SSHLogParser.firstMatch(#"^\(([^@()\s]+)@([^()\s]+)\)"#, in: trimmed) { return (g[1], g[2]) }
        if let g = SSHLogParser.firstMatch(#"^([^@\s]+)@(\S+?)'s password"#, in: trimmed) { return (g[1], g[2]) }
        return nil
    }

    /// Whether a password prompt comes from the tunnel's jump host rather than its SSH server.
    public static func isJumpHostPrompt(_ prompt: String, tunnel: Tunnel) -> Bool {
        guard tunnel.proxy.kind == .jumpHost, let who = passwordAccount(in: prompt) else { return false }
        let host = who.host.lowercased()
        guard host == tunnel.proxy.host.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        // Same machine for both hops: only the user name can tell them apart.
        if host == tunnel.host.trimmingCharacters(in: .whitespaces).lowercased() {
            let jumpUser = tunnel.proxy.username.trimmingCharacters(in: .whitespaces)
            let serverUser = tunnel.user.trimmingCharacters(in: .whitespaces)
            return !jumpUser.isEmpty && jumpUser != serverUser && who.user == jumpUser
        }
        return true
    }

    /// OpenSSH prints at most 100 characters of the key path in its passphrase prompt
    /// (`"Enter passphrase for key '%.100s': "`). Map a truncated path back to the configured identity file.
    public static func resolveKeyPath(fromPrompt promptPath: String?, identityFile: String,
                                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let configured = (identityFile as NSString).expandingTildeInPath
        guard let promptPath, !promptPath.isEmpty else { return configured }
        if fileExists(promptPath) { return promptPath }
        if !configured.isEmpty, configured.hasPrefix(promptPath) { return configured }
        return promptPath
    }
}

/// One request from a helper process to the Porthole app, sent as a single JSON line.
public struct AskpassRequest: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case prompt
        case proxyPassword
    }

    public var token: String
    public var tunnelID: String
    public var kind: Kind
    public var prompt: String

    public init(token: String, tunnelID: String, kind: Kind, prompt: String) {
        self.token = token
        self.tunnelID = tunnelID
        self.kind = kind
        self.prompt = prompt
    }
}

public struct AskpassReply: Codable, Sendable {
    public var ok: Bool
    public var answer: String

    public init(ok: Bool, answer: String = "") {
        self.ok = ok
        self.answer = answer
    }

    public static let cancelled = AskpassReply(ok: false)
}

public enum AskpassEnvironment {
    public static let socketPath = "PORTLANE_ASKPASS_SOCKET"
    public static let token = "PORTLANE_ASKPASS_TOKEN"
    public static let tunnelID = "PORTLANE_TUNNEL_ID"
}

/// Minimal blocking Unix-domain-socket helpers shared by the app and its helper modes.
public enum UnixSocket {
    public enum SocketError: Error, CustomStringConvertible {
        case system(String, Int32)
        case pathTooLong

        public var description: String {
            switch self {
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            case .pathTooLong: return "socket path too long"
            }
        }
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var addr = try makeAddress(path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let e = errno
            close(fd)
            throw SocketError.system("connect", e)
        }
        return fd
    }

    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var addr = try makeAddress(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw SocketError.system("bind", e)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw SocketError.system("listen", e)
        }
        return fd
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    /// Reads until a newline, EOF, or the caller's message size limit.
    public static func readLine(_ fd: Int32, limit: Int = 65_536) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while buffer.count < limit {
            let n = read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return buffer.isEmpty ? nil : buffer }
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
        }
        return buffer
    }

    /// Sends a request and waits for the reply (used by helper processes).
    public static func roundTrip(socketPath: String, request: AskpassRequest) throws -> AskpassReply {
        let fd = try connect(path: socketPath)
        defer { close(fd) }
        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))
        guard writeAll(fd, payload) else { throw SocketError.system("write", errno) }
        guard let line = readLine(fd) else { return .cancelled }
        return (try? JSONDecoder().decode(AskpassReply.self, from: line)) ?? .cancelled
    }
}
