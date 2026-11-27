import AppKit
import Observation
import PortlaneCore

/// Selection and transient user actions shared by the window and the menu bar.
@MainActor
@Observable
final class PortlaneModel {
    enum Selection: Hashable { case managed(UUID), external(Int32) }

    struct EditorRequest: Identifiable {
        let id = UUID()
        let tunnel: Tunnel
        var focusRule: UUID?
        var addRule = false
    }

    struct ImportPreview: Identifiable {
        let id = UUID()
        let tunnels: [Tunnel]
    }

    let store: TunnelStore
    let manager: TunnelManager
    private let demo: Bool
    private(set) var discovered: [ExternalSession] = []
    private(set) var refreshing = false
    private(set) var discoveryError: String?
    private(set) var copied: String?
    @ObservationIgnored private var copyReset: Task<Void, Never>?
    var errorMessage: String?
    var selection: Selection?
    var query = ""
    var editor: EditorRequest?
    var importPreview: ImportPreview?
    var logID: UUID?

    init(demo: Bool = false) {
        self.demo = demo
        store = demo ? TunnelStore(fileURL: nil, samples: DemoContent.tunnels) : TunnelStore()
        manager = TunnelManager(store: store, demo: demo)
        if demo { configureDemo() }
        pickAvailableSelection()
    }

    var externalSessions: [ExternalSession] {
        discovered.filter { !manager.runningPIDs.contains($0.id) }
    }

    var matchingTunnels: [Tunnel] { store.tunnels.filter { $0.matches(query: query) } }
    var matchingExternal: [ExternalSession] { externalSessions.filter { $0.matches(query: query) } }

    /// Retain the previous snapshot when an inventory command fails.
    func refreshDiscovery() {
        guard !demo, !refreshing else { return }
        refreshing = true
        let owned = manager.runningPIDs
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try ExternalScanner.scan(excluding: owned) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                discovered = snapshot
                discoveryError = nil
                pickAvailableSelection()
            case .failure:
                discoveryError = L10n.text(
                    "Could not refresh local SSH sessions. Showing the last snapshot.",
                    "本机发现刷新失败，仍显示上次结果。"
                )
            }
            refreshing = false
        }
    }

    func pickAvailableSelection() {
        switch selection {
        case .managed(let id) where store.tunnel(id) != nil: return
        case .external(let pid) where externalSessions.contains(where: { $0.id == pid }): return
        default: break
        }
        selection = store.tunnels.first.map { .managed($0.id) } ?? externalSessions.first.map { .external($0.id) }
    }

    func newTunnel(kind: ForwardingKind = .local) {
        editor = EditorRequest(tunnel: Tunnel(forwardings: [Self.newRule(kind: kind)]))
    }

    static func newRule(kind: ForwardingKind = .local) -> Forwarding {
        Forwarding(kind: kind, bindAddress: "127.0.0.1", port: kind == .dynamic ? 1080 : 0,
                   targetHost: "127.0.0.1", targetPort: 0)
    }

    func edit(_ tunnel: Tunnel, focusRule: UUID? = nil, addRule: Bool = false) {
        editor = EditorRequest(tunnel: tunnel, focusRule: focusRule, addRule: addRule)
    }

    /// A connection is started only after persistence succeeds.
    func save(_ tunnel: Tunnel, connect: Bool) throws {
        let previous = try store.save(tunnel)
        manager.tunnelDidChange(tunnel, previous: previous)
        if connect, manager.runtimes[tunnel.id]?.desiredOn != true { manager.connect(tunnel.id) }
        query = ""
        selection = .managed(tunnel.id)
        editor = nil
        refreshDiscovery()
    }

    func remove(_ tunnel: Tunnel) {
        do {
            try store.remove(tunnel.id)
            manager.disconnect(tunnel.id)
            if !demo { Keychain.removeTunnelCredentials(tunnel.id) }
            pickAvailableSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copy(_ text: String, key: String) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        guard clipboard.setString(text, forType: .string) else { return }
        copied = key
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { self?.copied = nil }
        }
    }

    /// Only the active user's local SSH config is inspected. Importing never rewrites it.
    func previewSSHConfig() {
        let file = URL.homeDirectory.appending(path: ".ssh/config")
        do {
            let content = try String(contentsOf: file, encoding: .utf8)
            let known = Set(store.tunnels.map(\.host))
            let imported = SSHConfigImporter.tunnels(fromConfig: content).map {
                // Resolve User, Port, IdentityFile and ProxyJump through the alias at connection time.
                Tunnel(name: $0.name, note: $0.note, host: $0.host, forwardings: $0.forwardings)
            }.filter { !known.contains($0.host) && !TunnelValidator.validate($0).contains(where: { $0.severity == .error }) }
            guard !imported.isEmpty else {
                errorMessage = L10n.text("No new TCP forwarding rules were found in ~/.ssh/config.",
                                         "~/.ssh/config 中没有可以导入的新 TCP 转发。")
                return
            }
            importPreview = ImportPreview(tunnels: imported)
        } catch {
            errorMessage = L10n.text("Could not read ~/.ssh/config.", "无法读取 ~/.ssh/config。")
        }
    }

    func importSelected(_ tunnels: [Tunnel]) {
        do {
            try store.add(tunnels)
            if let first = tunnels.first { selection = .managed(first.id) }
            query = ""
            importPreview = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func configureDemo() {
        for (index, tunnel) in store.tunnels.enumerated() where index == 0 || index == 2 { manager.connect(tunnel.id) }
        if let failed = store.tunnels.last, let rule = failed.forwardings.first {
            let message = L10n.text("Local port 8080 is already in use.", "本机端口 8080 已被占用。")
            manager.runtime(failed.id).applyDemo(state: .failed(message), forwardStatus: [rule.id: .failed(message)],
                                                  logs: [(.error, message)], lastError: message)
        }
        discovered = DemoContent.externalSessions
    }
}
