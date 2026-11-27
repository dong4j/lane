import Foundation

// MARK: - Forwarding

public enum ForwardingKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case remote
    case dynamic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .local: return String(localized: "Local")
        case .remote: return String(localized: "Remote")
        case .dynamic: return String(localized: "SOCKS Proxy")
        }
    }

    public var flag: String {
        switch self {
        case .local: return "-L"
        case .remote: return "-R"
        case .dynamic: return "-D"
        }
    }

    public var symbolName: String {
        switch self {
        case .local: return "arrow.down.left.circle.fill"
        case .remote: return "arrow.up.right.circle.fill"
        case .dynamic: return "globe.americas.fill"
        }
    }

    /// Whether the listening socket lives on this Mac.
    public var listensLocally: Bool { self != .remote }
}

public struct Forwarding: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: ForwardingKind
    /// Optional display name, separate from the note and effective OpenSSH arguments.
    public var name: String
    /// Listening address. Empty means ssh's default (loopback), `*` means all interfaces.
    public var bindAddress: String
    public var port: Int
    public var targetHost: String
    public var targetPort: Int
    public var enabled: Bool
    public var note: String

    public init(
        id: UUID = UUID(),
        kind: ForwardingKind = .local,
        bindAddress: String = "",
        port: Int = 8080,
        targetHost: String = "localhost",
        targetPort: Int = 80,
        enabled: Bool = true,
        note: String = "",
        name: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.bindAddress = bindAddress
        self.port = port
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.enabled = enabled
        self.note = note
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, bindAddress, port, targetHost, targetPort, enabled, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(ForwardingKind.self, forKey: .kind) ?? .local
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        targetHost = try c.decodeIfPresent(String.self, forKey: .targetHost) ?? ""
        targetPort = try c.decodeIfPresent(Int.self, forKey: .targetPort) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    /// The `-L` / `-R` / `-D` argument value as ssh expects it.
    public var sshSpec: String {
        let bind = bindAddress.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if !bind.isEmpty { parts.append(Self.bracketIfIPv6(bind)) }
        parts.append(String(port))
        if kind != .dynamic {
            parts.append(Self.bracketIfIPv6(targetHost.trimmingCharacters(in: .whitespaces)))
            parts.append(String(targetPort))
        }
        return parts.joined(separator: ":")
    }

    /// Human readable command fragment, e.g. `-L 8080:db.internal:5432`.
    public var commandString: String { "\(kind.flag) \(sshSpec)" }

    /// The address a client should connect to (for local / dynamic forwards).
    public var listenDisplayAddress: String {
        let bind = bindAddress.trimmingCharacters(in: .whitespaces)
        let host: String
        switch bind {
        case "", "localhost": host = "localhost"
        case "*", "0.0.0.0": host = kind == .remote ? "*" : "0.0.0.0"
        default: host = bind
        }
        return "\(Self.bracketIfIPv6(host)):\(port)"
    }

    public var targetDisplayAddress: String {
        "\(Self.bracketIfIPv6(targetHost)):\(targetPort)"
    }

    /// Plain-language description used in the editor.
    public func explanation(serverName: String) -> String {
        let server = serverName.isEmpty ? String(localized: "the SSH server") : serverName
        let listen = listenDisplayAddress, target = targetDisplayAddress
        switch kind {
        case .local:
            return String(localized: "Apps on this Mac connect to \(listen). Traffic travels through \(server), which then connects to \(target).")
        case .remote:
            if bindAddress.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "\(server) listens on port \(String(port)). Connections there come back through the tunnel to \(target) as seen from this Mac.")
            }
            return String(localized: "\(server) listens on \(listen). Connections there come back through the tunnel to \(target) as seen from this Mac.")
        case .dynamic:
            return String(localized: "A SOCKS4/5 proxy listens on \(listen). Point a browser or app at it and every connection exits from \(server).")
        }
    }

    static func bracketIfIPv6(_ host: String) -> String {
        if host.contains(":") && !host.hasPrefix("[") { return "[\(host)]" }
        return host
    }
}

// MARK: - Tunnel

public enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Let ssh decide: agent, default keys, then password prompts.
    case automatic
    case password
    case publicKey
    case keyboardInteractive

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic (agent & keys)")
        case .password: return String(localized: "Password")
        case .publicKey: return String(localized: "Private Key")
        case .keyboardInteractive: return String(localized: "Keyboard-Interactive / 2FA")
        }
    }

    public var shortTitle: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .password: return String(localized: "Password")
        case .publicKey: return String(localized: "Private key")
        case .keyboardInteractive: return String(localized: "Interactive")
        }
    }
}

public enum ProxyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case jumpHost
    case socks5
    case socks4
    case http

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return String(localized: "Direct connection")
        case .jumpHost: return String(localized: "Jump host (ProxyJump)")
        case .socks5: return String(localized: "SOCKS5 proxy")
        case .socks4: return String(localized: "SOCKS4 proxy")
        case .http: return String(localized: "HTTP proxy (CONNECT)")
        }
    }

    public var defaultPort: Int {
        switch self {
        case .none: return 0
        case .jumpHost: return 22
        case .socks5, .socks4: return 1080
        case .http: return 8080
        }
    }
}

