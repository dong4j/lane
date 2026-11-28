import AppKit
import Observation
import LaneCore

/// Selection and transient user actions shared by the window and the menu bar.
@MainActor
@Observable
final class LaneModel {
    enum Selection: Hashable { case managed(UUID), external(Int32) }

    struct EditorRequest: Identifiable {
        let id = UUID()
        let tunnel: Tunnel
        var focusRule: UUID?
        var addRule = false
    }

    enum ImportKind { case sshConfig, backup, codinn, restore }

    struct ImportPreview: Identifiable {
        let id = UUID()
        let kind: ImportKind
        let source: String
        let tunnels: [Tunnel]
        let skippedCount: Int
        var ignoredOptions: [String] = []
        var removedNames: [String] = []
        var smartGroups: [SmartGroup] = []
        var configSources: [UUID: String] = [:]
        var configWarnings: [String] = []
    }

    let preferences: LanePreferences
    let store: TunnelStore
    let manager: TunnelManager
    let agents: AgentAccess
    let demo: Bool
    private(set) var discovered: [ExternalSession] = []
    private(set) var refreshing = false
    private(set) var discoveryError: String?
    private(set) var copied: String?
    @ObservationIgnored private var copyReset: Task<Void, Never>?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    var errorMessage: String?
    var selection: Selection?
    var query = ""
    var editor: EditorRequest?
    var importPreview: ImportPreview?
    var logID: UUID?
    var showingAgentActivity = false

    init(demo: Bool = false) {
        self.demo = demo
        preferences = LanePreferences(defaults: demo ? nil : .standard)
        store = demo ? TunnelStore(fileURL: nil, samples: DemoContent.tunnels) : TunnelStore()
        manager = TunnelManager(store: store, demo: demo, preferences: preferences)
        agents = AgentAccess(manager: manager, files: store.fileURL.map(AgentFiles.live(tunnelFile:)))
        if demo { configureDemo() }
        pickAvailableSelection()
    }

    func showMainWindow() {
        NSApp.activate()
        openMainWindow?()
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
        agents.libraryChanged()
        manager.tunnelDidChange(tunnel, previous: previous)
        if connect, !manager.keepsConnected(tunnel.id) { manager.connect(tunnel.id) }
        query = ""
        selection = .managed(tunnel.id)
        editor = nil
        refreshDiscovery()
    }

    func remove(_ tunnel: Tunnel) {
        do {
            try store.remove(tunnel.id)
            manager.disconnect(tunnel.id)
            agents.libraryChanged()
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
        do {
            importPreview = try sshConfigImport()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sshConfigImport(from file: URL = URL.homeDirectory.appending(path: ".ssh/config")) throws -> ImportPreview {
        guard let parsed = try? SSHConfigImporter.preview(file: file) else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: L10n.text("Could not read ~/.ssh/config.", "无法读取 ~/.ssh/config。")
            ])
        }
        let candidates = parsed.tunnels.map {
            // Leave identity, user, port and jump host resolution to the original SSH alias.
            Tunnel(id: $0.id, name: $0.name, note: $0.note, host: $0.host, forwardings: $0.forwardings)
        }
        var preview = try makeImportPreview(candidates, kind: .sshConfig, source: (file.path as NSString).abbreviatingWithTildeInPath,
                                            allowEmpty: true)
        preview.configSources = parsed.sources.mapValues { ($0.path as NSString).abbreviatingWithTildeInPath }
        preview.configWarnings = parsed.notices.map { notice in
            switch notice {
            case .noFiles(let path):
                L10n.text("No files matched Include \(path).", "Include \(path) 未匹配到文件。")
            case .unreadable(let path):
                L10n.text("Could not read included file \(path).", "无法读取包含文件 \(path)。")
            case .includeCycle(let path):
                L10n.text("Skipped a circular or deeply nested Include in \(path).", "已跳过 \(path) 中循环或嵌套过深的 Include。")
            case .dynamicInclude(let path):
                L10n.text("Skipped Include \(path), which uses runtime expansion.", "已跳过使用运行时展开的 Include \(path)。")
            case .matchBlock(let path):
                L10n.text("Match conditions were skipped in \(path).", "已跳过 \(path) 中的 Match 条件。")
            }
        }
        if preview.tunnels.isEmpty {
            preview.configWarnings.append(L10n.text("No new, valid forwards were found.", "没有找到可导入的新转发。"))
        }
        return preview
    }

