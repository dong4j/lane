import Foundation

/// Builds the `/usr/bin/ssh` invocation for a tunnel.
public struct SSHCommandBuilder: Sendable {
    public struct Context: Sendable {
        public var sshPath: String
        /// Executable that implements `--proxy-connect` (the Lane binary itself).
        public var helperExecutable: String?
        /// Include `-v` so Porthole can follow connection progress.
        public var verbose: Bool
        /// A private control socket for a supervised connection. Rules are requested after authentication.
        public var controlPath: String?

        public init(sshPath: String = "/usr/bin/ssh", helperExecutable: String? = nil, verbose: Bool = true,
                    controlPath: String? = nil) {
            self.sshPath = sshPath
            self.helperExecutable = helperExecutable
            self.verbose = verbose
            self.controlPath = controlPath
        }
    }

    public var context: Context

    public init(context: Context = Context()) {
        self.context = context
    }

    /// Use the real proxy argument format without binding the comparison to an installation path.
    public static func connectionArguments(for tunnel: Tunnel) -> [String] {
        SSHCommandBuilder(context: .init(helperExecutable: "/Lane")).arguments(for: tunnel)
    }

    /// Resolve the same first-wins option OpenSSH receives for default loopback bindings.
    public static func prefersIPv6(for tunnel: Tunnel) -> Bool {
        let prefix = "addressfamily="
        if let option = parseExtraOptions(tunnel.extraOptions).first(where: { $0.lowercased().hasPrefix(prefix) }) {
            return option.dropFirst(prefix.count).lowercased() == "inet6"
        }
        return tunnel.addressFamily == .ipv6
    }

    /// Full argument vector (without the executable path).
    public func arguments(for tunnel: Tunnel) -> [String] {
        var args: [String] = ["-N"]
        if context.verbose { args.append("-v") }
        if !tunnel.useSSHConfig { args += ["-F", "/dev/null"] }

        func opt(_ key: String, _ value: String) { args += ["-o", "\(key)=\(value)"] }

        if let path = context.controlPath {
            // Apply before other options because OpenSSH keeps the first value it reads.
            args += ["-M", "-S", path]
            opt("ControlPersist", "no")
            opt("ClearAllForwardings", "yes")
        }
        // Behaviour Porthole relies on. These come first so nothing below can change them.
        for (key, value) in Self.requiredOptions {
            if context.controlPath != nil, ["ControlMaster", "ControlPath", "ClearAllForwardings"].contains(key) { continue }
            opt(key, value)
        }

        // User supplied options. ssh keeps the first value it sees for an option, so these go
        // before Porthole's own settings and therefore override them.
        for option in Self.parseExtraOptions(tunnel.extraOptions) {
            let key = option.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
            if Self.requiredOptions.contains(where: { $0.0.lowercased() == key }) { continue }
            args += ["-o", option]
        }

        // Connection
        opt("ConnectTimeout", String(max(1, tunnel.connectTimeout)))
        opt("ConnectionAttempts", String(max(1, tunnel.connectionAttempts)))
        opt("ServerAliveInterval", String(max(0, tunnel.keepAliveInterval)))
        opt("ServerAliveCountMax", String(max(1, tunnel.keepAliveCountMax)))
        let iface = tunnel.bindInterface.trimmingCharacters(in: .whitespaces)
        if !iface.isEmpty { opt("BindInterface", iface) }

        // Advanced
        opt("Compression", tunnel.compression ? "yes" : "no")
        opt("CheckHostIP", tunnel.checkHostIP ? "yes" : "no")
        opt("StrictHostKeyChecking", tunnel.hostKeyPolicy.sshValue)
        opt("AddressFamily", tunnel.addressFamily.sshValue)
        let hka = Self.cleanList(tunnel.hostKeyAlgorithms)
        if !hka.isEmpty { opt("HostKeyAlgorithms", hka) }
        let kex = Self.cleanList(tunnel.kexAlgorithms)
        if !kex.isEmpty { opt("KexAlgorithms", kex) }
        let ciphers = Self.cleanList(tunnel.ciphers)
        if !ciphers.isEmpty { opt("Ciphers", ciphers) }

        // Authentication
        switch tunnel.authMethod {
        case .automatic:
            break
        case .password:
            opt("PreferredAuthentications", "password,keyboard-interactive")
            opt("PubkeyAuthentication", "no")
            opt("NumberOfPasswordPrompts", "2")
        case .publicKey:
            let path = (tunnel.identityFile as NSString).expandingTildeInPath
            if !path.isEmpty { args += ["-i", path] }
            opt("IdentitiesOnly", "yes")
            // A server can want more once the key is accepted (sshd's `AuthenticationMethods
            // publickey,keyboard-interactive`), e.g. a one-time code. ssh only goes on to methods
            // listed here, so with "publickey" alone it gives up after the key's partial success.
            opt("PreferredAuthentications", "publickey,keyboard-interactive,password")
        case .keyboardInteractive:
            // publickey last, for servers that want a key (agent or ~/.ssh) before the code.
            opt("PreferredAuthentications", "keyboard-interactive,password,publickey")
            opt("NumberOfPasswordPrompts", "2")
        }

        // Proxy / jump host
        switch tunnel.proxy.kind {
        case .none:
            break
        case .jumpHost:
            var jump = tunnel.proxy.host
            if !tunnel.proxy.username.isEmpty { jump = "\(tunnel.proxy.username)@\(jump)" }
            if tunnel.proxy.port != 22 && tunnel.proxy.port > 0 { jump += ":\(tunnel.proxy.port)" }
            args += ["-J", jump]
        case .socks4, .socks5, .http:
            if let cmd = proxyCommand(for: tunnel) { opt("ProxyCommand", cmd) }
        }

        // Forwardings
        if context.controlPath == nil {
            for f in tunnel.enabledForwardings {
                args += [f.kind.flag, f.sshSpec]
            }
        }

        // Port 22 is ssh's default anyway; leaving it out lets a `Port` line in ~/.ssh/config apply
        // when the host is one of its aliases.
        if tunnel.port != 22 || !tunnel.useSSHConfig { args += ["-p", String(tunnel.port)] }
        let user = tunnel.user.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { args += ["-l", user] }
        // `--` stops option parsing so a host can never be interpreted as a flag.
        args += ["--", tunnel.host.trimmingCharacters(in: .whitespaces)]
        return args
    }

