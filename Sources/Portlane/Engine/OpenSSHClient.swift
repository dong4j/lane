import Foundation

/// Verifies user-selected OpenSSH executables before the connection manager can use them.
enum OpenSSHClient {
    static let systemPath = "/usr/bin/ssh"

    enum CheckError: LocalizedError {
        case notExecutable, unsupported, timedOut

        var errorDescription: String? {
            switch self {
            case .notExecutable: L10n.text("Choose an absolute path to an executable file.", "请选择可执行文件的绝对路径。")
            case .unsupported: L10n.text("The selected file did not report an OpenSSH version.", "所选文件未返回 OpenSSH 版本。")
            case .timedOut: L10n.text("The OpenSSH version check timed out.", "检查 OpenSSH 版本超时。")
            }
        }
    }

    static func expandedPath(_ input: String) -> String {
        (input.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    /// `ssh -V` uses stderr. Bound the wait because the selected executable may be something else.
    static func version(at path: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try probe(path) })
            }
        }
    }

    private static func probe(_ path: String) throws -> String {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw CheckError.notExecutable
        }
        let child = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        child.executableURL = URL(fileURLWithPath: path)
        child.arguments = ["-V"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = output
        child.terminationHandler = { _ in finished.signal() }
        try child.run()
        guard finished.wait(timeout: .now() + 3) == .success else {
            child.terminate()
            throw CheckError.timedOut
        }
        guard child.terminationStatus == 0,
              let data = try output.fileHandleForReading.read(upToCount: 4_096) else {
            throw CheckError.unsupported
        }
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.hasPrefix("OpenSSH_") else { throw CheckError.unsupported }
        return version
    }
}
