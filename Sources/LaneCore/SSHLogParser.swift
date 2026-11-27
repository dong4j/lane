import Foundation

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug, info, success, warning, error

    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .success: return 2
        case .warning: return 3
        case .error: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// A meaningful state change extracted from ssh's stderr.
public enum SSHEvent: Equatable, Sendable {
    case connecting(host: String, address: String?, port: Int?)
    case connectionEstablished
    case serverHostKey(type: String, fingerprint: String)
    case authenticated(method: String?)
    case localForwardListening(port: Int)
    case remoteForwardSuccess(port: Int)
    case forwardFailed(port: Int?, remote: Bool, message: String)
    case sessionReady
    /// Authentication was rejected. Not worth retrying automatically.
    case authFailed(String)
    /// Host key verification failed or the key changed. Not worth retrying.
    case hostKeyProblem(String)
    /// ssh refused its own settings (a bad option, a jump host loop…). Retrying can't help.
    case configError(String)
    /// Network-level failure. Retrying later may succeed.
    case connectionFailed(String)
    /// The established connection went away.
    case disconnected(String)
}

public struct ParsedLogLine: Equatable, Sendable {
    public var level: LogLevel
    public var message: String
    public var event: SSHEvent?
}

public enum SSHLogParser {
    public static func parse(_ rawLine: String) -> ParsedLogLine {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        var level: LogLevel = .info
        var message = line

        // "debug1: …" – checked by hand, it's on every line ssh -v prints.
        let prefix = line.utf8.prefix(8)
        if prefix.count == 8, prefix.starts(with: "debug".utf8),
           (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(prefix[prefix.index(prefix.startIndex, offsetBy: 5)]),
           prefix.dropFirst(6).elementsEqual(": ".utf8) {
            level = .debug
            message = String(line.dropFirst(8))
        }

        let event = detectEvent(message, isDebug: level == .debug)
        if let event {
            switch event {
            case .connecting, .connectionEstablished, .serverHostKey:
                level = .info
            case .authenticated, .localForwardListening, .remoteForwardSuccess, .sessionReady:
                level = .success
            case .forwardFailed, .authFailed, .hostKeyProblem, .configError, .connectionFailed:
                level = .error
            case .disconnected:
                level = .warning
            }
        } else if level != .debug {
            let lower = message.lowercased()
            if lower.hasPrefix("warning") || lower.contains("warning:") {
                level = .warning
            } else if lower.hasPrefix("error") || lower.contains("failed") || lower.contains("denied") || lower.hasPrefix("ssh:") {
                level = .error
            }
        }
        return ParsedLogLine(level: level, message: message, event: event)
    }

    /// Compiled patterns. ssh -v prints several lines for every forwarded connection, and each
    /// line is checked against a dozen patterns, so compiling them per line added up.
    // NSCache synchronizes its accesses and the cached regular expressions are immutable.
    nonisolated(unsafe) private static let compiled = NSCache<NSString, NSRegularExpression>()

    static func regex(_ pattern: String) -> NSRegularExpression? {
        if let re = compiled.object(forKey: pattern as NSString) { return re }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        compiled.setObject(re, forKey: pattern as NSString)
        return re
    }

    static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = regex(pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    static func detectEvent(_ m: String, isDebug: Bool) -> SSHEvent? {
        // Progress (debug level)
        if let g = firstMatch(#"^Connecting to (\S+) \[([^\]]+)\] port (\d+)"#, in: m) {
            return .connecting(host: g[1], address: g[2], port: Int(g[3]))
        }
        if m.hasPrefix("Connection established") { return .connectionEstablished }
        if let g = firstMatch(#"^Server host key: (\S+) (\S+)"#, in: m) {
            return .serverHostKey(type: g[1], fingerprint: g[2])
        }
        if let g = firstMatch(#"^Authenticated to .* using \"([^\"]+)\""#, in: m) {
            return .authenticated(method: g[1])
        }
        if m.hasPrefix("Authentication succeeded") {
            let method = firstMatch(#"\(([^)]+)\)"#, in: m)?[1]
            return .authenticated(method: method)
        }
        if let g = firstMatch(#"^Local forwarding listening on \S+ port (\d+)"#, in: m) {
            return Int(g[1]).map { .localForwardListening(port: $0) }
        }
        if let g = firstMatch(#"^remote forward success for: listen (?:\S+:)?(\d+)"#, in: m) {
            return Int(g[1]).map { .remoteForwardSuccess(port: $0) }
        }
        if let g = firstMatch(#"^remote forward failure for: listen (?:\S+:)?(\d+)"#, in: m) {
            let port = g[1]
            return .forwardFailed(port: Int(port), remote: true, message: String(localized: "The server refused to open remote port \(port)."))
        }
        if m.hasPrefix("Entering interactive session") { return .sessionReady }

        // Forwarding failures
        if let g = firstMatch(#"remote port forwarding failed for listen port (\d+)"#, in: m) {
            let port = g[1]
            return .forwardFailed(port: Int(port), remote: true, message: String(localized: "The server refused to open remote port \(port). It may already be in use there."))
        }
        if let g = firstMatch(#"cannot listen to port: (\d+)"#, in: m) {
            let port = g[1]
            return .forwardFailed(port: Int(port), remote: false, message: String(localized: "Could not listen on local port \(port). It is probably used by another app."))
        }
        if m.contains("Could not request local forwarding") {
            return .forwardFailed(port: nil, remote: false, message: String(localized: "Could not set up local port forwarding."))
        }
        if let g = firstMatch(#"^(?:Error|Warning): Could not request (\S+) forwarding"#, in: m) {
            return .forwardFailed(port: nil, remote: g[1].lowercased().contains("remote"), message: m)
        }

        // Failures – only meaningful for non-debug output.
        if isDebug { return nil }
        let lower = m.lowercased()
        // ssh rejects its configuration before connecting, e.g.
        // `command-line line 0: Bad configuration option: foo`, `/Users/me/.ssh/config line 3: …`,
        // `Bad local forwarding specification '…'`, `jumphost loop via …`.
        if lower.hasPrefix("command-line") || lower.contains("bad configuration option")
            || firstMatch(#"config:? line \d+:"#, in: lower) != nil
            || lower.hasPrefix("bad ") && lower.contains("specification")
            || lower.hasPrefix("jumphost loop") || lower.hasPrefix("can't open user config file")
            || lower.hasPrefix("usage: ssh") || lower.contains("illegal option") {
            return .configError(m)
        }
        if lower.contains("permission denied") || lower.contains("too many authentication failures")
            || lower.contains("no supported authentication methods available") {
            return .authFailed(m)
        }
        if lower.contains("host key verification failed") || lower.contains("remote host identification has changed")
            || lower.contains("host key for") && lower.contains("has changed") || lower.contains("no matching host key type found") {
            return .hostKeyProblem(m)
        }
        if lower.contains("could not resolve hostname") || lower.contains("connection refused")
            || lower.contains("operation timed out") || lower.contains("connection timed out")
            || lower.contains("network is unreachable") || lower.contains("no route to host")
            || lower.contains("kex_exchange_identification") || lower.contains("connection reset")
            || lower.contains("proxy") && lower.contains("failed")
            || lower.contains("ssh_exchange_identification") || lower.contains("unable to negotiate") {
            return .connectionFailed(m)
        }
        if lower.contains("closed by remote host") || lower.contains("broken pipe")
            || lower.contains("not responding") || lower.contains("connection to") && lower.contains("closed") {
            return .disconnected(m)
        }
        return nil
    }

    /// Ends a message with a full stop unless it already ends a sentence (in any script).
    public static func sentence(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…。！？".contains(last) ? trimmed : trimmed + "."
    }

    /// Turns a non-retryable failure into a short user facing explanation.
    public static func friendlyMessage(for event: SSHEvent) -> String {
        switch event {
        case .authFailed(let m):
            if m.lowercased().contains("too many") { return String(localized: "The server rejected the login (too many attempts). Check your key or password.") }
            return String(localized: "The server rejected the login. Check the user name, password or private key.")
        case .hostKeyProblem(let m):
            if m.lowercased().contains("changed") { return String(localized: "The server's host key has changed. This could be a man-in-the-middle attack; Lane will not connect.") }
            if m.lowercased().contains("no matching host key type") { return String(localized: "The server offers no host key type this Mac accepts. Adjust “Host key algorithms” in Advanced settings.") }
            return String(localized: "The server's identity could not be verified.")
        case .connectionFailed(let m):
            let l = m.lowercased()
            if l.contains("could not resolve hostname") { return String(localized: "The host name could not be resolved. Check the address or your network.") }
            if l.contains("connection refused") { return String(localized: "The server refused the connection. Is SSH running on that port?") }
            if l.contains("timed out") { return String(localized: "The connection timed out.") }
            if l.contains("unreachable") || l.contains("no route") { return String(localized: "The network is unreachable.") }
            if l.contains("unable to negotiate") { return String(localized: "No common algorithm with the server. Adjust the algorithms in Advanced settings.") }
            if l.contains("kex_exchange_identification") || l.contains("ssh_exchange_identification") {
                return String(localized: "The server closed the connection during the handshake. It may be restarting or limiting connections.")
            }
            if l.contains("proxy") { return String(localized: "Could not connect through the proxy: \(m)") }
            return m
        case .configError(let m):
            if m.lowercased().hasPrefix("jumphost loop") {
                return String(localized: "The jump host is the SSH server itself. Choose another jump host or connect directly.")
            }
            let detail = sentence(m)
            return String(localized: "ssh did not accept these settings: \(detail) Check “Extra ssh options” in Advanced settings and your ~/.ssh/config.")
        case .forwardFailed(_, _, let m):
            return m
        case .disconnected(let m):
            let l = m.lowercased()
            if l.contains("closed by remote host") { return String(localized: "The server closed the connection.") }
            if l.contains("broken pipe") || l.contains("connection reset") { return String(localized: "The connection was interrupted.") }
            if l.contains("not responding") { return String(localized: "The server stopped responding.") }
            return m
        default:
            return ""
        }
    }
}
