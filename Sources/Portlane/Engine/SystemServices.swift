import Darwin
import Foundation
import Network
import Security

/// Optional credentials use a Portlane-only service and stay outside configuration and logs.
enum Keychain {
    private static let service = "site.dong4j.portlane.ssh"

    static func tunnelPassword(_ id: UUID, account: String) -> String { "tunnel.\(id).password.\(account)" }
    static func proxyPassword(_ id: UUID) -> String { "tunnel.\(id).proxy" }
    static func keyPassphrase(_ path: String) -> String { "key.\((path as NSString).expandingTildeInPath)" }

    private static func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func get(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        var attributes = query(account)
        let result = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Lane · SSH"
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Key passphrases can be shared by multiple tunnels, so only delete credentials owned by this rule set.
    static func removeTunnelCredentials(_ id: UUID) {
        var attributes = query()
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &items) == errSecSuccess,
              let rows = items as? [[String: Any]] else { return }
        for row in rows {
            if let account = row[kSecAttrAccount as String] as? String, account.hasPrefix("tunnel.\(id).") {
                SecItemDelete(query(account) as CFDictionary)
            }
        }
    }
}

/// Local bind failures are attributed only after the kernel reports a conflict on the requested address.
enum PortInspector {
    static func conflict(port: Int, bindAddress: String) -> String? {
        let host = switch bindAddress {
        case "", "localhost": "127.0.0.1"
        case "*": "0.0.0.0"
        default: bindAddress.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        let address = info.pointee
        let socketFD = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        guard bind(socketFD, address.ai_addr, address.ai_addrlen) == -1, errno == EADDRINUSE else { return nil }
        if let owner = listenerNames(port: port).first {
            return L10n.text("Local port \(port) is in use by \(owner).", "本机端口 \(port) 已被 \(owner) 占用。")
        }
        return L10n.text("Local port \(port) is already in use.", "本机端口 \(port) 已被占用。")
    }

    private static func listenerNames(port: Int) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fc"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            $0.first == "c" ? String($0.dropFirst()) : nil
        }
    }
}

/// Only the transition back to a reachable network advances pending reconnects.
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var wasReachable: Bool?
    var onBecameReachable: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if reachable, wasReachable == false { onBecameReachable?() }
                wasReachable = reachable
            }
        }
        monitor.start(queue: DispatchQueue(label: "portlane.network"))
    }

    func stop() { monitor.cancel() }
}
