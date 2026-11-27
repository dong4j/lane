import Darwin
import Foundation
import LaneCore

/// The stdio process uses this socket to ask the running app to perform an authenticated action.
@MainActor
final class AgentIPC {
    typealias Handler = @MainActor @Sendable (AgentToolCall) async -> AgentToolResult

    private let socketPath: String
    private var listener: DispatchSourceRead?

    init(socketPath: String) { self.socketPath = socketPath }

    /// Neither socket I/O nor a stalled helper holds the app's main actor.
    func start(handler: @escaping Handler) throws {
        guard listener == nil else { return }
        let descriptor = try UnixSocket.listen(path: socketPath)
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1, fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            let code = errno
            close(descriptor)
            unlink(socketPath)
            throw UnixSocket.SocketError.system("fcntl", code)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { @Sendable in
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global(qos: .utility).async {
                Self.receive(client, handler: handler)
            }
        }
        source.setCancelHandler { @Sendable in close(descriptor) }
        listener = source
        source.resume()
    }

    func stop() {
        guard let listener else { return }
        self.listener = nil
        listener.cancel()
        unlink(socketPath)
    }

    nonisolated private static func receive(_ descriptor: Int32, handler: @escaping Handler) {
        guard configurePeer(descriptor), let data = UnixSocket.readLine(descriptor),
              let call = try? JSONDecoder().decode(AgentToolCall.self, from: data) else {
            close(descriptor)
            return
        }
        Task { @MainActor in
            let result = await handler(call)
            DispatchQueue.global(qos: .utility).async {
                defer { close(descriptor) }
                guard var data = try? AgentToolResult.encoder().encode(result) else { return }
                data.append(UInt8(ascii: "\n"))
                _ = UnixSocket.writeAll(descriptor, data)
            }
        }
    }

    /// A paired secret is sent only after checking that the peer belongs to the current macOS account.
    nonisolated static func send(_ call: AgentToolCall) throws -> AgentToolResult {
        let descriptor: Int32
        do {
            descriptor = try UnixSocket.connect(path: call.credential.socketPath)
        } catch {
            throw AgentToolError.unavailable
        }
        defer { close(descriptor) }
        guard configurePeer(descriptor) else { throw AgentToolError.unavailable }
        var data = try JSONEncoder().encode(call)
        data.append(UInt8(ascii: "\n"))
        guard UnixSocket.writeAll(descriptor, data),
              let reply = UnixSocket.readLine(descriptor, limit: 1_048_576),
              let result = try? AgentToolResult.decoder().decode(AgentToolResult.self, from: reply) else {
            throw AgentToolError.unavailable
        }
        return result
    }

    nonisolated private static func configurePeer(_ descriptor: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == geteuid(),
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1, fcntl(descriptor, F_SETFL, 0) != -1 else { return false }
        var timeout = timeval(tv_sec: 6, tv_usec: 0)
        var enabled: Int32 = 1
        return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 &&
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 &&
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    }
}
