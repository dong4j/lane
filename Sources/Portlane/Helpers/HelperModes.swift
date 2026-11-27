import Foundation
import PortlaneCore

private func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// `SSH_ASKPASS` program: forwards the prompt to the app and prints the answer for ssh.
enum AskpassHelper {
    static func run(prompt: String) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env[AskpassEnvironment.socketPath],
              let token = env[AskpassEnvironment.token],
              let tunnel = env[AskpassEnvironment.tunnelID] else { return 1 }
        let request = AskpassRequest(token: token, tunnelID: tunnel, kind: .prompt, prompt: prompt)
        do {
            let reply = try UnixSocket.roundTrip(socketPath: socket, request: request)
            guard reply.ok else { return 1 }
            FileHandle.standardOutput.write(Data((reply.answer + "\n").utf8))
            return 0
        } catch {
            writeStderr("Portlane askpass: \(error)")
            return 1
        }
    }
}

/// `ProxyCommand` helper: opens a TCP connection through a SOCKS4/SOCKS5/HTTP proxy and then
/// relays bytes between ssh (stdin/stdout) and the proxied connection.
///
/// Usage: Portlane --proxy-connect <socks4|socks5|http> <proxyHost> <proxyPort> <targetHost> <targetPort> [username [ask-password|no-password]]
enum ProxyHelper {
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 5, let proxyPort = Int(args[2]), let targetPort = Int(args[4]) else {
            writeStderr("usage: Portlane --proxy-connect <socks4|socks5|http> <proxyHost> <proxyPort> <targetHost> <targetPort> [username [ask-password|no-password]]")
            return 2
        }
        let type = args[0], proxyHost = args[1], targetHost = args[3]
        let username = args.count >= 6 ? args[5] : ""
        // Older command lines had no password flag and always asked when a user name was set.
        let askPassword = type != "socks4" && (args.count >= 7 ? args[6] == "ask-password" : !username.isEmpty)

        var password = ""
        if askPassword {
            password = fetchProxyPassword() ?? ""
        }

        let fd: Int32
        do {
            fd = try TCP.connect(host: proxyHost, port: proxyPort)
        } catch {
            writeStderr("ssh: connect to proxy \(proxyHost) port \(proxyPort): \(error)")
            return 1
        }

        do {
            switch type {
            case "socks4":
                try TCP.send(fd, ProxyHandshake.socks4Request(host: targetHost, port: targetPort, userID: username))
                try ProxyHandshake.parseSocks4Reply(try TCP.receive(fd, count: 8))
            case "socks5":
                try TCP.send(fd, ProxyHandshake.socks5Greeting(withAuth: !username.isEmpty || askPassword))
                let method = try ProxyHandshake.parseSocks5MethodSelection(try TCP.receive(fd, count: 2))
                if method == 0x02 {
                    try TCP.send(fd, try ProxyHandshake.socks5UserPass(username: username, password: password))
                    try ProxyHandshake.parseSocks5AuthReply(try TCP.receive(fd, count: 2))
                } else if method != 0x00 {
                    throw ProxyHandshake.HandshakeError.authenticationRequired
                }
                try TCP.send(fd, try ProxyHandshake.socks5Connect(host: targetHost, port: targetPort))
                let header = try TCP.receive(fd, count: 4)
                var remaining = try ProxyHandshake.parseSocks5ConnectReplyHeader(header)
                if remaining < 0 { remaining = Int(try TCP.receive(fd, count: 1)[0]) + 2 }
                _ = try TCP.receive(fd, count: remaining)
            case "http":
                let request = ProxyHandshake.httpConnectRequest(host: targetHost, port: targetPort,
                                                                username: username.isEmpty ? nil : username, password: password)
                try TCP.send(fd, Array(request.utf8))
                let header = try TCP.receiveHTTPHeader(fd)
                try ProxyHandshake.parseHTTPConnectResponse(header)
            default:
            writeStderr("Portlane: unknown proxy type \(type)")
                return 2
            }
        } catch {
            writeStderr("ssh: proxy \(proxyHost):\(proxyPort) failed: \(error)")
            close(fd)
            return 1
        }

        TCP.relay(socket: fd)
        return 0
    }

    static func fetchProxyPassword() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env[AskpassEnvironment.socketPath],
              let token = env[AskpassEnvironment.token],
              let tunnel = env[AskpassEnvironment.tunnelID] else { return nil }
        let request = AskpassRequest(token: token, tunnelID: tunnel, kind: .proxyPassword, prompt: "Proxy password")
        guard let reply = try? UnixSocket.roundTrip(socketPath: socket, request: request), reply.ok else { return nil }
        return reply.answer
    }
}

/// Small blocking TCP helpers for the proxy helper.
enum TCP {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func connect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw Failure(description: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(first) }
        var lastError = ECONNREFUSED
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    var one: Int32 = 1
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    return fd
                }
                lastError = errno
                close(fd)
            }
            cursor = info.pointee.ai_next
        }
        throw Failure(description: String(cString: strerror(lastError)))
    }

    static func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        guard UnixSocket.writeAll(fd, Data(bytes)) else { throw Failure(description: "write failed") }
    }

    static func receive(_ fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { throw Failure(description: "proxy closed the connection") }
            got += n
        }
        return buffer
    }

    static func receiveHTTPHeader(_ fd: Int32) throws -> String {
        var data = [UInt8]()
        let terminator: [UInt8] = [13, 10, 13, 10]
        while data.count < 16_384 {
            data += try receive(fd, count: 1)
            if data.count >= 4 && Array(data.suffix(4)) == terminator { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Copies stdin → socket and socket → stdout until either side closes.
    static func relay(socket fd: Int32) {
        let upstream = Thread {
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress!, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                if !UnixSocket.writeAll(fd, Data(buffer[0..<n])) { break }
            }
            shutdown(fd, SHUT_WR)
        }
        upstream.start()

        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            if !UnixSocket.writeAll(STDOUT_FILENO, Data(buffer[0..<n])) { break }
        }
        close(fd)
    }
}
