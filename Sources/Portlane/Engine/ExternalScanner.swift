import Darwin
import Foundation
import PortlaneCore

/// Takes a read-only snapshot of this user's OpenSSH processes and their listening sockets.
enum ExternalScanner {
    /// `ps` supplies ownership and executable identity before any argv is read.
    static func scan(excluding owned: Set<Int32>) throws -> [ExternalSession] {
        let candidates = try run("/bin/ps", ["-x", "-U", String(getuid()), "-o", "pid=,comm="])
            .split(separator: "\n")
            .compactMap { line -> Int32? in
                let columns = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard columns.count == 2, let pid = Int32(columns[0]), !owned.contains(pid),
                      (String(columns[1]) as NSString).lastPathComponent == "ssh" else { return nil }
                return pid
            }
        guard !candidates.isEmpty else { return [] }
        let endpoints = try listeners(pids: candidates)
        return candidates.compactMap { pid in
            let invocation = processArguments(pid).map(SSHInvocation.init(arguments:))
            return ExternalSession(pid: pid, invocation: invocation, listeners: endpoints)
        }
        .sorted { ($0.host ?? "", $0.id) < ($1.host ?? "", $1.id) }
    }

    /// A listener is attributed to the exact owning PID, never inferred from a TCP connect.
    static func listeners(pids: [Int32]) throws -> [ListeningEndpoint] {
        guard !pids.isEmpty else { return [] }
        let selection = pids.map(String.init).joined(separator: ",")
        let output = try run("/usr/sbin/lsof", ["-nP", "-a", "-p", selection, "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                             noMatchesIsSuccess: true)
        return ListeningEndpoint.parseLsof(output)
    }

    /// `KERN_PROCARGS2` is NUL-delimited. Read only argc entries, leaving the environment unparsed.
    private static func processArguments(_ pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length >= 5 else { return nil }
        var data = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &data, &length, nil, 0) == 0,
              length >= MemoryLayout<Int32>.size else { return nil }

        let count = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard count > 0, count <= length else { return nil }
        var offset = MemoryLayout<Int32>.size
        while offset < length, data[offset] != 0 { offset += 1 }
        while offset < length, data[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard offset < length, let end = data[offset..<length].firstIndex(of: 0) else { return nil }
            arguments.append(String(decoding: data[offset..<end], as: UTF8.self))
            offset = end + 1
        }
        return arguments
    }

    private static func run(_ executable: String, _ arguments: [String], noMatchesIsSuccess: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            if noMatchesIsSuccess, process.terminationStatus == 1,
               result.isEmpty || result.split(separator: "\n").contains(where: { $0.first == "p" }) {
                return result
            }
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(process.terminationStatus)."
            ])
        }
        return result
    }
}
