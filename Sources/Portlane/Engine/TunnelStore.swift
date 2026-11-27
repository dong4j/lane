import Foundation
import Observation
import PortlaneCore

/// Stores Portlane's configuration independently of the upstream application and ssh_config.
@MainActor
@Observable
final class TunnelStore {
    private(set) var tunnels: [Tunnel] = []
    private(set) var loadError: String?
    let fileURL: URL?

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["PORTLANE_DATA_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL.applicationSupportDirectory
            .appending(path: "Portlane", directoryHint: .isDirectory)
            .appending(path: "tunnels.json")
    }

    init(fileURL: URL? = TunnelStore.defaultURL, samples: [Tunnel] = []) {
        self.fileURL = fileURL
        tunnels = samples
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            tunnels = try PortholeDocument.decoder().decode(PortholeDocument.self, from: data).tunnels
        } catch {
            loadError = error.localizedDescription
        }
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
        return try PortholeDocument.encoder().encode(PortholeDocument(tunnels: tunnels))
    }

    /// Publish the new in-memory list only when the atomic disk replacement succeeds.
    private func write(_ updated: [Tunnel]) throws {
        if let loadError { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: loadError]) }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PortholeDocument.encoder().encode(PortholeDocument(tunnels: updated))
            try data.write(to: fileURL, options: .atomic)
        }
        tunnels = updated
    }
}
