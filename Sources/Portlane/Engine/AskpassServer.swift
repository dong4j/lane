import Foundation
import PortlaneCore
import Security

/// Listens on a private Unix socket for prompts relayed by the askpass / proxy helpers.
final class AskpassServer: @unchecked Sendable {
    typealias Handler = @Sendable (AskpassRequest) async -> AskpassReply

    let socketPath: String
    let token: String
    private var listenFD: Int32 = -1
    private let handler: Handler

    init(handler: @escaping Handler) {
        let dir = FileManager.default.temporaryDirectory.path
        socketPath = (dir as NSString).appendingPathComponent("portlane-\(getpid()).sock")
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        self.handler = handler
    }

    func start() throws {
        listenFD = try UnixSocket.listen(path: socketPath)
        let fd = listenFD
        let thread = Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard let self else { close(client); return }
                let worker = Thread { self.serve(client) }
                worker.start()
            }
        }
        thread.name = "portlane.askpass"
        thread.start()
    }

    func stop() {
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
            unlink(socketPath)
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let line = UnixSocket.readLine(fd),
              let request = try? JSONDecoder().decode(AskpassRequest.self, from: line),
              request.token == token else {
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        let handler = self.handler
        Task {
            box.reply = await handler(request)
            semaphore.signal()
        }
        semaphore.wait()
        guard var data = try? JSONEncoder().encode(box.reply) else { return }
        data.append(UInt8(ascii: "\n"))
        _ = UnixSocket.writeAll(fd, data)
    }

    private final class ReplyBox: @unchecked Sendable {
        var reply: AskpassReply = .cancelled
    }
}
