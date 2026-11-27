import Darwin
import Foundation
import Security

/// File locations for the local audit, pairings, and the private Unix-domain socket.
struct AgentFiles {
    let directory: URL
    let socketPath: String

    var ledger: URL { directory.appending(path: "activity.json") }

    static func live(tunnelFile: URL) -> Self {
        let directory = (ProcessInfo.processInfo.environment["PORTLANE_DATA_FILE"] ?? "").isEmpty
            ? tunnelFile.deletingLastPathComponent().appending(path: "Agent", directoryHint: .isDirectory)
            : tunnelFile.appendingPathExtension("agent")
        // Use the same macOS user directory under Launch Services and when launched from a shell.
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        var temporary = [CChar](repeating: 0, count: max(length, 1))
        let written = confstr(_CS_DARWIN_USER_TEMP_DIR, &temporary, temporary.count)
        let temporaryPath = written == 0 ? FileManager.default.temporaryDirectory.path :
            String(decoding: temporary.prefix(written - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let socket = URL(fileURLWithPath: temporaryPath, isDirectory: true).appending(path: "portlane-agent.sock")
        return Self(directory: directory, socketPath: socket.path)
    }

    func credentialURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString.lowercased()).pairing")
    }

    /// Keep the token out of the audit and out of copied commands.
    func writeCredential(_ credential: AgentCredential) throws {
        let url = credentialURL(credential.clientID)
        try write(JSONEncoder().encode(credential), to: url)
    }

    func writeLedger(_ snapshot: AgentLedger) throws {
        try write(JSONEncoder().encode(snapshot), to: ledger)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try data.write(to: url, options: .atomic)
        // The containing directory is already private even before the file is chmod'ed.
        guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }

    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Data(bytes).base64EncodedString()
    }
}
