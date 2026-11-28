import Darwin
import Foundation
import LaneCore
@testable import Lane
import Testing

/// Covers settings behavior without using the real tunnel library, defaults, or saved credentials.
@MainActor
struct SettingsTests {
    @Test func roundTripsLanePreferences() throws {
        let name = "site.dong4j.lane.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("dark", forKey: "lane.appearance")

        let preferences = LanePreferences(defaults: defaults)
        #expect(preferences.appearance == .dark)
        #expect(preferences.presentation == .both)
        #expect(preferences.reconnectOnWake)
        #expect(preferences.sshPath == "/usr/bin/ssh")

        preferences.language = .chinese
        preferences.presentation = .menuBarOnly
        preferences.reconnectOnWake = false
        preferences.notifyOnConnect = true
        preferences.customSSHPath = "/opt/homebrew/bin/ssh"

        let reloaded = LanePreferences(defaults: defaults)
        #expect(reloaded.language == .chinese)
        #expect(reloaded.presentation == .menuBarOnly)
        #expect(!reloaded.reconnectOnWake)
        #expect(reloaded.notifyOnConnect)
        #expect(reloaded.sshPath == "/opt/homebrew/bin/ssh")
    }

    /// Preview and commit independently skip duplicates, even if a second preview is still open.
    @Test func restoresSelectedBackupEntriesAndPreservesTheirIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "backup.json")
        let tunnel = Tunnel(name: "Fixture", host: "example.invalid",
                            forwardings: [Forwarding(kind: .dynamic, port: 1090)], autoConnect: true)
        let document = PortholeDocument(tunnels: [tunnel, tunnel, Tunnel()])
        try PortholeDocument.encoder().encode(document).write(to: file)

        let model = LaneModel(demo: true)
        let preview = try model.backupImport(from: file)
        #expect(preview.tunnels == [tunnel])
        #expect(preview.skippedCount == 2)
        #expect(try model.importSelected(preview.tunnels, kind: preview.kind) == 1)
        #expect(model.selection == .managed(tunnel.id))
        #expect(throws: (any Error).self) {
            try model.importSelected(preview.tunnels, kind: preview.kind)
        }

        let exported = try PortholeDocument.decoder().decode(PortholeDocument.self, from: model.store.exportData())
        #expect(exported.tunnels.first(where: { $0.id == tunnel.id }) == tunnel)
    }

    @Test func recognizesCodinnFilesAndSkipsAnAlreadyImportedSession() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "codinn.json")
        try Data("""
        {"tunnels":[{"name":"Legacy","ssh_host":"legacy.example","forwardings":[{"type":2,"port":1091}]}]}
        """.utf8).write(to: file)

        let model = LaneModel(demo: true)
        let preview = try model.backupImport(from: file)
        #expect(preview.tunnels.first?.forwardings.first?.kind == .dynamic)
        #expect(try model.importSelected(preview.tunnels, kind: preview.kind) == 1)
        #expect(throws: (any Error).self) { try model.backupImport(from: file) }
    }

    @Test func proxyIdentityChangesBothRestartAndReuseWhileNotesDoNot() throws {
        let model = LaneModel(demo: true)
        let rule = Forwarding(bindAddress: "127.0.0.1")
        let original = Tunnel(host: "sample.invalid", forwardings: [rule],
                              proxy: ProxySettings(kind: .socks5, host: "proxy.invalid", port: 1080,
                                                   username: "alice", requiresPassword: true))
        let before = try #require(AgentPreparedRoute(profile: original, forwarding: rule))
        var changed = original
        changed.note = "New note"
        #expect(!model.manager.requiresRestart(for: changed, replacing: original))
        changed.proxy.username = "bob"
        let after = try #require(AgentPreparedRoute(profile: changed, forwarding: rule))
        #expect(model.manager.requiresRestart(for: changed, replacing: original))
        #expect(before.key != after.key)
        let command = model.manager.commandBuilder.displayCommand(for: changed)
        #expect(command.contains("--proxy-connect socks5 proxy.invalid 1080 %h %p bob ask-password"))
    }

    @Test func bindFailureUsesTheRightFieldAndListenerFamily() {
        let rule = Forwarding(bindAddress: "127.0.0.1:3113", port: 3113)
        #expect(TunnelValidator.validate(rule).first?.field == .forwarding(rule.id, .listenAddress))
        let sockets = """
        p42
        cWrongIPv4
        f7
        tIPv4
        n127.0.0.2:3113
        p57
        cIPv6Listener
        f11
        tIPv6
        n*:3113
        p93
        cIPv4Listener
        f4
        tIPv4
        n127.0.0.1:3113
        """
        #expect(PortInspector.listenerName(in: sockets, port: 3113, host: "127.0.0.1", family: AF_INET) == "IPv4Listener")
        #expect(PortInspector.listenerName(in: sockets, port: 3113, host: "::1", family: AF_INET6) == "IPv6Listener")
        #expect(PortInspector.listenerName(in: sockets, port: 3113, host: "0.0.0.0", family: AF_INET) == nil)
        #expect(PortInspector.listenerName(in: sockets, port: 3114, host: "127.0.0.1", family: AF_INET) == nil)
    }

    @Test func validatesOnlyOpenSSHExecutables() async throws {
        #expect(try await OpenSSHClient.version(at: "/usr/bin/ssh").hasPrefix("OpenSSH_"))
        await #expect(throws: OpenSSHClient.CheckError.unsupported) {
            try await OpenSSHClient.version(at: "/usr/bin/true")
        }
    }
}
