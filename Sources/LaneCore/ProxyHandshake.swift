import Foundation

/// Pure encoders/decoders for SOCKS4a, SOCKS5 and HTTP CONNECT handshakes.
public enum ProxyHandshake {
    public enum HandshakeError: Error, Equatable, CustomStringConvertible {
        case unexpectedResponse(String)
        case rejected(String)
        case authenticationRequired
        case authenticationFailed
        case valueTooLong(String)

        public var description: String {
            switch self {
            case .unexpectedResponse(let s): return String(localized: "Unexpected proxy response: \(s)")
            case .rejected(let s): return String(localized: "Proxy refused the connection: \(s)")
            case .authenticationRequired: return String(localized: "The proxy requires a user name and password.")
            case .authenticationFailed: return String(localized: "The proxy rejected the user name or password.")
            case .valueTooLong(let s): return String(localized: "\(s) is too long for the proxy protocol.")
            }
        }
    }

    // MARK: SOCKS4a

    public static func socks4Request(host: String, port: Int, userID: String = "") -> [UInt8] {
        var bytes: [UInt8] = [0x04, 0x01, UInt8((port >> 8) & 0xff), UInt8(port & 0xff)]
        if let v4 = ipv4Bytes(host) {
            bytes += v4
            bytes += Array(userID.utf8) + [0]
        } else {
            // SOCKS4a: 0.0.0.x signals that a host name follows.
            bytes += [0, 0, 0, 1]
            bytes += Array(userID.utf8) + [0]
            bytes += Array(host.utf8) + [0]
        }
        return bytes
    }

    /// Reply is 8 bytes; 0x5A means granted.
    public static func parseSocks4Reply(_ reply: [UInt8]) throws {
        guard reply.count >= 2, reply[0] == 0x00 else { throw HandshakeError.unexpectedResponse(hex(reply)) }
        switch reply[1] {
        case 0x5A: return
        case 0x5B: throw HandshakeError.rejected("request rejected or failed")
        case 0x5C: throw HandshakeError.rejected("cannot reach identd")
        case 0x5D: throw HandshakeError.rejected("user id not matched")
        default: throw HandshakeError.unexpectedResponse(hex(reply))
        }
    }

    // MARK: SOCKS5

    public static func socks5Greeting(withAuth: Bool) -> [UInt8] {
        withAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
    }

    /// Returns the method selected by the server (0x00 none, 0x02 user/pass).
    public static func parseSocks5MethodSelection(_ reply: [UInt8]) throws -> UInt8 {
        guard reply.count >= 2, reply[0] == 0x05 else { throw HandshakeError.unexpectedResponse(hex(reply)) }
        if reply[1] == 0xFF { throw HandshakeError.authenticationRequired }
        return reply[1]
    }

    public static func socks5UserPass(username: String, password: String) throws -> [UInt8] {
        let u = Array(username.utf8), p = Array(password.utf8)
        guard u.count <= 255 else { throw HandshakeError.valueTooLong("User name") }
        guard p.count <= 255 else { throw HandshakeError.valueTooLong("Password") }
        return [0x01, UInt8(u.count)] + u + [UInt8(p.count)] + p
    }

    public static func parseSocks5AuthReply(_ reply: [UInt8]) throws {
        guard reply.count >= 2 else { throw HandshakeError.unexpectedResponse(hex(reply)) }
        if reply[1] != 0x00 { throw HandshakeError.authenticationFailed }
    }

    public static func socks5Connect(host: String, port: Int) throws -> [UInt8] {
        var bytes: [UInt8] = [0x05, 0x01, 0x00]
        if let v4 = ipv4Bytes(host) {
            bytes += [0x01] + v4
        } else if let v6 = ipv6Bytes(host) {
            bytes += [0x04] + v6
        } else {
            let name = Array(host.utf8)
            guard name.count <= 255 else { throw HandshakeError.valueTooLong("Host name") }
            bytes += [0x03, UInt8(name.count)] + name
        }
        bytes += [UInt8((port >> 8) & 0xff), UInt8(port & 0xff)]
        return bytes
    }

    /// Validates the first 4 bytes of a SOCKS5 reply and returns how many more bytes the
    /// bound-address section occupies (so the caller can drain it).
    public static func parseSocks5ConnectReplyHeader(_ header: [UInt8]) throws -> Int {
        guard header.count >= 4, header[0] == 0x05 else { throw HandshakeError.unexpectedResponse(hex(header)) }
        if header[1] != 0x00 {
            let reasons: [UInt8: String] = [
                0x01: "general SOCKS server failure", 0x02: "connection not allowed by ruleset",
                0x03: "network unreachable", 0x04: "host unreachable", 0x05: "connection refused",
                0x06: "TTL expired", 0x07: "command not supported", 0x08: "address type not supported",
            ]
            throw HandshakeError.rejected(reasons[header[1]] ?? "error \(header[1])")
        }
        switch header[3] {
        case 0x01: return 4 + 2
        case 0x04: return 16 + 2
        case 0x03: return -1 // caller must read one length byte, then that many + 2
        default: throw HandshakeError.unexpectedResponse(hex(header))
        }
    }

    // MARK: HTTP CONNECT

    public static func httpConnectRequest(host: String, port: Int, username: String?, password: String?) -> String {
        let authority = "\(host.contains(":") ? "[\(host)]" : host):\(port)"
        var lines = [
            "CONNECT \(authority) HTTP/1.1",
            "Host: \(authority)",
            "User-Agent: Porthole",
            "Proxy-Connection: Keep-Alive",
        ]
        if let username, !username.isEmpty {
            let token = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(token)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// Parses the status line of the proxy's response header block.
    public static func parseHTTPConnectResponse(_ header: String) throws {
        guard let statusLine = header.components(separatedBy: "\r\n").first ?? header.components(separatedBy: "\n").first else {
            throw HandshakeError.unexpectedResponse(header)
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw HandshakeError.unexpectedResponse(statusLine)
        }
        switch code {
        case 200..<300: return
        case 407: throw HandshakeError.authenticationFailed
        default: throw HandshakeError.rejected(statusLine)
        }
    }

    // MARK: utils

    static func ipv4Bytes(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    static func ipv6Bytes(_ s: String) -> [UInt8]? {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var addr = in6_addr()
        guard inet_pton(AF_INET6, trimmed, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
