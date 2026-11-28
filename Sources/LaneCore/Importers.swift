import Darwin
import Foundation

// MARK: - ~/.ssh/config

/// Imports `Host` blocks from an OpenSSH client config that define port forwardings.
public enum SSHConfigImporter {
    public struct Entry: Equatable, Sendable {
        public var alias: String
        public var options: [(String, String)]
        public var source: URL?

        public static func == (a: Entry, b: Entry) -> Bool {
            a.alias == b.alias && a.source == b.source &&
                a.options.map { "\($0.0)=\($0.1)" } == b.options.map { "\($0.0)=\($0.1)" }
        }

        func values(_ key: String) -> [String] {
            options.filter { $0.0.lowercased() == key.lowercased() }.map(\.1)
        }

        func value(_ key: String) -> String? { values(key).first }
    }

    public enum Notice: Hashable, Sendable {
        case noFiles(String), unreadable(String), includeCycle(String), dynamicInclude(String), matchBlock(String)
    }

    public struct Preview: Sendable {
        public let tunnels: [Tunnel]
        public let sources: [UUID: URL]
        public let notices: [Notice]
    }

    private struct Directive {
        let key: String
        let value: String
        let source: URL?
        var includes: [[Directive]] = []
    }

    public static func parse(_ text: String) -> [Entry] {
        entries(from: directives(text, source: nil))
    }

    /// Resolve relative includes from the user's config directory and keep each included file's Host scope local.
    public static func preview(file: URL) throws -> Preview {
        var notices: [Notice] = []
        let lines = try read(file, relativeTo: file.deletingLastPathComponent(), ancestry: [], notices: &notices)
        let rows = entries(from: lines).compactMap { entry -> (Tunnel, URL?)? in
            tunnel(from: entry).map { ($0, entry.source) }
        }
        var sources: [UUID: URL] = [:]
        for (tunnel, source) in rows { sources[tunnel.id] = source }
        var seen: Set<Notice> = []
        return Preview(tunnels: rows.map(\.0), sources: sources, notices: notices.filter { seen.insert($0).inserted })
    }

    private static func read(_ url: URL, relativeTo root: URL, ancestry: [URL], notices: inout [Notice]) throws -> [Directive] {
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        guard ancestry.count < 16, !ancestry.contains(file) else {
            notices.append(.includeCycle(url.path))
            return []
        }
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var inMatch = false
        return try directives(String(contentsOf: file, encoding: .utf8), source: url).map { line in
            var line = line
            if line.key == "match" {
                notices.append(.matchBlock(url.path))
                inMatch = true
            }
            if line.key == "host" { inMatch = false }
            if line.key == "include", !inMatch {
                for word in words(line.value) {
                    if word.contains("%") || word.contains("${") {
                        notices.append(.dynamicInclude(word))
                        continue
                    }
                    let expanded = (word as NSString).expandingTildeInPath
                    let pattern = expanded.hasPrefix("/") ? expanded : root.appending(path: expanded).path
                    let paths = matchingPaths(pattern)
                    if paths.isEmpty { notices.append(.noFiles(word)) }
                    for path in paths {
                        do {
                            let included = try read(URL(fileURLWithPath: path), relativeTo: root,
                                                    ancestry: ancestry + [file], notices: &notices)
                            line.includes.append(included)
                        } catch {
                            notices.append(.unreadable(path))
                        }
                    }
                }
            }
            return line
        }
    }

    private static func matchingPaths(_ pattern: String) -> [String] {
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(pattern, 0, nil, &matches) == 0, let paths = matches.gl_pathv else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { paths[$0].map { String(cString: $0) } }
    }