public enum HostKeyPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Ask before trusting a new host; always refuse changed keys.
    case ask
    /// Trust new hosts automatically; refuse changed keys.
    case acceptNew
    /// Only connect to hosts already in known_hosts.
    case strict

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: return String(localized: "Ask for new hosts")
        case .acceptNew: return String(localized: "Trust new hosts automatically")
        case .strict: return String(localized: "Only known hosts")
        }
    }

    public var sshValue: String {
        switch self {
        case .ask: return "ask"
        case .acceptNew: return "accept-new"
        case .strict: return "yes"
        }
    }
}

public enum AddressFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case any, ipv4, ipv6
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .any: return String(localized: "Any")
        case .ipv4: return String(localized: "IPv4 only")
        case .ipv6: return String(localized: "IPv6 only")
        }
    }
    public var sshValue: String {
        switch self {
        case .any: return "any"
        case .ipv4: return "inet"
        case .ipv6: return "inet6"
        }
    }
}

public struct ProxySettings: Codable, Hashable, Sendable {
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    /// Username for the proxy (SOCKS5 / HTTP) or for the jump host.
    public var username: String
    /// Whether a password stored in the Keychain should be sent to the proxy.
    public var requiresPassword: Bool

    public init(kind: ProxyKind = .none, host: String = "", port: Int = 0, username: String = "", requiresPassword: Bool = false) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.requiresPassword = requiresPassword
    }

    /// `user@host:port` style label (port omitted when 22).
    public var notation: String {
        var s = username.isEmpty ? host : "\(username)@\(host)"
        if port != 22 && port > 0 { s += ":\(port)" }
        return s
    }

    enum CodingKeys: String, CodingKey { case kind, host, port, username, requiresPassword }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(ProxyKind.self, forKey: .kind) ?? .none
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        requiresPassword = try c.decodeIfPresent(Bool.self, forKey: .requiresPassword) ?? false
    }
}