    /// Prefer the document format when it contains tunnel records. Codinn exports may also be JSON objects.
    func backupImport(from file: URL, restoring: Bool = false) throws -> ImportPreview {
        let data = try Data(contentsOf: file)
        let document: PortholeDocument?
        do {
            document = try PortholeDocument.decoder().decode(PortholeDocument.self, from: data)
        } catch let error as PortholeDocument.UnsupportedVersion {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: TunnelStore.versionMessage(error.version)
            ])
        } catch {
            document = nil
        }
        if let document, restoring || document.tunnels.contains(where: { !$0.host.isEmpty }) {
            var ignored: Set<String> = []
            let safe = document.tunnels.map { tunnel in
                var tunnel = tunnel
                let options = SSHCommandBuilder.backupOptions(tunnel.extraOptions)
                tunnel.extraOptions = options.allowed
                ignored.formUnion(options.ignored)
                return tunnel
            }
            var preview = try makeImportPreview(safe, kind: restoring ? .restore : .backup, source: file.lastPathComponent)
            preview.ignoredOptions = ignored.sorted()
            if restoring {
                let incoming = Set(safe.map(\.id))
                preview.removedNames = store.tunnels.filter { !incoming.contains($0.id) }.map(\.displayName)
                preview.smartGroups = document.smartGroups
            }
            return preview
        }
        guard !restoring else { throw invalidBackup() }
        let candidates = try LegacySSHTunnelImporter.tunnels(from: data)
        return try makeImportPreview(candidates, kind: .codinn, source: file.lastPathComponent)
    }

    /// Reload active connections only after the restored library has reached disk.
    func restoreBackup(_ preview: ImportPreview) throws -> URL? {
        guard preview.kind == .restore else { throw invalidBackup() }
        let previous = store.tunnels
        let preserved = try store.restore(preview.tunnels, smartGroups: preview.smartGroups)
        agents.libraryChanged()
        for old in previous {
            if let restored = store.tunnel(old.id) {
                manager.tunnelDidChange(restored, previous: old)
            } else {
                manager.disconnect(old.id)
            }
        }
        query = ""
        pickAvailableSelection()
        refreshDiscovery()
        return preserved
    }

    /// Check for duplicates again when committing, since the library can change while a preview is open.
    @discardableResult
    func importSelected(_ tunnels: [Tunnel], kind: ImportKind) throws -> Int {
        let fresh = try makeImportPreview(tunnels, kind: kind, source: "").tunnels
        try store.add(fresh)
        agents.libraryChanged()
        if let first = fresh.first { selection = .managed(first.id) }
        query = ""
        return fresh.count
    }

    private func makeImportPreview(_ candidates: [Tunnel], kind: ImportKind, source: String,
                                   allowEmpty: Bool = false) throws -> ImportPreview {
        var ids = kind == .restore ? Set<UUID>() : Set(store.tunnels.map(\.id))
        var aliases = Set(store.tunnels.map { $0.host.lowercased() })
        let builder = SSHCommandBuilder()
        func codinnKey(_ tunnel: Tunnel) -> [String] { [tunnel.name] + builder.arguments(for: tunnel) }
        var codinnKeys = kind == .codinn ? Set(store.tunnels.map(codinnKey)) : []

        let fresh = candidates.filter { tunnel in
            guard !ids.contains(tunnel.id), Set(tunnel.forwardings.map(\.id)).count == tunnel.forwardings.count,
                  !TunnelValidator.validate(tunnel).contains(where: { $0.severity == .error }) else { return false }
            switch kind {
            case .sshConfig:
                guard aliases.insert(tunnel.host.lowercased()).inserted else { return false }
            case .codinn:
                // Codinn records are given new IDs on parse, so compare their names and connection parameters.
                guard codinnKeys.insert(codinnKey(tunnel)).inserted else { return false }
            case .backup, .restore:
                break
            }
            return ids.insert(tunnel.id).inserted
        }
        if kind == .restore, fresh.count != candidates.count { throw invalidBackup() }
        guard kind == .restore || allowEmpty || !fresh.isEmpty else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: L10n.text("No new, valid tunnels were found.", "没有找到可导入的新隧道。")
            ])
        }
        return ImportPreview(kind: kind, source: source, tunnels: fresh, skippedCount: candidates.count - fresh.count)
    }

    private func invalidBackup() -> CocoaError {
        CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: L10n.text("Choose a complete Lane or Porthole backup with valid tunnels.",
                                                 "请选择隧道配置有效的完整 Lane 或 Porthole 备份。")
        ])
    }

    private func configureDemo() {
        for (index, tunnel) in store.tunnels.enumerated() where index == 0 || index == 2 { manager.connect(tunnel.id) }
        if let failed = store.tunnels.last, let rule = failed.forwardings.first {
            let message = L10n.text("Local port 8080 is already in use.", "本机端口 8080 已被占用。")
            manager.runtime(failed.id).applyDemo(state: .failed(message), forwardStatus: [rule.id: .failed(message)],
                                                  logs: [(.error, message)], lastError: message, failureKind: .portInUse)
        }
        discovered = DemoContent.externalSessions
    }
}
