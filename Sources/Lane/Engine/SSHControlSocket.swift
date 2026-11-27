import Foundation
import LaneCore

/// A private OpenSSH master socket lets the app apply exactly its own rules after authentication.
struct SSHControlSocket: Sendable {
    struct Failure: Error, Sendable {
        let rule: Forwarding
        let detail: String
    }

    private let directory: URL
    let url: URL

    init() throws {
        // Use a short path to stay within the sockaddr_un limit on macOS.
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "pl-\(UUID().uuidString)", directoryHint: .isDirectory)
        url = directory.appending(path: "ssh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Each acknowledgement belongs to one rule, including server-side remote forwarding errors.
    func apply(_ rules: [Forwarding], ssh: String) -> Failure? {
        for rule in rules {
            guard !Task.isCancelled else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ssh)
            process.arguments = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                                 "-S", url.path, "-O", "forward", rule.kind.flag, rule.sshSpec, "--", "localhost"]
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                let result = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let detail = String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return Failure(rule: rule, detail: detail)
                }
            } catch {
                return Failure(rule: rule, detail: error.localizedDescription)
            }
        }
        return nil
    }
}