public struct Tunnel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var note: String

    // Server
    public var host: String
    public var port: Int
    public var user: String
    public var authMethod: AuthMethod
    public var identityFile: String

    public var forwardings: [Forwarding]

    // Behaviour
    public var autoConnect: Bool
    public var autoReconnect: Bool

    // Connection
    public var connectTimeout: Int
    public var connectionAttempts: Int
    public var keepAliveInterval: Int
    public var keepAliveCountMax: Int
    public var bindInterface: String
    public var proxy: ProxySettings

    // Advanced
    public var compression: Bool
    public var checkHostIP: Bool
    public var hostKeyPolicy: HostKeyPolicy
    public var addressFamily: AddressFamily
    public var hostKeyAlgorithms: String
    public var kexAlgorithms: String
    public var ciphers: String
    public var useSSHConfig: Bool
    /// Extra `-o` options, one `Key=Value` (or `Key Value`) per line.
    public var extraOptions: String

    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "",
        note: String = "",
        host: String = "",
        port: Int = 22,
        user: String = "",
        authMethod: AuthMethod = .automatic,
        identityFile: String = "",
        forwardings: [Forwarding] = [],
        autoConnect: Bool = false,
        autoReconnect: Bool = true,
        connectTimeout: Int = 15,
        connectionAttempts: Int = 1,
        keepAliveInterval: Int = 30,
        keepAliveCountMax: Int = 3,
        bindInterface: String = "",
        proxy: ProxySettings = ProxySettings(),
        compression: Bool = false,
        checkHostIP: Bool = false,
        hostKeyPolicy: HostKeyPolicy = .ask,
        addressFamily: AddressFamily = .any,
        hostKeyAlgorithms: String = "",
        kexAlgorithms: String = "",
        ciphers: String = "",
        useSSHConfig: Bool = true,
        extraOptions: String = "",
        createdAt: Date = Tunnel.now()
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.host = host
        self.port = port
        self.user = user
        self.authMethod = authMethod
        self.identityFile = identityFile
        self.forwardings = forwardings
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
        self.connectTimeout = connectTimeout
        self.connectionAttempts = connectionAttempts
        self.keepAliveInterval = keepAliveInterval
        self.keepAliveCountMax = keepAliveCountMax
        self.bindInterface = bindInterface
        self.proxy = proxy
        self.compression = compression
        self.checkHostIP = checkHostIP
        self.hostKeyPolicy = hostKeyPolicy
        self.addressFamily = addressFamily
        self.hostKeyAlgorithms = hostKeyAlgorithms
        self.kexAlgorithms = kexAlgorithms
        self.ciphers = ciphers
        self.useSSHConfig = useSSHConfig
        self.extraOptions = extraOptions
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, note, host, port, user, authMethod, identityFile, forwardings
        case autoConnect, autoReconnect, connectTimeout, connectionAttempts, keepAliveInterval, keepAliveCountMax
        case bindInterface, proxy, compression, checkHostIP, hostKeyPolicy, addressFamily
        case hostKeyAlgorithms, kexAlgorithms, ciphers, useSSHConfig, extraOptions, createdAt
    }

    /// Tolerant decoding so files written by older/newer versions still load.
    public init(from decoder: Decoder) throws {
        let d = Tunnel()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? d.note
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? d.authMethod
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? d.identityFile
        forwardings = try c.decodeIfPresent([Forwarding].self, forKey: .forwardings) ?? []
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? d.autoConnect
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? d.autoReconnect
        connectTimeout = try c.decodeIfPresent(Int.self, forKey: .connectTimeout) ?? d.connectTimeout
        connectionAttempts = try c.decodeIfPresent(Int.self, forKey: .connectionAttempts) ?? d.connectionAttempts
        keepAliveInterval = try c.decodeIfPresent(Int.self, forKey: .keepAliveInterval) ?? d.keepAliveInterval
        keepAliveCountMax = try c.decodeIfPresent(Int.self, forKey: .keepAliveCountMax) ?? d.keepAliveCountMax
        bindInterface = try c.decodeIfPresent(String.self, forKey: .bindInterface) ?? d.bindInterface
        proxy = try c.decodeIfPresent(ProxySettings.self, forKey: .proxy) ?? d.proxy
        compression = try c.decodeIfPresent(Bool.self, forKey: .compression) ?? d.compression
        checkHostIP = try c.decodeIfPresent(Bool.self, forKey: .checkHostIP) ?? d.checkHostIP
        hostKeyPolicy = try c.decodeIfPresent(HostKeyPolicy.self, forKey: .hostKeyPolicy) ?? d.hostKeyPolicy
        addressFamily = try c.decodeIfPresent(AddressFamily.self, forKey: .addressFamily) ?? d.addressFamily
        hostKeyAlgorithms = try c.decodeIfPresent(String.self, forKey: .hostKeyAlgorithms) ?? d.hostKeyAlgorithms
        kexAlgorithms = try c.decodeIfPresent(String.self, forKey: .kexAlgorithms) ?? d.kexAlgorithms
        ciphers = try c.decodeIfPresent(String.self, forKey: .ciphers) ?? d.ciphers
        useSSHConfig = try c.decodeIfPresent(Bool.self, forKey: .useSSHConfig) ?? d.useSSHConfig
        extraOptions = try c.decodeIfPresent(String.self, forKey: .extraOptions) ?? d.extraOptions
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Tunnel.now()
    }

    /// Whole-second timestamp so dates survive an ISO-8601 round trip unchanged.
    public static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host.isEmpty ? String(localized: "Untitled Tunnel") : host
    }

    /// `user@host:port` style label (port omitted when 22).
    public var hostNotation: String {
        var s = user.isEmpty ? host : "\(user)@\(host)"
        if port != 22 { s += ":\(port)" }
        return s
    }

    public var enabledForwardings: [Forwarding] { forwardings.filter(\.enabled) }

    /// Returns a copy with fresh identifiers, suitable for "Duplicate".
    public func duplicated() -> Tunnel {
        var copy = self
        copy.id = UUID()
        let original = displayName
        copy.name = String(localized: "\(original) copy")
        copy.createdAt = Tunnel.now()
        copy.forwardings = forwardings.map { f in
            var n = f
            n.id = UUID()
            return n
        }
        return copy
    }

    /// Case-insensitive keyword match against name, note, host, user and forwardings.
    /// Every whitespace-separated keyword must match (like the original Smart Groups).
    public func matches(query: String) -> Bool {
        let keywords = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if keywords.isEmpty { return true }
        let haystack = ([name, note, host, user, String(port)] + forwardings.flatMap {
            [$0.bindAddress, String($0.port), $0.targetHost, String($0.targetPort), $0.name, $0.note]
        }).joined(separator: " ").lowercased()
        return keywords.allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Smart groups & document

public struct SmartGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Space separated keywords; a tunnel belongs to the group when all keywords match.
    public var keywords: String

    public init(id: UUID = UUID(), name: String, keywords: String) {
        self.id = id
        self.name = name
        self.keywords = keywords
    }
}

public struct PortholeDocument: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var tunnels: [Tunnel]
    public var smartGroups: [SmartGroup]

    public init(version: Int = PortholeDocument.currentVersion, tunnels: [Tunnel] = [], smartGroups: [SmartGroup] = []) {
        self.version = version
        self.tunnels = tunnels
        self.smartGroups = smartGroups
    }

    enum CodingKeys: String, CodingKey { case version, tunnels, smartGroups }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tunnels = try c.decodeIfPresent([Tunnel].self, forKey: .tunnels) ?? []
        smartGroups = try c.decodeIfPresent([SmartGroup].self, forKey: .smartGroups) ?? []
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