    private static func directives(_ text: String, source: URL?) -> [Directive] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let (key, value) = splitKeyValue(line)
            return Directive(key: key.lowercased(), value: value, source: source)
        }
    }

    private static func aliases(in lines: [Directive]) -> [String] {
        lines.flatMap { line in
            if line.key == "include" { return line.includes.flatMap(aliases(in:)) }
            guard line.key == "host" else { return [] }
            return words(line.value).filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
    }

    private static func entries(from lines: [Directive]) -> [Entry] {
        var seen: Set<String> = []
        return aliases(in: lines).filter { seen.insert($0).inserted }.compactMap { alias in
            var entry = Entry(alias: alias, options: [], source: nil)
            return collect(lines, into: &entry) ? entry : nil
        }
    }

    private static func collect(_ lines: [Directive], into entry: inout Entry) -> Bool {
        var active = true
        var explicit = false
        for line in lines {
            switch line.key {
            case "host":
                let patterns = words(line.value)
                let matches = patterns.filter { pattern in
                    let candidate = pattern.hasPrefix("!") ? String(pattern.dropFirst()) : pattern
                    return fnmatch(candidate, entry.alias, 0) == 0
                }
                active = !matches.isEmpty && !matches.contains { $0.hasPrefix("!") }
                if active, matches.contains(entry.alias) {
                    explicit = true
                    if entry.source == nil { entry.source = line.source }
                }
            case "match":
                active = false
            case "include" where active:
                for file in line.includes {
                    if collect(file, into: &entry) { explicit = true }
                }
            case "include":
                break
            default:
                if active { entry.options.append((line.key, line.value)) }
            }
        }
        return explicit
    }

    /// Tunnels for every host block that has at least one forwarding.
    public static func tunnels(fromConfig text: String) -> [Tunnel] {
        parse(text).compactMap(tunnel(from:))
    }

    private static func tunnel(from entry: Entry) -> Tunnel? {
        var forwards: [Forwarding] = []
        for (key, kind) in [("LocalForward", ForwardingKind.local), ("RemoteForward", .remote), ("DynamicForward", .dynamic)] {
            for value in entry.values(key) {
                guard let rule = parseForward(value, kind: kind),
                      !forwards.contains(where: { $0.kind == kind && $0.sshSpec == rule.sshSpec }) else { continue }
                forwards.append(rule)
            }
        }
        guard !forwards.isEmpty else { return nil }
        var tunnel = Tunnel(name: entry.alias, host: entry.alias)
        tunnel.useSSHConfig = true
        tunnel.port = entry.value("Port").flatMap { words($0).first }.flatMap(Int.init) ?? 22
        tunnel.user = entry.value("User").flatMap { words($0).first } ?? ""
        if let identity = entry.value("IdentityFile").flatMap({ words($0).first }) {
            tunnel.identityFile = identity
            tunnel.authMethod = .publicKey
        }
        if let real = entry.value("HostName").flatMap({ words($0).first }) {
            tunnel.note = String(localized: "Imported from ~/.ssh/config (\(real))")
        } else {
            tunnel.note = String(localized: "Imported from ~/.ssh/config")
        }
        tunnel.forwardings = forwards
        return tunnel
    }

    static func splitKeyValue(_ line: String) -> (String, String) {
        // Accepts "Key value", "Key=value" and "Key = value".
        var key = ""
        var rest = Substring(line)
        if let idx = line.firstIndex(where: { $0 == "=" || $0.isWhitespace }) {
            key = String(line[..<idx])
            rest = line[idx...]
        } else {
            return (line, "")
        }
        var value = rest.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("=") { value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return (key, value)
    }

    /// Tokenize paths and aliases without shell evaluation.
    private static func words(_ value: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !word.isEmpty { words.append(word); word = "" }
            } else if character == "#", word.isEmpty {
                break
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    /// Parses `[bind:]port host:hostport` (Local/Remote) or `[bind:]port` (Dynamic).
    public static func parseForward(_ value: String, kind: ForwardingKind) -> Forwarding? {
        let parts = words(value)
        guard let listen = parts.first else { return nil }
        let (bind, portString) = splitHostPort(listen, portOnlyAllowed: true)
        guard let port = Int(portString) else { return nil }
        var f = Forwarding(kind: kind, bindAddress: bind, port: port, targetHost: "", targetPort: 0)
        if kind == .dynamic { return f }
        guard parts.count >= 2 else { return nil }
        let (host, hp) = splitHostPort(parts[1], portOnlyAllowed: false)
        guard let hostport = Int(hp), !host.isEmpty else { return nil }
        f.targetHost = host
        f.targetPort = hostport
        return f
    }

    static func splitHostPort(_ s: String, portOnlyAllowed: Bool) -> (String, String) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            return (host, after.hasPrefix(":") ? String(after.dropFirst()) : "")
        }
        if let colon = s.lastIndex(of: ":") {
            return (String(s[..<colon]), String(s[s.index(after: colon)...]))
        }
        return portOnlyAllowed ? ("", s) : (s, "")
    }
}

// MARK: - Codinn "SSH Tunnel" export

