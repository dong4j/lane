import Foundation
import Observation
import LaneCore

/// Stores Lane's configuration independently of the upstream application and ssh_config.
@MainActor
@Observable
final class TunnelStore {
    private(set) var tunnels: [Tunnel] = []
    private(set) var loadError: String?
    private(set) var canRestore = true
    private var smartGroups: [SmartGroup] = []
    let fileURL: URL?

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["LANE_DATA_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL.applicationSupportDirectory
            .appending(path: "Lane", directoryHint: .isDirectory)
            .appending(path: "tunnels.json")
    }

    init(fileURL: URL? = TunnelStore.defaultURL, samples: [Tunnel] = []) {
        self.fileURL = fileURL
        tunnels = samples
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try PortholeDocument.decoder().decode(PortholeDocument.self, from: data)
            tunnels = document.tunnels
            smartGroups = document.smartGroups
        } catch let error as PortholeDocument.UnsupportedVersion {
            loadError = Self.versionMessage(error.version)
            canRestore = false
        } catch {
            loadError = L10n.text("Lane could not read the tunnel library. Restore it from Settings → Data.",
                                  "无法读取隧道库。可在「设置 → 数据」从备份恢复。")
        }
    }

    static func versionMessage(_ version: Int) -> String {
        L10n.text("Configuration format \(version) is unsupported. Open it with a compatible version of Lane.",
                  "当前版本无法读取格式 \(version) 的配置。请使用兼容版本的 Lane。")
    }

    func tunnel(_ id: UUID) -> Tunnel? {
        tunnels.first { $0.id == id }
    }

    @discardableResult
    func save(_ tunnel: Tunnel) throws -> Tunnel? {
        var updated = tunnels
        let previous = self.tunnel(tunnel.id)
        if let index = updated.firstIndex(where: { $0.id == tunnel.id }) {
            updated[index] = tunnel
        } else {
            updated.append(tunnel)
        }
        try write(updated)
        return previous
    }

    func add(_ items: [Tunnel]) throws {
        try write(tunnels + items)
    }

    func remove(_ id: UUID) throws {
        try write(tunnels.filter { $0.id != id })
    }

    /// Export the same tunnel data that can be restored, without looking up any Keychain entries.
    func exportData() throws -> Data {
        if let loadError { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: loadError]) }
        return try PortholeDocument.encoder().encode(PortholeDocument(tunnels: tunnels, smartGroups: smartGroups))
    }

    /// Copy the exact bytes first, so even a malformed library is available for recovery.
    func restore(_ updated: [Tunnel], smartGroups: [SmartGroup]) throws -> URL? {
        guard canRestore else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: loadError ?? ""]) }
        var preserved: URL?
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let path = fileURL.deletingLastPathComponent().appending(path: "\(fileURL.lastPathComponent).before-restore-\(UUID()).bak")
            try FileManager.default.copyItem(at: fileURL, to: path)
            preserved = path
        }
        try replace(updated, smartGroups: smartGroups)
        loadError = nil
        return preserved
    }

    /// Publish the new in-memory list only when the atomic disk replacement succeeds.
    private func write(_ updated: [Tunnel]) throws {
        if let loadError { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: loadError]) }
        try replace(updated, smartGroups: smartGroups)
    }

    private func replace(_ updated: [Tunnel], smartGroups: [SmartGroup]) throws {
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PortholeDocument.encoder().encode(PortholeDocument(tunnels: updated, smartGroups: smartGroups))
            try data.write(to: fileURL, options: .atomic)
        }
        tunnels = updated
        self.smartGroups = smartGroups
    }
}
