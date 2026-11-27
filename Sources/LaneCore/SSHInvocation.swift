import Foundation

/// The displayable subset of an already-running OpenSSH command.
public struct SSHInvocation: Sendable {
    public private(set) var host: String?
    public private(set) var forwards: [Forwarding] = []

    /// Consumes a real argv, preserving whitespace in SSH paths and option values.
    public init(arguments: [String]) {
        let takesValue: Set<Character> = [
            "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o",
            "P", "p", "Q", "R", "S", "W", "w"
        ]
        var remaining = arguments.dropFirst().makeIterator()
        while let argument = remaining.next() {
            if argument == "--" {
                if host == nil { host = remaining.next() }
                break
            }
            if !argument.hasPrefix("-") {
                if host != nil { break }
                host = argument
                continue
            }
            var flags = argument.dropFirst()
            while let flag = flags.popFirst() {
                guard takesValue.contains(flag) else { continue }
                guard let value = flags.isEmpty ? remaining.next() : String(flags) else { break }
                switch flag {
                case "L": append(Self.parseSpecification(value, kind: .local))
                case "R": append(Self.parseSpecification(value, kind: .remote))
                case "D": append(Self.parseSpecification(value, kind: .dynamic))
                case "o": append(Self.parseOption(value))
                default: break
                }
                break
            }
        }
    }

    /// Accepts TCP forms only. Bracketed IPv6 literals occupy a single address field.
    public static func parseSpecification(_ value: String, kind: ForwardingKind) -> Forwarding? {
        var fields = [""]
        var bracketed = false
        for character in value {
            switch character {
            case "[": bracketed = true
            case "]": bracketed = false
            case ":" where !bracketed: fields.append("")
            default: fields[fields.count - 1].append(character)
            }
        }
        guard !bracketed else { return nil }
        let fieldCount = kind == .dynamic ? 1 : 3
        guard fields.count == fieldCount || fields.count == fieldCount + 1 else { return nil }
        let offset = fields.count - fieldCount
        guard let port = Int(fields[offset]), TunnelValidator.isValidPort(port) else { return nil }
        let bind = offset == 0 ? "" : fields[0]
        if kind == .dynamic { return Forwarding(kind: kind, bindAddress: bind, port: port) }
        let target = fields[offset + 1]
        guard !target.isEmpty, let targetPort = Int(fields[offset + 2]),
              TunnelValidator.isValidPort(targetPort) else { return nil }
        return Forwarding(kind: kind, bindAddress: bind, port: port, targetHost: target, targetPort: targetPort)
    }

    /// Parses the forwarding directives used in an expanded ssh_config or passed through `-o`.
    public static func parseOption(_ option: String) -> Forwarding? {
        let (key, value) = SSHConfigImporter.splitKeyValue(option)
        let kind: ForwardingKind
        switch key.lowercased() {
        case "localforward": kind = .local
        case "remoteforward": kind = .remote
        case "dynamicforward": kind = .dynamic
        default: return nil
        }
        return SSHConfigImporter.parseForward(value, kind: kind).flatMap {
            TunnelValidator.validate($0).contains(where: { $0.severity == .error }) ? nil : $0
        }
    }

    private mutating func append(_ forward: Forwarding?) {
        if let forward, !forwards.contains(where: { $0.kind == forward.kind && $0.sshSpec == forward.sshSpec }) {
            forwards.append(forward)
        }
    }
}