/// Best-effort importer for files exported by the original SSH Tunnel app (Mantle JSON).
/// The exact export layout was not observed, so this accepts the model property names found in the
/// app binary (`ssh_host`, `ssh_user`, `forwardings`, `bind_address`, `hostport`, …) wherever they appear.
public enum LegacySSHTunnelImporter {
    public static func tunnels(from data: Data) throws -> [Tunnel] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var found: [[String: Any]] = []
        collectSessions(object, into: &found)
        return found.compactMap(tunnel(from:))
    }

    static func collectSessions(_ object: Any, into result: inout [[String: Any]]) {
        if let dict = object as? [String: Any] {
            if dict["ssh_host"] != nil || dict["sshHost"] != nil {
                result.append(dict)
                return
            }
            for value in dict.values { collectSessions(value, into: &result) }
        } else if let array = object as? [Any] {
            for value in array { collectSessions(value, into: &result) }
        }
    }

    static func string(_ d: [String: Any], _ keys: String...) -> String? {
        for k in keys {
            if let s = d[k] as? String { return s }
            if let n = d[k] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    static func int(_ d: [String: Any], _ keys: String...) -> Int? {
        for k in keys {
            if let n = d[k] as? NSNumber { return n.intValue }
            if let s = d[k] as? String, let v = Int(s.trimmingCharacters(in: .whitespaces)) { return v }
        }
        return nil
    }

    static func bool(_ d: [String: Any], _ keys: String...) -> Bool? {
        for k in keys {
            if let n = d[k] as? NSNumber { return n.boolValue }
            if let s = d[k] as? String { return ["1", "yes", "true", "on"].contains(s.lowercased()) }
        }
        return nil
    }

    static func tunnel(from d: [String: Any]) -> Tunnel? {
        guard let host = string(d, "ssh_host", "sshHost"), !host.isEmpty else { return nil }
        var t = Tunnel()
        t.host = host
        t.name = string(d, "name", "tunnel_name", "session_name") ?? host
        t.note = string(d, "comment", "note") ?? ""
        t.port = int(d, "ssh_port", "sshPort") ?? 22
        t.user = string(d, "ssh_user", "sshUser") ?? ""
        t.autoConnect = bool(d, "auto_connect", "autoConnect") ?? false
        t.connectTimeout = int(d, "connection_timeout", "connect_timeout") ?? t.connectTimeout
        t.connectionAttempts = max(1, int(d, "connection_attempts") ?? 1)
        t.keepAliveCountMax = max(1, int(d, "server_alive_count_max") ?? t.keepAliveCountMax)
        t.compression = bool(d, "compression", "enable_compression") ?? false
        t.checkHostIP = bool(d, "check_host_ip") ?? false
        if let strict = bool(d, "strict_hostkey_checking") { t.hostKeyPolicy = strict ? .ask : .acceptNew }
        switch int(d, "address_familly", "address_family") {
        case 0: t.addressFamily = .ipv4
        case 1: t.addressFamily = .ipv6
        default: t.addressFamily = .any
        }
        t.hostKeyAlgorithms = string(d, "hostkey_algorithms") ?? ""
        t.kexAlgorithms = string(d, "key_exchange_algorithms") ?? ""
        t.ciphers = string(d, "ciphers") ?? ""
        if let iface = string(d, "connect_interface"), iface.lowercased() != "auto", iface.lowercased() != "automatic" {
            t.bindInterface = iface
        }

        // Authentication: `auth_methods` may be an array of names or of dictionaries.
        var methods: [String] = []
        if let arr = d["auth_methods"] as? [Any] {
            for m in arr {
                if let s = m as? String { methods.append(s.lowercased()) }
                if let md = m as? [String: Any], let s = string(md, "method_name") { methods.append(s.lowercased()) }
            }
        } else if let s = string(d, "auth_methods", "auth_method") {
            methods = s.lowercased().components(separatedBy: CharacterSet(charactersIn: ", "))
        }
        if methods.contains(where: { $0.contains("public") }) {
            t.authMethod = .publicKey
        } else if methods.contains(where: { $0.contains("interactive") }) {
            t.authMethod = .keyboardInteractive
        } else if methods.contains(where: { $0.contains("password") }) {
            t.authMethod = .password
        }
        if let key = string(d, "privatekey_path") { t.identityFile = key }

        // Proxy
        if bool(d, "proxy_command") == true, let ph = string(d, "proxy_command_host"), !ph.isEmpty {
            var p = ProxySettings()
            switch int(d, "proxy_command_type") {
            case 0: p.kind = .socks4
            case 2: p.kind = .http
            default: p.kind = .socks5
            }
            p.host = ph
            p.port = int(d, "proxy_command_port") ?? p.kind.defaultPort
            p.username = string(d, "proxy_command_username") ?? ""
            p.requiresPassword = bool(d, "proxy_command_auth") ?? false
            t.proxy = p
        }

        if let forwards = d["forwardings"] as? [Any] {
            t.forwardings = forwards.compactMap { item in
                guard let fd = item as? [String: Any] else { return nil }
                return forwarding(from: fd)
            }
        }
        return t
    }

    static func forwarding(from d: [String: Any]) -> Forwarding? {
        var kind: ForwardingKind = .local
        if let n = int(d, "type") {
            kind = n == 1 ? .remote : (n == 2 ? .dynamic : .local)
        } else if let s = string(d, "type", "typeName")?.lowercased() {
            if s.contains("remote") || s == "r" { kind = .remote }
            else if s.contains("dynamic") || s == "d" { kind = .dynamic }
        }
        guard let port = int(d, "port") else { return nil }
        return Forwarding(
            kind: kind,
            bindAddress: string(d, "bind_address", "bindAddress") ?? "",
            port: port,
            targetHost: string(d, "host") ?? (kind == .dynamic ? "" : "localhost"),
            targetPort: int(d, "hostport", "host_port") ?? 0,
            enabled: bool(d, "enabled") ?? true,
            note: string(d, "note") ?? ""
        )
    }
}