    /// The ProxyCommand that routes the connection through Porthole's proxy helper.
    public func proxyCommand(for tunnel: Tunnel) -> String? {
        let p = tunnel.proxy
        guard p.kind == .socks4 || p.kind == .socks5 || p.kind == .http else { return nil }
        guard let helper = context.helperExecutable else {
            // Fallback to the system netcat (no proxy authentication support).
            let flag: String
            switch p.kind {
            case .socks4: flag = "4"
            case .socks5: flag = "5"
            default: flag = "connect"
            }
            return "/usr/bin/nc -X \(flag) -x \(p.host):\(p.port) %h %p"
        }
        var parts = [Self.shellQuote(helper), "--proxy-connect", p.kind.rawValue, Self.shellQuote(p.host), String(p.port), "%h", "%p"]
        // SOCKS4 has no passwords; for the others the helper only asks when the proxy needs one.
        let askPassword = p.kind != .socks4 && p.requiresPassword
        if !p.username.isEmpty || askPassword {
            parts.append(Self.shellQuote(p.username))
            parts.append(askPassword ? "ask-password" : "no-password")
        }
        // ssh expands %-tokens in ProxyCommand; the helper path, host and user name are taken literally.
        return parts.enumerated().map { i, part in (5...6).contains(i) ? part : part.replacingOccurrences(of: "%", with: "%%") }
            .joined(separator: " ")
    }

    /// Options Porthole's supervision depends on. User supplied options can't override them.
    public static let requiredOptions: [(String, String)] = [
        ("ExitOnForwardFailure", "yes"),
        ("ForkAfterAuthentication", "no"),
        ("ClearAllForwardings", "no"),
        ("BatchMode", "no"),
        ("ControlMaster", "no"),
        ("ControlPath", "none"),
        ("RequestTTY", "no"),
        ("PermitLocalCommand", "no"),
        ("ForwardAgent", "no"),
        ("ForwardX11", "no"),
    ]

    /// Shell-escaped command line, for "Copy SSH Command". Omits `-v`.
    public func displayCommand(for tunnel: Tunnel) -> String {
        var b = self
        b.context.verbose = false
        b.context.controlPath = nil
        let args = b.arguments(for: tunnel).filter { $0 != "--" }
        // Drop options that only matter to Porthole's supervision to keep the command readable.
        var cleaned: [String] = []
        var i = 0
        let internalOptions: Set<String> = ["BatchMode=no", "ControlMaster=no", "ControlPath=none", "RequestTTY=no", "PermitLocalCommand=no"]
        while i < args.count {
            if args[i] == "-o", i + 1 < args.count, internalOptions.contains(args[i + 1]) {
                i += 2
                continue
            }
            cleaned.append(args[i])
            i += 1
        }
        return ([context.sshPath] + cleaned).map(Self.shellQuote).joined(separator: " ")
    }

    // MARK: helpers

    public static func cleanList(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }

    /// Converts free-form lines (`Key value`, `Key=value`, `-o Key=value`) to `Key=value`.
    public static func parseExtraOptions(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            if line.hasPrefix("-o") { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
                return "\(key)=\(value)"
            }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { return nil }
            let key = String(parts[0])
            guard key.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return "\(key)=\(parts[1].trimmingCharacters(in: .whitespaces))"
        }
    }

    /// A backup can supply connection settings. Local commands and program/provider paths require local configuration.
    public static func backupOptions(_ text: String) -> (allowed: String, ignored: Set<String>) {
        let supported: Set<String> = [
            "addressfamily", "checkhostip", "ciphers", "compression", "connectionattempts", "connecttimeout",
            "gatewayports", "hostkeyalgorithms", "identitiesonly", "identityfile", "kexalgorithms", "macs",
            "preferredauthentications", "pubkeyacceptedalgorithms", "rekeylimit", "serveralivecountmax",
            "serveraliveinterval", "stricthostkeychecking"
        ]
        var allowed: [String] = []
        var ignored: Set<String> = []
        for option in parseExtraOptions(text) {
            let key = String(option.prefix { $0 != "=" })
            if supported.contains(key.lowercased()) {
                allowed.append(option)
            } else {
                ignored.insert(key.lowercased())
            }
        }
        return (allowed.joined(separator: "\n"), ignored)
    }

    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
