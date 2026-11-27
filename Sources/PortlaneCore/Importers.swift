import Foundation

// MARK: - ~/.ssh/config

/// Imports `Host` blocks from an OpenSSH client config that define port forwardings.
public enum SSHConfigImporter {
    public struct Entry: Equatable, Sendable {
        public var alias: String
        public var options: [(String, String)]

        public static func == (a: Entry, b: Entry) -> Bool {
            a.alias == b.alias && a.options.map { "\($0.0)=\($0.1)" } == b.options.map { "\($0.0)=\($0.1)" }
        }

        func values(_ key: String) -> [String] {
            options.filter { $0.0.lowercased() == key.lowercased() }.map(\.1)
        }

        func value(_ key: String) -> String? { values(key).first }
    }

    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var current: Entry?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (key, value) = splitKeyValue(line)
            guard !key.isEmpty else { continue }
            switch key.lowercased() {
            case "host":
                if let c = current { entries.append(c) }
                // Only plain aliases become tunnels; patterns like `*` or `!foo` are skipped.
                let aliases = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let plain = aliases.first { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                current = plain.map { Entry(alias: $0, options: []) }
            case "match":
                if let c = current { entries.append(c) }
                current = nil
            default:
                current?.options.append((key, value))
            }
        }
        if let c = current { entries.append(c) }
        return entries
    }

    /// Tunnels for every host block that has at least one forwarding.
    public static func tunnels(fromConfig text: String) -> [Tunnel] {
        parse(text).compactMap { entry in
            var forwards: [Forwarding] = []
            for v in entry.values("LocalForward") {
                if let f = parseForward(v, kind: .local) { forwards.append(f) }
            }
            for v in entry.values("RemoteForward") {
                if let f = parseForward(v, kind: .remote) { forwards.append(f) }
            }
            for v in entry.values("DynamicForward") {
                if let f = parseForward(v, kind: .dynamic) { forwards.append(f) }
            }
            guard !forwards.isEmpty else { return nil }

            var t = Tunnel(name: entry.alias, host: entry.alias)
            // Keep `host` as the alias so ssh picks up every option from the config itself.
            t.useSSHConfig = true
            t.port = entry.value("Port").flatMap(Int.init) ?? 22
            t.user = entry.value("User") ?? ""
            if let identity = entry.value("IdentityFile") {
                t.identityFile = identity
                t.authMethod = .publicKey
            }
            if let real = entry.value("HostName") {
                t.note = String(localized: "Imported from ~/.ssh/config (\(real))")
            } else {
                t.note = String(localized: "Imported from ~/.ssh/config")
            }
            t.forwardings = forwards
            return t
        }
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
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        return (key, value)
    }

    /// Parses `[bind:]port host:hostport` (Local/Remote) or `[bind:]port` (Dynamic).
    public static func parseForward(_ value: String, kind: ForwardingKind) -> Forwarding? {
        let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
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
